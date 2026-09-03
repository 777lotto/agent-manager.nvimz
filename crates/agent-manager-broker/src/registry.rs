//! Owner-only metadata registry for the durable broker.

use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

use crate::protocol::{
    AgentState, AgentSummary, ManagedWorkspace, Provider, ProviderRuntime, WorkspaceStrategy,
};

const REGISTRY_SCHEMA_VERSION: u32 = 1;
const MAX_REGISTRY_BYTES: u64 = 8 * 1024 * 1024;
const MAX_REGISTRY_AGENTS: usize = 10_000;

#[derive(Debug, Error)]
pub enum RegistryError {
    #[error("registry I/O failed: {0}")]
    Io(#[from] io::Error),
    #[error("registry JSON is invalid: {0}")]
    Json(#[from] serde_json::Error),
    #[error("registry path is unsafe: {0}")]
    Unsafe(&'static str),
}

#[derive(Clone, Debug)]
pub(crate) struct RegistryStore {
    path: PathBuf,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct RegistryDocument {
    schema_version: u32,
    updated_at: String,
    agents: Vec<RegistryAgent>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct RegistryAgent {
    id: String,
    provider: Provider,
    provider_session_id: Option<String>,
    cwd: String,
    workspace_strategy: WorkspaceStrategy,
    worktree_path: Option<String>,
    #[serde(default)]
    managed_workspace: Option<ManagedWorkspace>,
    #[serde(default)]
    runtime: Option<ProviderRuntime>,
    title: String,
    state: AgentState,
    created_at: String,
    updated_at: String,
    #[serde(
        default,
        rename = "provider_runtime_version",
        skip_serializing_if = "Option::is_none"
    )]
    legacy_provider_runtime_version: Option<String>,
}

impl RegistryStore {
    pub(crate) fn open(path: PathBuf) -> Result<Self, RegistryError> {
        if !path.is_absolute() {
            return Err(RegistryError::Unsafe("path must be absolute"));
        }
        let parent = path
            .parent()
            .ok_or(RegistryError::Unsafe("path must have a parent directory"))?;
        ensure_private_directory(parent)?;
        validate_existing_private_file(&path)?;
        Ok(Self { path })
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn bytes(&self) -> u64 {
        fs::metadata(&self.path).map_or(0, |metadata| metadata.len())
    }

    pub(crate) fn load(&self) -> Result<Vec<AgentSummary>, RegistryError> {
        if !validate_existing_private_file(&self.path)? {
            return Ok(Vec::new());
        }
        let file = File::open(&self.path)?;
        let metadata = file.metadata()?;
        if metadata.len() > MAX_REGISTRY_BYTES {
            return Err(RegistryError::Unsafe("file exceeds the size limit"));
        }
        let capacity = usize::try_from(metadata.len())
            .map_err(|_| RegistryError::Unsafe("file size exceeds platform limits"))?;
        let mut encoded = Vec::with_capacity(capacity);
        file.take(MAX_REGISTRY_BYTES + 1)
            .read_to_end(&mut encoded)?;
        if encoded.len() as u64 > MAX_REGISTRY_BYTES {
            return Err(RegistryError::Unsafe("file exceeds the size limit"));
        }
        let document: RegistryDocument = serde_json::from_slice(&encoded)?;
        if document.schema_version != REGISTRY_SCHEMA_VERSION {
            return Err(RegistryError::Unsafe("schema version is unsupported"));
        }
        if document.agents.len() > MAX_REGISTRY_AGENTS {
            return Err(RegistryError::Unsafe("agent count exceeds the limit"));
        }
        let mut ids = HashSet::new();
        document
            .agents
            .into_iter()
            .map(|agent| {
                if !ids.insert(agent.id.clone()) {
                    return Err(RegistryError::Unsafe("agent IDs must be unique"));
                }
                agent.into_disconnected_summary()
            })
            .collect()
    }

    pub(crate) fn persist(&self, agents: &[AgentSummary]) -> Result<(), RegistryError> {
        if agents.len() > MAX_REGISTRY_AGENTS {
            return Err(RegistryError::Unsafe("agent count exceeds the limit"));
        }
        validate_existing_private_file(&self.path)?;
        let document = RegistryDocument {
            schema_version: REGISTRY_SCHEMA_VERSION,
            updated_at: timestamp(),
            agents: agents.iter().map(RegistryAgent::from).collect(),
        };
        let encoded = serde_json::to_vec_pretty(&document)?;
        if encoded.len() as u64 > MAX_REGISTRY_BYTES {
            return Err(RegistryError::Unsafe(
                "encoded registry exceeds the size limit",
            ));
        }
        let parent = self
            .path
            .parent()
            .ok_or(RegistryError::Unsafe("path must have a parent directory"))?;
        ensure_private_directory(parent)?;
        let temporary = parent.join(format!(
            ".{}.{}.tmp",
            self.path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("registry"),
            Uuid::new_v4()
        ));
        let write_result = (|| -> Result<(), RegistryError> {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temporary)?;
            file.write_all(&encoded)?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            fs::rename(&temporary, &self.path)?;
            fs::set_permissions(&self.path, fs::Permissions::from_mode(0o600))?;
            File::open(parent)?.sync_all()?;
            Ok(())
        })();
        if write_result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        write_result
    }
}

impl From<&AgentSummary> for RegistryAgent {
    fn from(summary: &AgentSummary) -> Self {
        Self {
            id: summary.id.clone(),
            provider: summary.provider,
            provider_session_id: summary.provider_session_id.clone(),
            cwd: summary.cwd.clone(),
            workspace_strategy: summary.workspace_strategy,
            worktree_path: summary.worktree_path.clone(),
            managed_workspace: summary.managed_workspace.clone(),
            runtime: summary.runtime.clone(),
            title: summary.title.clone(),
            state: summary.state,
            created_at: summary.created_at.clone(),
            updated_at: summary.updated_at.clone(),
            legacy_provider_runtime_version: None,
        }
    }
}

impl RegistryAgent {
    fn into_disconnected_summary(self) -> Result<AgentSummary, RegistryError> {
        if self.id.is_empty()
            || self.id.len() > 256
            || self.cwd.is_empty()
            || self.cwd.len() > 8_192
            || !Path::new(&self.cwd).is_absolute()
            || self.title.len() > 4_096
            || self
                .provider_session_id
                .as_ref()
                .is_some_and(|session| session.is_empty() || session.len() > 1_024)
            || self
                .legacy_provider_runtime_version
                .as_ref()
                .is_some_and(|version| version.len() > 1_024)
            || !valid_managed_workspace(self.managed_workspace.as_ref())
            || !valid_runtime(self.runtime.as_ref())
        {
            return Err(RegistryError::Unsafe("agent metadata is invalid"));
        }
        match (self.workspace_strategy, self.worktree_path.as_deref()) {
            (WorkspaceStrategy::Shared, None) if self.managed_workspace.is_none() => {}
            (WorkspaceStrategy::Worktree, Some(path))
                if !path.is_empty() && path.len() <= 8_192 && Path::new(path).is_absolute() => {}
            _ => return Err(RegistryError::Unsafe("workspace metadata is inconsistent")),
        }
        Ok(AgentSummary {
            id: self.id,
            provider: self.provider,
            provider_session_id: self.provider_session_id,
            cwd: self.cwd,
            workspace_strategy: self.workspace_strategy,
            worktree_path: self.worktree_path,
            managed_workspace: self.managed_workspace,
            runtime: self.runtime,
            title: self.title,
            state: AgentState::Disconnected,
            active_turn_id: None,
            pending_approvals: 0,
            unread_events: 0,
            capabilities: Vec::new(),
            created_at: self.created_at,
            updated_at: self.updated_at,
        })
    }
}

fn valid_managed_workspace(workspace: Option<&ManagedWorkspace>) -> bool {
    workspace.is_none_or(|workspace| {
        !workspace.repository.is_empty()
            && workspace.repository.len() <= 128
            && !workspace.task_id.is_empty()
            && workspace.task_id.len() <= 128
            && workspace.branch == format!("agent/{}", workspace.task_id)
            && !workspace.base_branch.is_empty()
            && workspace.base_branch.len() <= 256
    })
}

fn valid_runtime(runtime: Option<&ProviderRuntime>) -> bool {
    runtime.is_none_or(|runtime| {
        !runtime.compatibility_profile.is_empty()
            && runtime.compatibility_profile.len() <= 256
            && !runtime.provider_version.is_empty()
            && runtime.provider_version.len() <= 256
            && runtime
                .adapter_version
                .as_ref()
                .is_none_or(|version| !version.is_empty() && version.len() <= 256)
            && runtime.executable.as_ref().is_none_or(|path| {
                !path.is_empty() && path.len() <= 8_192 && Path::new(path).is_absolute()
            })
    })
}

pub(crate) fn ensure_private_directory(path: &Path) -> Result<(), RegistryError> {
    if !path.is_absolute() {
        return Err(RegistryError::Unsafe("directory must be absolute"));
    }
    match fs::symlink_metadata(path) {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir_all(path)?;
            fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
        }
        Err(error) => return Err(RegistryError::Io(error)),
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_dir() {
        return Err(RegistryError::Unsafe("parent is not a directory"));
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(RegistryError::Unsafe("directory must be owner-only"));
    }
    Ok(())
}

fn validate_existing_private_file(path: &Path) -> Result<bool, RegistryError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(RegistryError::Io(error)),
    };
    if !metadata.file_type().is_file() {
        return Err(RegistryError::Unsafe("registry must be a regular file"));
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(RegistryError::Unsafe("registry file must be owner-only"));
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
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::fs::symlink;

    use super::{RegistryError, RegistryStore};
    use crate::protocol::{AgentState, AgentSummary, Provider, ProviderRuntime, WorkspaceStrategy};

    #[test]
    fn registry_round_trip_contains_metadata_only() {
        let directory = std::env::temp_dir().join(format!(
            "agent-manager-registry-test-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir(&directory).expect("create test directory");
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
            .expect("protect test directory");
        let path = directory.join("registry.json");
        let store = RegistryStore::open(path.clone()).expect("open registry");
        store
            .persist(&[AgentSummary {
                id: "agent-1".to_owned(),
                provider: Provider::Codex,
                provider_session_id: Some("thread-1".to_owned()),
                cwd: "/workspace/project".to_owned(),
                workspace_strategy: WorkspaceStrategy::Shared,
                worktree_path: None,
                managed_workspace: None,
                runtime: Some(ProviderRuntime {
                    compatibility_profile: "codex-app-server-stable-v1".to_owned(),
                    provider_version: "0.153.0".to_owned(),
                    adapter_version: None,
                    executable: Some("/home/ai/.local/bin/codex".to_owned()),
                }),
                title: "project".to_owned(),
                state: AgentState::Running,
                active_turn_id: Some("turn-secret-payload".to_owned()),
                pending_approvals: 1,
                unread_events: 4,
                capabilities: Vec::new(),
                created_at: "2026-09-02T00:00:00Z".to_owned(),
                updated_at: "2026-09-02T00:01:00Z".to_owned(),
            }])
            .expect("persist registry");
        let encoded = fs::read_to_string(&path).expect("read registry");
        assert!(!encoded.contains("turn-secret-payload"));
        assert_eq!(
            fs::metadata(&path)
                .expect("registry metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let loaded = store.load().expect("load registry");
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].state, AgentState::Disconnected);
        assert_eq!(loaded[0].provider_session_id.as_deref(), Some("thread-1"));
        assert_eq!(
            loaded[0]
                .runtime
                .as_ref()
                .map(|runtime| runtime.provider_version.as_str()),
            Some("0.153.0")
        );
        fs::remove_file(&path).expect("remove registry fixture");
        symlink(directory.join("missing-target"), &path).expect("create dangling registry symlink");
        assert!(matches!(
            RegistryStore::open(path),
            Err(RegistryError::Unsafe("registry must be a regular file"))
        ));
        fs::remove_dir_all(directory).expect("remove test directory");
    }
}
