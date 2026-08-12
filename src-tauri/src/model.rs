use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
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
#[serde(rename_all = "camelCase")]
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
        start_at_utc: String,
        time_zone: String,
        duration_minutes: Option<i64>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum PlannerResponse {
    Proposal {
        summary: String,
        operations: Vec<MutationOperation>,
    },
    Clarification {
        question: String,
    },
}

impl PlannerResponse {
    pub fn proposal(summary: impl Into<String>, operations: Vec<MutationOperation>) -> Self {
        Self::Proposal {
            summary: summary.into(),
            operations,
        }
    }
}
