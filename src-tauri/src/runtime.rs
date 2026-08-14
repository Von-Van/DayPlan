use crate::agent::{OllamaStatus, PlannerAgent, MODEL_NAME};
use crate::error::{AppError, AppResult};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use std::fs;
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::process::{Child, Command};
use tokio_util::sync::CancellationToken;

pub const BUNDLED_OLLAMA_VERSION: &str = "0.32.0";
const START_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_PULL_RESPONSE_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RuntimePhase {
    Unavailable,
    Starting,
    ReadyWithoutModel,
    Downloading,
    ModelReady,
    UpdateRequired,
    Error,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadProgress {
    pub completed: u64,
    pub total: Option<u64>,
    pub percent: Option<u8>,
    pub status: String,
}

struct RuntimeState {
    child: Option<Child>,
    phase: RuntimePhase,
    detail: String,
    download: Option<DownloadProgress>,
    download_cancel: Option<CancellationToken>,
}

impl Default for RuntimeState {
    fn default() -> Self {
        Self {
            child: None,
            phase: RuntimePhase::Unavailable,
            detail: "The bundled local AI runtime has not started.".into(),
            download: None,
            download_cancel: None,
        }
    }
}

struct RuntimeInner {
    endpoint: String,
    host: String,
    runtime_dir: PathBuf,
    model_dir: PathBuf,
    state: Mutex<RuntimeState>,
    lifecycle: tokio::sync::Mutex<()>,
}

impl Drop for RuntimeInner {
    fn drop(&mut self) {
        if let Ok(state) = self.state.get_mut() {
            if let Some(child) = state.child.as_mut() {
                let _ = child.start_kill();
            }
        }
    }
}

#[derive(Clone)]
pub struct OllamaRuntimeManager {
    inner: Arc<RuntimeInner>,
}

impl OllamaRuntimeManager {
    pub fn new(resource_dir: PathBuf, app_data_dir: PathBuf) -> AppResult<Self> {
        let port = reserve_loopback_port()?;
        Self::new_with_port(resource_dir, app_data_dir, port)
    }

    fn new_with_port(resource_dir: PathBuf, app_data_dir: PathBuf, port: u16) -> AppResult<Self> {
        let host = format!("127.0.0.1:{port}");
        let model_dir = app_data_dir.join("ai-models");
        fs::create_dir_all(&model_dir)?;
        Ok(Self {
            inner: Arc::new(RuntimeInner {
                endpoint: format!("http://{host}"),
                host,
                runtime_dir: resource_dir.join("resources").join("ollama"),
                model_dir,
                state: Mutex::new(RuntimeState::default()),
                lifecycle: tokio::sync::Mutex::new(()),
            }),
        })
    }

    pub fn endpoint(&self) -> &str {
        &self.inner.endpoint
    }

    pub fn model_dir(&self) -> &Path {
        &self.inner.model_dir
    }

    pub async fn ensure_started(&self, agent: &PlannerAgent) -> AppResult<()> {
        let _lifecycle = self.inner.lifecycle.lock().await;
        let child_is_running = {
            let mut state = self.lock_state()?;
            match state.child.as_mut() {
                Some(child) => child.try_wait()?.is_none(),
                None => false,
            }
        };
        if child_is_running && agent.status().await.running {
            return Ok(());
        }
        self.stop_locked().await?;
        let binary = self.binary_path();
        if !binary.is_file() {
            self.set_failure(
                RuntimePhase::Unavailable,
                "The signed DayPlan package does not contain its local AI runtime.",
            );
            return Err(AppError::OllamaRuntime(format!(
                "missing {}",
                binary.display()
            )));
        }

        self.set_phase(
            RuntimePhase::Starting,
            "Starting DayPlan's local AI runtime…",
        );
        let mut command = Command::new(&binary);
        command
            .arg("serve")
            .current_dir(binary.parent().unwrap_or(&self.inner.runtime_dir))
            .env("OLLAMA_HOST", &self.inner.host)
            .env("OLLAMA_MODELS", &self.inner.model_dir)
            .env("OLLAMA_NOHISTORY", "1")
            .env("OLLAMA_NO_CLOUD", "1")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(if cfg!(debug_assertions) {
                Stdio::inherit()
            } else {
                Stdio::null()
            })
            .kill_on_drop(true);
        let child = command.spawn().map_err(|error| {
            self.set_failure(
                RuntimePhase::Error,
                "The bundled AI runtime could not start.",
            );
            AppError::OllamaRuntime(error.to_string())
        })?;
        self.lock_state()?.child = Some(child);

        let deadline = tokio::time::Instant::now() + START_TIMEOUT;
        while tokio::time::Instant::now() < deadline {
            let status = agent.status().await;
            if status.running {
                if status.ollama_version.as_deref() != Some(BUNDLED_OLLAMA_VERSION) {
                    self.set_failure(
                        RuntimePhase::UpdateRequired,
                        "The bundled AI runtime version does not match this DayPlan release.",
                    );
                    self.stop_locked().await?;
                    return Err(AppError::OllamaRuntime("runtime version mismatch".into()));
                }
                self.set_phase(
                    if status.model_installed {
                        RuntimePhase::ModelReady
                    } else {
                        RuntimePhase::ReadyWithoutModel
                    },
                    &status.detail,
                );
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        self.stop_locked().await?;
        self.set_failure(
            RuntimePhase::Error,
            "The bundled AI runtime did not become ready in time.",
        );
        Err(AppError::OllamaUnavailable)
    }

    pub async fn status(&self, agent: &PlannerAgent) -> OllamaStatus {
        if let Err(error) = self.ensure_started(agent).await {
            let state = self.lock_state().ok();
            return OllamaStatus {
                phase: state
                    .as_ref()
                    .map_or(RuntimePhase::Error, |value| value.phase),
                running: false,
                model_installed: false,
                model_name: MODEL_NAME.into(),
                model_digest: None,
                ollama_version: Some(BUNDLED_OLLAMA_VERSION.into()),
                model_license: None,
                detail: state
                    .as_ref()
                    .map(|value| value.detail.clone())
                    .unwrap_or_else(|| error.to_string()),
                download: None,
                storage_bytes: directory_size(&self.inner.model_dir).ok(),
            };
        }
        let mut status = agent.status().await;
        let state = self.lock_state().ok();
        status.phase = state.as_ref().map_or(
            if status.model_installed {
                RuntimePhase::ModelReady
            } else {
                RuntimePhase::ReadyWithoutModel
            },
            |value| value.phase,
        );
        status.download = state.and_then(|value| value.download.clone());
        status.storage_bytes = directory_size(&self.inner.model_dir).ok();
        status
    }

    pub async fn pull_model(&self, agent: &PlannerAgent) -> AppResult<()> {
        self.ensure_started(agent).await?;
        let token = CancellationToken::new();
        {
            let mut state = self.lock_state()?;
            if state.download_cancel.is_some() {
                return Err(AppError::Validation(
                    "A model download is already running.".into(),
                ));
            }
            state.phase = RuntimePhase::Downloading;
            state.detail = "Downloading qwen3:8b…".into();
            state.download = Some(DownloadProgress {
                status: "starting".into(),
                ..Default::default()
            });
            state.download_cancel = Some(token.clone());
        }
        let mut result = self.pull_model_inner(token).await;
        if result.is_ok() {
            let installed = agent.status().await;
            if !installed.model_installed || installed.model_digest.is_none() {
                result = Err(AppError::OllamaRuntime(
                    "download completed without a verifiable model digest".into(),
                ));
            }
        }
        let mut state = self.lock_state()?;
        state.download_cancel = None;
        match &result {
            Ok(()) => {
                state.phase = RuntimePhase::ModelReady;
                state.detail = "DayPlan's local qwen3:8b model is ready.".into();
                state.download = None;
            }
            Err(AppError::ModelDownloadCancelled) => {
                state.phase = RuntimePhase::ReadyWithoutModel;
                state.detail =
                    "Model download cancelled. Downloaded layers are retained for retry.".into();
                state.download = None;
            }
            Err(error) => {
                state.phase = RuntimePhase::Error;
                state.detail = format!("Model download failed: {error}");
            }
        }
        result
    }

    async fn pull_model_inner(&self, token: CancellationToken) -> AppResult<()> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(60 * 60))
            .build()?;
        let response = client
            .post(format!("{}/api/pull", self.inner.endpoint))
            .json(&serde_json::json!({ "model": MODEL_NAME, "stream": true }))
            .send()
            .await?;
        if !response.status().is_success() {
            return Err(AppError::OllamaUnavailable);
        }
        let mut stream = response.bytes_stream();
        let mut buffered = Vec::new();
        let mut received = 0_u64;
        loop {
            let chunk = tokio::select! {
                _ = token.cancelled() => return Err(AppError::ModelDownloadCancelled),
                value = stream.next() => value,
            };
            let Some(chunk) = chunk else { break };
            let chunk = chunk?;
            received = received.saturating_add(chunk.len() as u64);
            if received > MAX_PULL_RESPONSE_BYTES {
                return Err(AppError::OllamaRuntime(
                    "model download response exceeded its safety limit".into(),
                ));
            }
            buffered.extend_from_slice(&chunk);
            while let Some(position) = buffered.iter().position(|byte| *byte == b'\n') {
                let line = buffered.drain(..=position).collect::<Vec<_>>();
                if let Ok(update) = serde_json::from_slice::<PullUpdate>(&line) {
                    if let Some(error) = update.error {
                        return Err(AppError::OllamaRuntime(error));
                    }
                    let percent = update.total.filter(|total| *total > 0).map(|total| {
                        ((update.completed.unwrap_or(0).saturating_mul(100) / total).min(100)) as u8
                    });
                    self.lock_state()?.download = Some(DownloadProgress {
                        completed: update.completed.unwrap_or(0),
                        total: update.total,
                        percent,
                        status: update.status,
                    });
                }
            }
        }
        Ok(())
    }

    pub fn cancel_download(&self) {
        if let Ok(state) = self.inner.state.lock() {
            if let Some(token) = &state.download_cancel {
                token.cancel();
            }
        }
    }

    pub async fn restart(&self, agent: &PlannerAgent) -> AppResult<()> {
        self.cancel_download();
        self.stop().await?;
        self.ensure_started(agent).await
    }

    pub async fn remove_model(&self) -> AppResult<()> {
        self.cancel_download();
        self.stop().await?;
        if self.inner.model_dir.exists() {
            fs::remove_dir_all(&self.inner.model_dir)?;
        }
        fs::create_dir_all(&self.inner.model_dir)?;
        self.set_phase(
            RuntimePhase::Unavailable,
            "Local AI model data was removed.",
        );
        Ok(())
    }

    async fn stop(&self) -> AppResult<()> {
        let _lifecycle = self.inner.lifecycle.lock().await;
        self.stop_locked().await
    }

    async fn stop_locked(&self) -> AppResult<()> {
        let child = self.lock_state()?.child.take();
        if let Some(mut child) = child {
            let _ = child.kill().await;
            let _ = child.wait().await;
        }
        Ok(())
    }

    fn binary_path(&self) -> PathBuf {
        if let Some(path) = std::env::var_os("DAYPLAN_OLLAMA_RUNTIME") {
            return PathBuf::from(path);
        }
        let relative = if cfg!(windows) {
            "ollama.exe"
        } else {
            "ollama"
        };
        self.inner
            .runtime_dir
            .join(platform_directory())
            .join(relative)
    }

    fn lock_state(&self) -> AppResult<std::sync::MutexGuard<'_, RuntimeState>> {
        self.inner
            .state
            .lock()
            .map_err(|_| AppError::Internal("The local AI runtime state is unavailable.".into()))
    }

    fn set_phase(&self, phase: RuntimePhase, detail: &str) {
        if let Ok(mut state) = self.inner.state.lock() {
            state.phase = phase;
            state.detail = detail.into();
        }
    }

    fn set_failure(&self, phase: RuntimePhase, detail: &str) {
        self.set_phase(phase, detail);
    }
}

#[derive(Deserialize)]
struct PullUpdate {
    #[serde(default)]
    status: String,
    completed: Option<u64>,
    total: Option<u64>,
    error: Option<String>,
}

fn reserve_loopback_port() -> std::io::Result<u16> {
    TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0))?
        .local_addr()
        .map(|address| address.port())
}

fn platform_directory() -> &'static str {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") | ("macos", "x86_64") => "macos-universal",
        ("windows", "x86_64") => "windows-x86_64",
        _ => "unsupported",
    }
}

fn directory_size(path: &Path) -> std::io::Result<u64> {
    let mut total = 0_u64;
    if !path.exists() {
        return Ok(0);
    }
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let metadata = entry.metadata()?;
        total = total.saturating_add(if metadata.is_dir() {
            directory_size(&entry.path())?
        } else {
            metadata.len()
        });
    }
    Ok(total)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reserves_private_loopback_port() {
        match reserve_loopback_port() {
            Ok(port) => assert_ne!(port, 11434),
            Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {}
            Err(error) => panic!("could not reserve loopback port: {error}"),
        }
    }

    #[test]
    fn model_storage_is_isolated() {
        let root = tempfile::tempdir().unwrap();
        let manager = OllamaRuntimeManager::new_with_port(
            root.path().join("resources"),
            root.path().join("data"),
            49_152,
        )
        .unwrap();
        assert_eq!(manager.model_dir(), root.path().join("data/ai-models"));
        assert_ne!(manager.endpoint(), "http://127.0.0.1:11434");
        assert_eq!(
            manager.binary_path(),
            root.path()
                .join("resources/resources/ollama")
                .join(platform_directory())
                .join(if cfg!(windows) {
                    "ollama.exe"
                } else {
                    "ollama"
                })
        );
    }
}
