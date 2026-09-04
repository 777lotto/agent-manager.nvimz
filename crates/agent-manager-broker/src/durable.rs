//! Owner-only Unix-socket transport for the durable broker lifecycle.

use std::fs;
use std::future::Future;
use std::io;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream as StdUnixStream;
use std::path::{Path, PathBuf};

use thiserror::Error;
use tokio::io::{BufReader, split};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::mpsc;
use tokio::task::JoinError;

use crate::embedded::{
    Broker, BrokerMode, ClientInput, EmbeddedConfig, EmbeddedError, read_client, write_client,
};
use crate::registry::{RegistryError, RegistryStore, ensure_private_directory};
use crate::status::{StatusError, StatusStore};

#[derive(Clone, Debug)]
pub struct DurableConfig {
    pub socket_path: PathBuf,
    pub registry_path: PathBuf,
    pub status_path: PathBuf,
    pub broker: EmbeddedConfig,
}

impl DurableConfig {
    #[must_use]
    pub fn new(socket_path: PathBuf, registry_path: PathBuf) -> Self {
        let status_path = registry_path.parent().map_or_else(
            || PathBuf::from("status.json"),
            |parent| parent.join("status.json"),
        );
        Self {
            socket_path,
            registry_path,
            status_path,
            broker: EmbeddedConfig::default(),
        }
    }

    #[must_use]
    pub fn with_broker_config(mut self, broker: EmbeddedConfig) -> Self {
        self.broker = broker;
        self
    }

    #[must_use]
    pub fn with_status_path(mut self, status_path: PathBuf) -> Self {
        self.status_path = status_path;
        self
    }
}

#[derive(Debug, Error)]
pub enum DurableError {
    #[error("durable broker I/O failed: {0}")]
    Io(#[from] io::Error),
    #[error("durable broker task failed: {0}")]
    Join(#[from] JoinError),
    #[error("durable broker core failed: {0}")]
    Broker(#[from] EmbeddedError),
    #[error("durable registry failed: {0}")]
    Registry(#[from] RegistryError),
    #[error("durable status failed: {0}")]
    Status(String),
    #[error("durable socket path is unsafe: {0}")]
    Unsafe(&'static str),
    #[error("another durable broker already owns the socket")]
    AlreadyRunning,
}

impl From<StatusError> for DurableError {
    fn from(error: StatusError) -> Self {
        Self::Status(error.to_string())
    }
}

pub async fn serve(config: DurableConfig) -> Result<(), DurableError> {
    serve_until(config, shutdown_signal()).await
}

pub async fn serve_until<F>(config: DurableConfig, shutdown: F) -> Result<(), DurableError>
where
    F: Future<Output = ()>,
{
    let (listener, socket_guard) = bind_owner_only(&config.socket_path)?;
    let status = StatusStore::open(config.status_path.clone())?;
    let registry_path = config.registry_path.clone();
    let result = serve_until_inner(config, shutdown, status.clone(), listener, socket_guard).await;
    if let Err(error) = &result {
        let byte_count = fs::metadata(registry_path).map_or(0, |metadata| metadata.len());
        let _ = status.failure(durable_error_code(error), 0, byte_count);
    }
    result
}

async fn serve_until_inner<F>(
    config: DurableConfig,
    shutdown: F,
    status: StatusStore,
    listener: UnixListener,
    socket_guard: SocketGuard,
) -> Result<(), DurableError>
where
    F: Future<Output = ()>,
{
    let registry = RegistryStore::open(config.registry_path)?;
    let restored_agents = registry.load()?;
    registry.persist(&restored_agents)?;

    let (input_tx, input_rx) = mpsc::unbounded_channel();
    let accept_handle = tokio::spawn(accept_clients(listener, input_tx));
    let (runtime_tx, runtime_rx) = mpsc::unbounded_channel();
    let mut broker = Broker::new(
        config.broker,
        BrokerMode::Durable,
        runtime_tx,
        Some(registry),
        restored_agents,
        Some(status.clone()),
    );
    let (object_count, byte_count) = broker.durable_counts();
    status.success("running", object_count, byte_count)?;

    tokio::pin!(shutdown);
    let broker_result = tokio::select! {
        result = broker.run(input_rx, runtime_rx) => result.map_err(DurableError::from),
        () = &mut shutdown => Ok(()),
    };
    accept_handle.abort();
    let _ = accept_handle.await;
    broker.shutdown_agents().await;
    let (object_count, byte_count) = broker.durable_counts();
    status.success("stopped", object_count, byte_count)?;
    drop(socket_guard);
    broker_result
}

const fn durable_error_code(error: &DurableError) -> &'static str {
    match error {
        DurableError::Io(_) => "io_failed",
        DurableError::Join(_) => "task_failed",
        DurableError::Broker(_) => "broker_core_failed",
        DurableError::Registry(_) => "registry_failed",
        DurableError::Status(_) => "status_failed",
        DurableError::Unsafe(_) => "unsafe_path",
        DurableError::AlreadyRunning => "already_running",
    }
}

async fn accept_clients(
    listener: UnixListener,
    input: mpsc::UnboundedSender<ClientInput>,
) -> Result<(), DurableError> {
    let mut generation = 0_u64;
    loop {
        let (stream, _) = listener.accept().await?;
        generation = generation
            .checked_add(1)
            .ok_or(DurableError::Unsafe("connection generation overflow"))?;
        serve_connection(stream, generation, &input).await;
    }
}

async fn serve_connection(
    stream: UnixStream,
    generation: u64,
    input: &mpsc::UnboundedSender<ClientInput>,
) {
    let (reader, writer) = split(stream);
    let (output_tx, output_rx) = mpsc::unbounded_channel();
    if input
        .send(ClientInput::Connected {
            generation,
            output: output_tx,
        })
        .is_err()
    {
        return;
    }
    let mut reader_task = tokio::spawn(read_client(
        BufReader::new(reader),
        input.clone(),
        generation,
    ));
    let mut writer_task = tokio::spawn(write_client(writer, output_rx));
    tokio::select! {
        _ = &mut reader_task => {
            writer_task.abort();
            let _ = writer_task.await;
        }
        _ = &mut writer_task => {
            reader_task.abort();
            let _ = reader_task.await;
        }
    }
    let _ = input.send(ClientInput::Closed { generation });
}

fn bind_owner_only(path: &Path) -> Result<(UnixListener, SocketGuard), DurableError> {
    if !path.is_absolute() {
        return Err(DurableError::Unsafe("socket path must be absolute"));
    }
    let parent = path.parent().ok_or(DurableError::Unsafe(
        "socket path must have a parent directory",
    ))?;
    ensure_private_directory(parent)?;
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            if !metadata.file_type().is_socket() {
                return Err(DurableError::Unsafe(
                    "existing socket path is not a Unix socket",
                ));
            }
            match StdUnixStream::connect(path) {
                Ok(_) => return Err(DurableError::AlreadyRunning),
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound
                    ) =>
                {
                    let current = fs::symlink_metadata(path)?;
                    if !current.file_type().is_socket()
                        || current.dev() != metadata.dev()
                        || current.ino() != metadata.ino()
                    {
                        return Err(DurableError::Unsafe("socket changed during stale cleanup"));
                    }
                    fs::remove_file(path)?;
                }
                Err(error) => return Err(DurableError::Io(error)),
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(DurableError::Io(error)),
    }
    let listener = UnixListener::bind(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_socket() || metadata.permissions().mode() & 0o077 != 0 {
        return Err(DurableError::Unsafe("socket is not owner-only"));
    }
    let guard = SocketGuard {
        path: path.to_owned(),
        device: metadata.dev(),
        inode: metadata.ino(),
    };
    Ok((listener, guard))
}

struct SocketGuard {
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl Drop for SocketGuard {
    fn drop(&mut self) {
        let Ok(metadata) = fs::symlink_metadata(&self.path) else {
            return;
        };
        if metadata.file_type().is_socket()
            && metadata.dev() == self.device
            && metadata.ino() == self.inode
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let Ok(mut terminate) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        else {
            let _ = tokio::signal::ctrl_c().await;
            return;
        };
        tokio::select! {
            _ = terminate.recv() => {}
            _ = tokio::signal::ctrl_c() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::time::Duration;

    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::UnixStream;
    use tokio::sync::oneshot;
    use tokio::time::timeout;

    use super::{DurableConfig, DurableError, bind_owner_only, serve_until};

    #[tokio::test]
    async fn owner_only_socket_survives_client_reconnect() {
        // Keep the Unix-socket path below macOS's short `sun_path` limit even
        // when the runner provides a long temporary-directory prefix.
        let directory =
            std::env::temp_dir().join(format!("amdt-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir(&directory).expect("create test directory");
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
            .expect("protect test directory");
        let socket = directory.join("s");
        let registry = directory.join("registry.json");
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let broker = tokio::spawn(serve_until(
            DurableConfig::new(socket.clone(), registry.clone()),
            async {
                let _ = shutdown_rx.await;
            },
        ));
        timeout(Duration::from_secs(5), async {
            while !socket.exists() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("socket creation timed out");
        assert_eq!(
            fs::metadata(&socket)
                .expect("socket metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );

        for request_id in [1, 2] {
            let stream = UnixStream::connect(&socket)
                .await
                .expect("connect durable client");
            let (reader, mut writer) = tokio::io::split(stream);
            writer
                .write_all(
                    format!(
                        "{{\"jsonrpc\":\"2.0\",\"id\":{request_id},\"method\":\"initialize\",\"params\":{{\"protocol_version\":1,\"client\":{{\"name\":\"test\",\"version\":\"0.1.0\"}},\"last_sequence\":0}}}}\n"
                    )
                    .as_bytes(),
                )
                .await
                .expect("write initialize");
            let mut reader = BufReader::new(reader);
            let mut line = String::new();
            timeout(Duration::from_secs(5), reader.read_line(&mut line))
                .await
                .expect("initialize response timed out")
                .expect("read initialize response");
            let response: serde_json::Value =
                serde_json::from_str(&line).expect("initialize response JSON");
            assert_eq!(response["result"]["mode"], "durable");
            drop(reader);
            drop(writer);
        }

        shutdown_tx.send(()).expect("signal broker shutdown");
        timeout(Duration::from_secs(5), broker)
            .await
            .expect("broker shutdown timed out")
            .expect("broker task panicked")
            .expect("broker failed");
        assert!(!socket.exists());
        assert!(registry.exists());

        symlink(directory.join("missing-target"), &socket).expect("create dangling socket symlink");
        assert!(matches!(
            bind_owner_only(&socket),
            Err(DurableError::Unsafe(
                "existing socket path is not a Unix socket"
            ))
        ));
        fs::remove_dir_all(directory).expect("remove test directory");
    }
}
