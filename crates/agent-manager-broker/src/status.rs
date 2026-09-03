//! Stable, non-sensitive service status for external monitoring.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use thiserror::Error;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

const STATUS_SCHEMA_VERSION: u32 = 1;
const MAX_STATUS_BYTES: u64 = 64 * 1024;

#[derive(Debug, Error)]
pub(crate) enum StatusError {
    #[error("status I/O failed: {0}")]
    Io(#[from] io::Error),
    #[error("status JSON is invalid: {0}")]
    Json(#[from] serde_json::Error),
    #[error("status path is unsafe: {0}")]
    Unsafe(&'static str),
}

#[derive(Clone, Debug)]
pub(crate) struct StatusStore {
    path: PathBuf,
    document: Arc<Mutex<StatusDocument>>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct StatusDocument {
    schema_version: u32,
    service: String,
    state: String,
    updated_at: String,
    last_success_at: Option<String>,
    last_failure_at: Option<String>,
    last_error: Option<String>,
    object_count: u64,
    byte_count: u64,
}

impl StatusStore {
    pub(crate) fn open(path: PathBuf) -> Result<Self, StatusError> {
        if !path.is_absolute() {
            return Err(StatusError::Unsafe("path must be absolute"));
        }
        let parent = path
            .parent()
            .ok_or(StatusError::Unsafe("path must have a parent directory"))?;
        ensure_status_directory(parent)?;
        let document = if validate_existing_status_file(&path)? {
            let file = File::open(&path)?;
            if file.metadata()?.len() > MAX_STATUS_BYTES {
                return Err(StatusError::Unsafe("file exceeds the size limit"));
            }
            let mut encoded = Vec::new();
            file.take(MAX_STATUS_BYTES + 1).read_to_end(&mut encoded)?;
            let document: StatusDocument = serde_json::from_slice(&encoded)?;
            if document.schema_version != STATUS_SCHEMA_VERSION
                || document.service != "agent-manager"
            {
                return Err(StatusError::Unsafe("identity or schema is invalid"));
            }
            document
        } else {
            StatusDocument {
                schema_version: STATUS_SCHEMA_VERSION,
                service: "agent-manager".to_owned(),
                state: "starting".to_owned(),
                updated_at: timestamp(),
                last_success_at: None,
                last_failure_at: None,
                last_error: None,
                object_count: 0,
                byte_count: 0,
            }
        };
        let store = Self {
            path,
            document: Arc::new(Mutex::new(document)),
        };
        store.persist()?;
        Ok(store)
    }

    pub(crate) fn success(
        &self,
        state: &str,
        object_count: u64,
        byte_count: u64,
    ) -> Result<(), StatusError> {
        {
            let mut document = self
                .document
                .lock()
                .map_err(|_| StatusError::Unsafe("status lock is poisoned"))?;
            let now = timestamp();
            state.clone_into(&mut document.state);
            document.updated_at.clone_from(&now);
            document.last_success_at = Some(now);
            document.last_error = None;
            document.object_count = object_count;
            document.byte_count = byte_count;
        }
        self.persist()
    }

    pub(crate) fn failure(
        &self,
        error: &'static str,
        object_count: u64,
        byte_count: u64,
    ) -> Result<(), StatusError> {
        {
            let mut document = self
                .document
                .lock()
                .map_err(|_| StatusError::Unsafe("status lock is poisoned"))?;
            let now = timestamp();
            "failed".clone_into(&mut document.state);
            document.updated_at.clone_from(&now);
            document.last_failure_at = Some(now);
            document.last_error = Some(error.to_owned());
            document.object_count = object_count;
            document.byte_count = byte_count;
        }
        self.persist()
    }

    fn persist(&self) -> Result<(), StatusError> {
        let document = self
            .document
            .lock()
            .map_err(|_| StatusError::Unsafe("status lock is poisoned"))?
            .clone();
        let encoded = serde_json::to_vec_pretty(&document)?;
        if encoded.len() as u64 > MAX_STATUS_BYTES {
            return Err(StatusError::Unsafe("encoded status exceeds the size limit"));
        }
        let parent = self
            .path
            .parent()
            .ok_or(StatusError::Unsafe("path must have a parent directory"))?;
        ensure_status_directory(parent)?;
        validate_existing_status_file(&self.path)?;
        let temporary = parent.join(format!(".agent-manager-status.{}.tmp", Uuid::new_v4()));
        let write_result = (|| -> Result<(), StatusError> {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o640)
                .open(&temporary)?;
            file.write_all(&encoded)?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            fs::rename(&temporary, &self.path)?;
            fs::set_permissions(&self.path, fs::Permissions::from_mode(0o640))?;
            File::open(parent)?.sync_all()?;
            Ok(())
        })();
        if write_result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        write_result
    }
}

fn ensure_status_directory(path: &Path) -> Result<(), StatusError> {
    if !path.is_absolute() {
        return Err(StatusError::Unsafe("directory must be absolute"));
    }
    match fs::symlink_metadata(path) {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir_all(path)?;
            fs::set_permissions(path, fs::Permissions::from_mode(0o750))?;
        }
        Err(error) => return Err(StatusError::Io(error)),
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_dir() {
        return Err(StatusError::Unsafe("parent is not a directory"));
    }
    if metadata.permissions().mode() & 0o007 != 0 {
        return Err(StatusError::Unsafe(
            "directory must not be world-accessible",
        ));
    }
    Ok(())
}

fn validate_existing_status_file(path: &Path) -> Result<bool, StatusError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(StatusError::Io(error)),
    };
    if !metadata.file_type().is_file() {
        return Err(StatusError::Unsafe("status must be a regular file"));
    }
    if metadata.permissions().mode() & 0o007 != 0 {
        return Err(StatusError::Unsafe("status must not be world-accessible"));
    }
    Ok(true)
}

fn timestamp() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_owned())
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::{PermissionsExt, symlink};

    use super::{StatusError, StatusStore};

    #[test]
    fn status_is_non_world_accessible_and_rejects_symlinks() {
        let directory = std::env::temp_dir().join(format!(
            "agent-manager-status-test-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir(&directory).expect("create status test directory");
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o750))
            .expect("protect status test directory");
        let path = directory.join("status.json");
        let store = StatusStore::open(path.clone()).expect("open status store");
        store
            .success("running", 2, 128)
            .expect("write successful status");
        assert_eq!(
            fs::metadata(&path)
                .expect("status metadata")
                .permissions()
                .mode()
                & 0o007,
            0
        );
        let document: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&path).expect("read status"))
                .expect("status JSON");
        assert_eq!(document["object_count"], 2);
        assert_eq!(document["byte_count"], 128);

        fs::remove_file(&path).expect("remove status fixture");
        symlink(directory.join("missing-target"), &path).expect("create dangling status symlink");
        assert!(matches!(
            StatusStore::open(path),
            Err(StatusError::Unsafe("status must be a regular file"))
        ));
        fs::remove_dir_all(directory).expect("remove status test directory");
    }
}
