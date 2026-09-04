//! Adapter for the workstation's authoritative repository/worktree lifecycle.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::process::Command;

use crate::protocol::ManagedWorkspace;

const AUDIT_SCHEMA_VERSION: u32 = 1;
const COMMAND_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_AUDIT_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceCommandSpec {
    pub program: String,
}

impl Default for WorkspaceCommandSpec {
    fn default() -> Self {
        Self {
            program: "zemrip-agent-workspace".to_owned(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct WorkspaceLifecycle {
    command: WorkspaceCommandSpec,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct WorkspaceInventory {
    pub schema_version: u32,
    pub generated_at: String,
    pub registry: String,
    pub repositories: Vec<RepositorySummary>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RepositorySummary {
    pub slug: String,
    pub github: String,
    pub canonical_path: String,
    pub base_branch: String,
    pub canonical_branch: Option<String>,
    pub canonical_clean: bool,
    pub worktree_root: String,
    pub tasks: Vec<TaskSummary>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct TaskSummary {
    pub task_id: String,
    pub branch: String,
    pub path: String,
    pub head: Option<String>,
    pub upstream: Option<String>,
    pub lease_identity: Vec<String>,
    pub lease_keep: Option<String>,
    pub lease_transition: Option<String>,
    pub cleanup_candidate: bool,
    pub reasons: Vec<String>,
}

#[derive(Debug, Error)]
pub enum WorkspaceError {
    #[error("workspace lifecycle command could not be started")]
    Spawn,
    #[error("workspace lifecycle command timed out")]
    Timeout,
    #[error("workspace lifecycle command refused the request")]
    Refused,
    #[error("workspace lifecycle audit exceeded the size limit")]
    TooLarge,
    #[error("workspace lifecycle audit returned invalid JSON")]
    InvalidJson,
    #[error("workspace lifecycle audit schema is unsupported")]
    UnsupportedSchema,
    #[error("workspace repository or task identifier is invalid")]
    InvalidIdentifier,
    #[error("workspace lifecycle returned unsafe repository metadata")]
    UnsafeRepository,
    #[error("workspace lifecycle did not return the claimed task")]
    MissingTask,
}

#[derive(Debug, Deserialize)]
struct AuditDocument {
    schema_version: u32,
    generated_at: String,
    registry: String,
    repositories: Vec<AuditRepository>,
}

#[derive(Debug, Deserialize)]
struct AuditRepository {
    slug: String,
    github: String,
    canonical: AuditCanonical,
    worktree_root: String,
    worktrees: Vec<AuditWorktree>,
}

#[derive(Debug, Deserialize)]
struct AuditCanonical {
    path: String,
    base_branch: String,
    branch: Option<String>,
    clean: bool,
}

#[derive(Debug, Deserialize)]
struct AuditWorktree {
    task_id: Option<String>,
    branch: Option<String>,
    path: String,
    head: Option<String>,
    upstream: Option<String>,
    #[serde(default)]
    lease_identity: Vec<String>,
    lease_keep: Option<String>,
    lease_transition: Option<String>,
    cleanup_candidate: bool,
    #[serde(default)]
    reasons: Vec<String>,
}

#[derive(Debug, Eq, PartialEq)]
struct ClaimReceipt {
    path: String,
    branch: String,
}

impl WorkspaceLifecycle {
    #[must_use]
    pub fn new(command: WorkspaceCommandSpec) -> Self {
        Self { command }
    }

    pub async fn inventory(&self) -> Result<WorkspaceInventory, WorkspaceError> {
        self.audit(None).await
    }

    pub async fn claim(
        &self,
        repository: &str,
        task_id: &str,
        resume: bool,
    ) -> Result<(String, ManagedWorkspace), WorkspaceError> {
        validate_repository(repository)?;
        validate_task(task_id)?;
        let owner_pid = std::process::id().to_string();
        let mut arguments = vec!["claim", repository, task_id, "--owner-pid", &owner_pid];
        if resume {
            arguments.push("--resume");
        }
        let output = self.run(&arguments).await?;
        if let Ok(receipt) = parse_claim_receipt(&output, repository, task_id)
            && let Ok(base_branch) = validate_claim_receipt(&receipt, repository, task_id).await
        {
            return Ok((
                receipt.path,
                ManagedWorkspace {
                    repository: repository.to_owned(),
                    task_id: task_id.to_owned(),
                    branch: receipt.branch,
                    base_branch,
                },
            ));
        }

        // Older lifecycle implementations did not emit a machine-readable
        // claim receipt. Keep their safe, albeit expensive, audit projection
        // as a compatibility fallback.
        let inventory = match self.audit(Some(repository)).await {
            Ok(inventory) => inventory,
            Err(error) => {
                let _ = self.handoff(repository, task_id).await;
                return Err(error);
            }
        };
        let Some(repository_summary) = inventory
            .repositories
            .into_iter()
            .find(|candidate| candidate.slug == repository)
        else {
            let _ = self.handoff(repository, task_id).await;
            return Err(WorkspaceError::UnsafeRepository);
        };
        let Some(task) = repository_summary
            .tasks
            .into_iter()
            .find(|candidate| candidate.task_id == task_id)
        else {
            let _ = self.handoff(repository, task_id).await;
            return Err(WorkspaceError::MissingTask);
        };
        if task.branch != format!("agent/{task_id}") || !Path::new(&task.path).is_absolute() {
            let _ = self.handoff(repository, task_id).await;
            return Err(WorkspaceError::MissingTask);
        }
        Ok((
            task.path,
            ManagedWorkspace {
                repository: repository_summary.slug,
                task_id: task_id.to_owned(),
                branch: task.branch,
                base_branch: repository_summary.base_branch,
            },
        ))
    }

    pub async fn handoff(&self, repository: &str, task_id: &str) -> Result<(), WorkspaceError> {
        validate_repository(repository)?;
        validate_task(task_id)?;
        let owner_pid = std::process::id().to_string();
        self.run(&["handoff", repository, task_id, "--owner-pid", &owner_pid])
            .await
            .map(|_| ())
    }

    async fn audit(&self, repository: Option<&str>) -> Result<WorkspaceInventory, WorkspaceError> {
        if let Some(repository) = repository {
            validate_repository(repository)?;
        }
        let output = match repository {
            Some(repository) => self.run(&["audit", repository, "--json"]).await?,
            None => self.run(&["audit", "--json"]).await?,
        };
        if output.len() > MAX_AUDIT_BYTES {
            return Err(WorkspaceError::TooLarge);
        }
        let document: AuditDocument =
            serde_json::from_slice(&output).map_err(|_| WorkspaceError::InvalidJson)?;
        project_inventory(document)
    }

    async fn run(&self, arguments: &[&str]) -> Result<Vec<u8>, WorkspaceError> {
        let mut command = Command::new(&self.command.program);
        command
            .args(arguments)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        let output = tokio::time::timeout(COMMAND_TIMEOUT, command.output())
            .await
            .map_err(|_| WorkspaceError::Timeout)?
            .map_err(|_| WorkspaceError::Spawn)?;
        if !output.status.success() {
            return Err(WorkspaceError::Refused);
        }
        Ok(output.stdout)
    }
}

fn parse_claim_receipt(
    output: &[u8],
    repository: &str,
    task_id: &str,
) -> Result<ClaimReceipt, WorkspaceError> {
    let output = std::str::from_utf8(output).map_err(|_| WorkspaceError::UnsafeRepository)?;
    let first_line = output.lines().next().ok_or(WorkspaceError::MissingTask)?;
    let prefix = format!("claimed: {repository}/{task_id}: ");
    let branch = format!("agent/{task_id}");
    let suffix = format!(" branch={branch} lease=held");
    let path = first_line
        .strip_prefix(&prefix)
        .and_then(|line| line.strip_suffix(&suffix))
        .filter(|path| !path.is_empty())
        .ok_or(WorkspaceError::MissingTask)?;
    Ok(ClaimReceipt {
        path: path.to_owned(),
        branch,
    })
}

async fn validate_claim_receipt(
    receipt: &ClaimReceipt,
    repository: &str,
    task_id: &str,
) -> Result<String, WorkspaceError> {
    let path = Path::new(&receipt.path);
    if !path.is_absolute()
        || path.file_name().and_then(|name| name.to_str()) != Some(task_id)
        || path
            .parent()
            .and_then(Path::file_name)
            .and_then(|name| name.to_str())
            != Some(repository)
    {
        return Err(WorkspaceError::UnsafeRepository);
    }
    let canonical = path
        .canonicalize()
        .map_err(|_| WorkspaceError::UnsafeRepository)?;
    if canonical != path || !canonical.is_dir() {
        return Err(WorkspaceError::UnsafeRepository);
    }
    let marker = fs::symlink_metadata(canonical.join(".git"))
        .map_err(|_| WorkspaceError::UnsafeRepository)?;
    if !marker.file_type().is_file() || marker.len() > 8_192 {
        return Err(WorkspaceError::UnsafeRepository);
    }

    let top_level = git_value(&canonical, &["rev-parse", "--show-toplevel"]).await?;
    let top_level = Path::new(&top_level)
        .canonicalize()
        .map_err(|_| WorkspaceError::UnsafeRepository)?;
    let git_directory = git_path(&canonical, "--git-dir").await?;
    let common_directory = git_path(&canonical, "--git-common-dir").await?;
    if top_level != canonical || git_directory == common_directory {
        return Err(WorkspaceError::UnsafeRepository);
    }

    let branch = git_value(&canonical, &["symbolic-ref", "--quiet", "--short", "HEAD"]).await?;
    if branch != receipt.branch {
        return Err(WorkspaceError::MissingTask);
    }
    let merge_key = format!("branch.{}.merge", receipt.branch);
    let merge = git_value(&canonical, &["config", "--get", &merge_key]).await?;
    let base_branch = merge
        .strip_prefix("refs/heads/")
        .filter(|value| validate_repository(value).is_ok())
        .ok_or(WorkspaceError::UnsafeRepository)?;
    Ok(base_branch.to_owned())
}

async fn git_path(cwd: &Path, argument: &str) -> Result<PathBuf, WorkspaceError> {
    let raw = git_value(cwd, &["rev-parse", argument]).await?;
    let raw = Path::new(&raw);
    let path = if raw.is_absolute() {
        raw.to_owned()
    } else {
        cwd.join(raw)
    };
    path.canonicalize()
        .map_err(|_| WorkspaceError::UnsafeRepository)
}

async fn git_value(cwd: &Path, arguments: &[&str]) -> Result<String, WorkspaceError> {
    let mut command = Command::new("git");
    command
        .arg("-C")
        .arg(cwd)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let output = tokio::time::timeout(COMMAND_TIMEOUT, command.output())
        .await
        .map_err(|_| WorkspaceError::Timeout)?
        .map_err(|_| WorkspaceError::Spawn)?;
    if !output.status.success() || output.stdout.len() > 8_192 {
        return Err(WorkspaceError::UnsafeRepository);
    }
    let value = std::str::from_utf8(&output.stdout)
        .map_err(|_| WorkspaceError::UnsafeRepository)?
        .trim();
    if value.is_empty() {
        return Err(WorkspaceError::UnsafeRepository);
    }
    Ok(value.to_owned())
}

fn project_inventory(document: AuditDocument) -> Result<WorkspaceInventory, WorkspaceError> {
    if document.schema_version != AUDIT_SCHEMA_VERSION {
        return Err(WorkspaceError::UnsupportedSchema);
    }
    if document.registry.is_empty() || !Path::new(&document.registry).is_absolute() {
        return Err(WorkspaceError::UnsafeRepository);
    }
    let mut repositories = Vec::with_capacity(document.repositories.len());
    for repository in document.repositories {
        validate_repository(&repository.slug)?;
        if repository.github.is_empty()
            || repository.canonical.base_branch.is_empty()
            || !Path::new(&repository.canonical.path).is_absolute()
            || !Path::new(&repository.worktree_root).is_absolute()
        {
            return Err(WorkspaceError::UnsafeRepository);
        }
        let mut tasks = Vec::new();
        let worktree_root = Path::new(&repository.worktree_root);
        for worktree in repository.worktrees {
            let (Some(task_id), Some(branch)) = (worktree.task_id, worktree.branch) else {
                continue;
            };
            let worktree_path = Path::new(&worktree.path);
            if validate_task(&task_id).is_err()
                || branch != format!("agent/{task_id}")
                || !worktree_path.is_absolute()
                || worktree_path.parent() != Some(worktree_root)
                || worktree_path.file_name().and_then(|name| name.to_str())
                    != Some(task_id.as_str())
            {
                continue;
            }
            tasks.push(TaskSummary {
                task_id,
                branch,
                path: worktree.path,
                head: worktree.head,
                upstream: worktree.upstream,
                lease_identity: worktree.lease_identity,
                lease_keep: worktree.lease_keep,
                lease_transition: worktree.lease_transition,
                cleanup_candidate: worktree.cleanup_candidate,
                reasons: worktree.reasons,
            });
        }
        tasks.sort_by(|left, right| left.task_id.cmp(&right.task_id));
        repositories.push(RepositorySummary {
            slug: repository.slug,
            github: repository.github,
            canonical_path: repository.canonical.path,
            base_branch: repository.canonical.base_branch,
            canonical_branch: repository.canonical.branch,
            canonical_clean: repository.canonical.clean,
            worktree_root: repository.worktree_root,
            tasks,
        });
    }
    repositories.sort_by(|left, right| left.slug.cmp(&right.slug));
    Ok(WorkspaceInventory {
        schema_version: document.schema_version,
        generated_at: document.generated_at,
        registry: document.registry,
        repositories,
    })
}

fn validate_repository(value: &str) -> Result<(), WorkspaceError> {
    if valid_identifier(value, true) {
        Ok(())
    } else {
        Err(WorkspaceError::InvalidIdentifier)
    }
}

fn validate_task(value: &str) -> Result<(), WorkspaceError> {
    if valid_identifier(value, false) {
        Ok(())
    } else {
        Err(WorkspaceError::InvalidIdentifier)
    }
}

fn valid_identifier(value: &str, allow_dot: bool) -> bool {
    if value.is_empty() || value.len() > 128 {
        return false;
    }
    let mut previous_separator = true;
    for byte in value.bytes() {
        let separator = byte == b'-' || (allow_dot && byte == b'.');
        if byte.is_ascii_lowercase() || byte.is_ascii_digit() {
            previous_separator = false;
        } else if separator && !previous_separator {
            previous_separator = true;
        } else {
            return false;
        }
    }
    !previous_separator
}

#[cfg(test)]
mod tests {
    use super::{AuditDocument, ClaimReceipt, parse_claim_receipt, project_inventory};

    #[test]
    fn parses_only_the_exact_claim_receipt() {
        let receipt = parse_claim_receipt(
            b"claimed: agent-manager/fast-start: /home/ai/worktrees/agent-manager/fast-start branch=agent/fast-start lease=held\nhand off with: ignored\n",
            "agent-manager",
            "fast-start",
        )
        .expect("claim receipt");
        assert_eq!(
            receipt,
            ClaimReceipt {
                path: "/home/ai/worktrees/agent-manager/fast-start".to_owned(),
                branch: "agent/fast-start".to_owned(),
            }
        );
        assert!(
            parse_claim_receipt(
                b"claimed: other/fast-start: /tmp/fast-start branch=agent/fast-start lease=held\n",
                "agent-manager",
                "fast-start",
            )
            .is_err()
        );
    }

    #[test]
    fn projects_only_stable_task_mappings() {
        let document: AuditDocument = serde_json::from_value(serde_json::json!({
            "schema_version": 1,
            "generated_at": "2026-09-03T00:00:00Z",
            "registry": "/home/ai/.config/zemrip-agent/repositories.toml",
            "repositories": [{
                "slug": "agent-manager",
                "github": "owner/agent-manager.nvimz",
                "canonical": {
                    "path": "/home/ai/agent-manager",
                    "base_branch": "bluff",
                    "branch": "bluff",
                    "clean": true
                },
                "worktree_root": "/home/ai/worktrees/agent-manager",
                "worktrees": [
                    {
                        "task_id": "safe-task",
                        "branch": "agent/safe-task",
                        "path": "/home/ai/worktrees/agent-manager/safe-task",
                        "head": "abc",
                        "upstream": null,
                        "lease_identity": ["launcher:alive"],
                        "lease_keep": null,
                        "lease_transition": "claim-acquired",
                        "cleanup_candidate": false,
                        "reasons": []
                    },
                    {
                        "task_id": null,
                        "branch": "bluff",
                        "path": "/tmp/unmanaged",
                        "head": null,
                        "upstream": null,
                        "lease_identity": [],
                        "lease_keep": null,
                        "lease_transition": null,
                        "cleanup_candidate": false,
                        "reasons": ["unknown"]
                    }
                ]
            }]
        }))
        .expect("audit fixture");
        let inventory = project_inventory(document).expect("project inventory");
        assert_eq!(inventory.repositories[0].base_branch, "bluff");
        assert_eq!(inventory.repositories[0].tasks.len(), 1);
        assert_eq!(inventory.repositories[0].tasks[0].task_id, "safe-task");
    }
}
