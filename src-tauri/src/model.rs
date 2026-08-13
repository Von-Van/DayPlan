use serde::{Deserialize, Serialize};

pub const MAX_TITLE_LENGTH: usize = 140;
pub const MAX_NOTES_LENGTH: usize = 800;
pub const MAX_COMMAND_LENGTH: usize = 1_000;
pub const MAX_OPERATIONS: usize = 12;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ScheduleEvent {
    pub id: String,
    pub title: String,
    pub notes: String,
    pub start_at_utc: String,
    pub time_zone: String,
    pub duration_minutes: i64,
    pub revision: i64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DailyTask {
    pub id: String,
    pub title: String,
    pub day: String,
    pub completed: bool,
    pub completed_at: Option<String>,
    pub sort_order: i64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateEventInput {
    pub title: String,
    #[serde(default)]
    pub notes: String,
    pub start_at_utc: String,
    pub time_zone: String,
    pub duration_minutes: i64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateEventInput {
    pub id: String,
    pub revision: i64,
    pub title: Option<String>,
    pub notes: Option<String>,
    pub start_at_utc: Option<String>,
    pub time_zone: Option<String>,
    pub duration_minutes: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RescheduleEventInput {
    pub id: String,
    pub revision: i64,
    pub start_at_utc: String,
    pub time_zone: String,
    pub duration_minutes: i64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateTaskInput {
    pub title: String,
    pub day: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateTaskInput {
    pub id: String,
    pub title: Option<String>,
    pub completed: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalDateTimeInput {
    pub day: String,
    pub time: String,
    pub time_zone: String,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum LocalDateTimeResolution {
    Resolved { start_at_utc: String },
    Ambiguous { options: Vec<LocalTimeOption> },
    Nonexistent { message: String },
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LocalTimeOption {
    pub start_at_utc: String,
    pub utc_offset_minutes: i32,
    pub label: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExportBundle {
    pub format_version: u32,
    pub exported_at: String,
    pub events: Vec<ScheduleEvent>,
    pub tasks: Vec<DailyTask>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportPreview {
    pub event_count: usize,
    pub task_count: usize,
    pub earliest_day: Option<String>,
    pub latest_day: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BackupInfo {
    pub name: String,
    pub created_at: String,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DatabaseStatus {
    pub ready: bool,
    pub schema_version: u32,
    pub error: Option<crate::error::CommandError>,
    pub backups: Vec<BackupInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum MutationOperation {
    CreateEvent {
        title: String,
        notes: String,
        start_at_utc: String,
        time_zone: String,
        duration_minutes: i64,
    },
    UpdateEvent {
        event_id: String,
        expected_revision: i64,
        title: Option<String>,
        notes: Option<String>,
        duration_minutes: Option<i64>,
    },
    DeleteEvent {
        event_id: String,
        expected_revision: i64,
    },
    RescheduleEvent {
        event_id: String,
        expected_revision: i64,
        title: Option<String>,
        notes: Option<String>,
        start_at_utc: String,
        time_zone: String,
        duration_minutes: Option<i64>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ModelResponse {
    Proposal {
        summary: String,
        operations: Vec<MutationOperation>,
    },
    Clarification {
        question: String,
    },
}

impl ModelResponse {
    pub fn proposal(summary: impl Into<String>, operations: Vec<MutationOperation>) -> Self {
        Self::Proposal {
            summary: summary.into(),
            operations,
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum PlannerResponse {
    Proposal {
        proposal_id: String,
        summary: String,
        operations: Vec<MutationOperation>,
        expires_at: String,
    },
    Clarification {
        question: String,
    },
}
