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
    #[error(transparent)]
    Database(#[from] rusqlite::Error),
    #[error(transparent)]
    Network(#[from] reqwest::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

pub type AppResult<T> = Result<T, AppError>;
