use serde::Serialize;
use serde_json::Value;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("{0}")]
    Validation(String),
    #[error("The requested record no longer exists.")]
    NotFound,
    #[error("This schedule item changed after the proposal was created. Review the agenda and try again.")]
    Conflict,
    #[error("The local Ollama service could not be reached. Start Ollama, then make sure qwen3:8b is installed.")]
    OllamaUnavailable,
    #[error("Ollama returned an invalid planner response: {0}")]
    InvalidModelResponse(String),
    #[error("The local DayPlan database did not pass its integrity check. Restore a backup from Settings.")]
    CorruptDatabase,
    #[error("This DayPlan database was created by a newer app version.")]
    UnsupportedDatabaseVersion,
    #[error("The selected backup is not available.")]
    BackupNotFound,
    #[error(transparent)]
    Database(#[from] rusqlite::Error),
    #[error(transparent)]
    Network(#[from] reqwest::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

pub type AppResult<T> = Result<T, AppError>;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandError {
    pub code: &'static str,
    pub message: String,
    pub retryable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

impl CommandError {
    pub fn internal(message: impl Into<String>) -> Self {
        Self {
            code: "internal",
            message: message.into(),
            retryable: true,
            details: None,
        }
    }
}

impl From<AppError> for CommandError {
    fn from(error: AppError) -> Self {
        let (code, retryable) = match &error {
            AppError::Validation(_) => ("validation", false),
            AppError::NotFound => ("not_found", false),
            AppError::Conflict => ("conflict", true),
            AppError::OllamaUnavailable => ("ollama_unavailable", true),
            AppError::InvalidModelResponse(_) => ("invalid_model_response", true),
            AppError::CorruptDatabase => ("corrupt_database", false),
            AppError::UnsupportedDatabaseVersion => ("unsupported_database_version", false),
            AppError::BackupNotFound => ("backup_not_found", false),
            AppError::Database(_) | AppError::Json(_) | AppError::Io(_) => ("storage", true),
            AppError::Network(_) => ("network", true),
        };
        Self {
            code,
            message: error.to_string(),
            retryable,
            details: None,
        }
    }
}
