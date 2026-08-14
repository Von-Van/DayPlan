use crate::db::validate_model_response;
use crate::error::{AppError, AppResult};
use crate::model::{
    ModelResponse, MutationOperation, PlannerResponse, ScheduleEvent, MAX_COMMAND_LENGTH,
    MAX_NOTES_LENGTH, MAX_OPERATIONS, MAX_REMINDER_MINUTES, MAX_TITLE_LENGTH,
};
use crate::runtime::{DownloadProgress, RuntimePhase};
use chrono::{DateTime, Duration as ChronoDuration, SecondsFormat, Utc};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

pub const OLLAMA_BASE_URL: &str = "http://127.0.0.1:11434";
pub const MODEL_NAME: &str = "qwen3:8b";
const MEMORY_LIMIT: usize = 4;
const PROPOSAL_TTL_MINUTES: i64 = 10;
const MAX_RESPONSE_BYTES: usize = 256 * 1024;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OllamaStatus {
    pub phase: RuntimePhase,
    pub running: bool,
    pub model_installed: bool,
    pub model_name: String,
    pub model_digest: Option<String>,
    pub ollama_version: Option<String>,
    pub model_license: Option<String>,
    pub detail: String,
    pub download: Option<DownloadProgress>,
    pub storage_bytes: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionTurn {
    input: String,
    outcome: SessionOutcome,
}

#[derive(Debug, Clone, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
enum SessionOutcome {
    Proposal {
        proposal_id: String,
        summary: String,
        operations: Vec<MutationOperation>,
        applied: bool,
    },
    Clarification {
        question: String,
    },
}

#[derive(Clone)]
struct PendingProposal {
    id: String,
    response: ModelResponse,
    expires_at: DateTime<Utc>,
    claimed: bool,
}

#[derive(Default)]
struct AgentState {
    session: Vec<SessionTurn>,
    pending: Option<PendingProposal>,
    current_request: u64,
}

pub struct PlannerAgent {
    client: Client,
    base_url: String,
    model_name: String,
    state: Arc<Mutex<AgentState>>,
    active_cancel: Arc<Mutex<Option<(u64, CancellationToken)>>>,
}

impl Default for PlannerAgent {
    fn default() -> Self {
        Self::new(OLLAMA_BASE_URL, MODEL_NAME)
    }
}

impl PlannerAgent {
    pub fn new(base_url: impl Into<String>, model_name: impl Into<String>) -> Self {
        Self {
            client: Client::builder()
                .connect_timeout(Duration::from_secs(3))
                .timeout(Duration::from_secs(60))
                .build()
                .expect("HTTP client configuration is valid"),
            base_url: base_url.into(),
            model_name: model_name.into(),
            state: Arc::new(Mutex::new(AgentState::default())),
            active_cancel: Arc::new(Mutex::new(None)),
        }
    }

    pub fn clear_context(&self) -> AppResult<()> {
        self.cancel_current();
        let mut state = self.lock_state()?;
        state.session.clear();
        state.pending = None;
        state.current_request = state.current_request.wrapping_add(1);
        Ok(())
    }

    pub fn cancel_current(&self) {
        if let Ok(mut active) = self.active_cancel.lock() {
            if let Some((_, token)) = active.take() {
                token.cancel();
            }
        }
    }

    pub fn memory_len(&self) -> usize {
        self.state
            .lock()
            .map(|state| state.session.len())
            .unwrap_or_default()
    }

    pub fn referenced_event_ids(&self) -> Vec<String> {
        let Ok(state) = self.state.lock() else {
            return Vec::new();
        };
        let mut identifiers = HashSet::new();
        for turn in &state.session {
            let SessionOutcome::Proposal { operations, .. } = &turn.outcome else {
                continue;
            };
            for operation in operations {
                if let Some(id) = operation_event_id(operation) {
                    identifiers.insert(id.to_string());
                }
            }
        }
        identifiers.into_iter().collect()
    }

    pub async fn status(&self) -> OllamaStatus {
        ollama_status_at(&self.client, &self.base_url, &self.model_name).await
    }

    pub fn preflight(&self, command: &str, candidates: &[ScheduleEvent]) -> Option<ModelResponse> {
        let has_memory = self.memory_len() > 0;
        preflight(command, candidates, has_memory)
    }

    pub async fn propose(
        &self,
        command: &str,
        selected_day: &str,
        time_zone: &str,
        candidates: &[ScheduleEvent],
    ) -> AppResult<PlannerResponse> {
        let cleaned = command.trim();
        if cleaned.chars().count() > MAX_COMMAND_LENGTH {
            return Err(AppError::Validation(
                "Planner commands must be 1,000 characters or fewer.".into(),
            ));
        }

        let (request_id, memory, previous_pending, has_memory) = {
            let mut state = self.lock_state()?;
            state.current_request = state.current_request.wrapping_add(1);
            let request_id = state.current_request;
            let memory = state.session.clone();
            let previous_pending = state.pending.take().map(|pending| pending.response);
            (
                request_id,
                memory,
                previous_pending,
                !state.session.is_empty(),
            )
        };
        self.cancel_current();

        if let Some(response) = preflight(cleaned, candidates, has_memory) {
            return self.finish_response(request_id, cleaned, response);
        }

        let status = self.status().await;
        if !status.running || !status.model_installed {
            return Err(AppError::OllamaUnavailable);
        }

        let token = CancellationToken::new();
        self.active_cancel
            .lock()
            .map_err(|_| {
                AppError::Internal("The planner cancellation state is unavailable.".into())
            })?
            .replace((request_id, token.clone()));
        let request = json!({
            "model": self.model_name,
            "stream": false,
            "think": false,
            "tools": [{
                "type": "function",
                "function": {
                    "name": "propose_schedule_changes",
                    "description": "Return exactly one safe schedule proposal or exactly one clarification question. This tool never writes data.",
                    "parameters": proposal_schema()
                }
            }],
            "messages": [
                { "role": "system", "content": system_instruction() },
                { "role": "user", "content": planner_context(cleaned, selected_day, time_zone, candidates, &memory, previous_pending.as_ref()) }
            ],
            "options": { "temperature": 0 }
        });

        let body = tokio::select! {
            _ = token.cancelled() => return Err(AppError::RequestCancelled),
            response = self.client.post(format!("{}/api/chat", self.base_url)).json(&request).send() => {
                let response = response.map_err(|_| AppError::OllamaUnavailable)?;
                if !response.status().is_success() {
                    return Err(AppError::OllamaUnavailable);
                }
                if response.content_length().is_some_and(|length| length > MAX_RESPONSE_BYTES as u64) {
                    return Err(AppError::InvalidModelResponse("the model response exceeded the size limit".into()));
                }
                let bytes = response.bytes().await.map_err(|_| AppError::OllamaUnavailable)?;
                if bytes.len() > MAX_RESPONSE_BYTES {
                    return Err(AppError::InvalidModelResponse("the model response exceeded the size limit".into()));
                }
                serde_json::from_slice::<OllamaChatResponse>(&bytes)
                    .map_err(|error| AppError::InvalidModelResponse(error.to_string()))?
            }
        };
        self.clear_active_cancel(request_id);

        let response = parse_tool_response(body)?;
        validate_model_response(&response)
            .map_err(|error| AppError::InvalidModelResponse(error.to_string()))?;
        validate_references(&response, candidates)?;
        self.finish_response(request_id, cleaned, response)
    }

    pub fn claim_pending(&self, proposal_id: &str) -> AppResult<ModelResponse> {
        let mut state = self.lock_state()?;
        let Some(pending) = state.pending.as_mut() else {
            return Err(AppError::ProposalUnavailable);
        };
        if pending.id != proposal_id || pending.claimed {
            return Err(AppError::ProposalUnavailable);
        }
        if pending.expires_at <= Utc::now() {
            state.pending = None;
            return Err(AppError::ProposalExpired);
        }
        pending.claimed = true;
        Ok(pending.response.clone())
    }

    pub fn finish_pending(&self, proposal_id: &str, applied: bool) -> AppResult<()> {
        let mut state = self.lock_state()?;
        if state
            .pending
            .as_ref()
            .is_some_and(|pending| pending.id == proposal_id)
        {
            state.pending = None;
        }
        if applied {
            for turn in state.session.iter_mut().rev() {
                if let SessionOutcome::Proposal {
                    proposal_id: recorded,
                    applied,
                    ..
                } = &mut turn.outcome
                {
                    if recorded == proposal_id {
                        *applied = true;
                        break;
                    }
                }
            }
        }
        Ok(())
    }

    pub fn discard_pending(&self, proposal_id: &str) -> AppResult<()> {
        let mut state = self.lock_state()?;
        if state
            .pending
            .as_ref()
            .is_some_and(|pending| pending.id == proposal_id && !pending.claimed)
        {
            state.pending = None;
            Ok(())
        } else {
            Err(AppError::ProposalUnavailable)
        }
    }

    fn finish_response(
        &self,
        request_id: u64,
        command: &str,
        response: ModelResponse,
    ) -> AppResult<PlannerResponse> {
        let mut state = self.lock_state()?;
        if state.current_request != request_id {
            return Err(AppError::RequestCancelled);
        }
        let public = match &response {
            ModelResponse::Clarification { question } => {
                state.pending = None;
                state.session.push(SessionTurn {
                    input: command.to_string(),
                    outcome: SessionOutcome::Clarification {
                        question: question.clone(),
                    },
                });
                PlannerResponse::Clarification {
                    question: question.clone(),
                }
            }
            ModelResponse::Proposal {
                summary,
                operations,
            } => {
                let proposal_id = Uuid::new_v4().to_string();
                let expires_at = Utc::now() + ChronoDuration::minutes(PROPOSAL_TTL_MINUTES);
                state.pending = Some(PendingProposal {
                    id: proposal_id.clone(),
                    response: response.clone(),
                    expires_at,
                    claimed: false,
                });
                state.session.push(SessionTurn {
                    input: command.to_string(),
                    outcome: SessionOutcome::Proposal {
                        proposal_id: proposal_id.clone(),
                        summary: summary.clone(),
                        operations: operations.clone(),
                        applied: false,
                    },
                });
                PlannerResponse::Proposal {
                    proposal_id,
                    summary: summary.clone(),
                    operations: operations.clone(),
                    expires_at: expires_at.to_rfc3339_opts(SecondsFormat::Millis, true),
                }
            }
        };
        trim_memory(&mut state.session);
        Ok(public)
    }

    fn clear_active_cancel(&self, request_id: u64) {
        if let Ok(mut active) = self.active_cancel.lock() {
            if active
                .as_ref()
                .is_some_and(|(active_id, _)| *active_id == request_id)
            {
                active.take();
            }
        }
    }

    fn lock_state(&self) -> AppResult<MutexGuard<'_, AgentState>> {
        self.state
            .lock()
            .map_err(|_| AppError::Internal("The planner session is unavailable.".into()))
    }
}

pub async fn ollama_status(client: &Client) -> OllamaStatus {
    ollama_status_at(client, OLLAMA_BASE_URL, MODEL_NAME).await
}

async fn ollama_status_at(client: &Client, base_url: &str, model_name: &str) -> OllamaStatus {
    let response = match tokio::time::timeout(
        Duration::from_secs(3),
        client.get(format!("{base_url}/api/tags")).send(),
    )
    .await
    {
        Ok(Ok(response)) if response.status().is_success() => response,
        _ => return unavailable_status(model_name),
    };
    let body: OllamaTags = match response.json().await {
        Ok(body) => body,
        Err(_) => {
            return OllamaStatus {
                phase: RuntimePhase::Error,
                running: true,
                model_installed: false,
                model_name: model_name.into(),
                model_digest: None,
                ollama_version: None,
                model_license: None,
                detail: "Ollama replied with an unreadable model list.".into(),
                download: None,
                storage_bytes: None,
            }
        }
    };
    let installed = body.models.into_iter().find(|model| {
        model.name == model_name || model.name.starts_with(&format!("{model_name}-"))
    });
    let version = tokio::time::timeout(
        Duration::from_secs(3),
        client.get(format!("{base_url}/api/version")).send(),
    )
    .await
    .ok()
    .and_then(Result::ok)
    .and_then(|response| response.status().is_success().then_some(response));
    let ollama_version = if let Some(response) = version {
        response
            .json::<OllamaVersion>()
            .await
            .ok()
            .map(|body| body.version)
    } else {
        None
    };
    let model_license = if installed.is_some() {
        match tokio::time::timeout(
            Duration::from_secs(3),
            client
                .post(format!("{base_url}/api/show"))
                .json(&json!({ "model": model_name }))
                .send(),
        )
        .await
        {
            Ok(Ok(response)) if response.status().is_success() => response
                .json::<OllamaShow>()
                .await
                .ok()
                .and_then(|body| summarize_license(&body.license)),
            _ => None,
        }
    } else {
        None
    };
    OllamaStatus {
        phase: if installed.is_some() {
            RuntimePhase::ModelReady
        } else {
            RuntimePhase::ReadyWithoutModel
        },
        running: true,
        model_installed: installed.is_some(),
        model_name: model_name.into(),
        model_digest: installed.as_ref().map(|model| model.digest.clone()),
        ollama_version,
        model_license,
        detail: if installed.is_some() {
            "Local model is ready. Nothing is sent to a cloud service.".into()
        } else {
            format!(
                "DayPlan's local runtime is ready. Download {model_name} to enable AI planning."
            )
        },
        download: None,
        storage_bytes: None,
    }
}

fn unavailable_status(model_name: &str) -> OllamaStatus {
    OllamaStatus {
        phase: RuntimePhase::Unavailable,
        running: false,
        model_installed: false,
        model_name: model_name.into(),
        model_digest: None,
        ollama_version: None,
        model_license: None,
        detail: "DayPlan's local AI runtime is not running.".into(),
        download: None,
        storage_bytes: None,
    }
}

fn preflight(
    command: &str,
    candidates: &[ScheduleEvent],
    has_memory: bool,
) -> Option<ModelResponse> {
    let cleaned = command.trim();
    if cleaned.is_empty() {
        return Some(ModelResponse::Clarification {
            question: "What would you like to change in your schedule?".into(),
        });
    }
    if has_bare_twelve_hour_time(cleaned) {
        return Some(ModelResponse::Clarification {
            question:
                "Is that time AM or PM? Please include it so I can prepare the change safely."
                    .into(),
        });
    }
    let lower = cleaned.to_ascii_lowercase();
    if lower.contains("repeat") || lower.contains("every weekday") || lower.contains("recurring") {
        return Some(ModelResponse::Clarification { question: "Recurring events are not supported in this version of DayPlan. What one-time event should I change?".into() });
    }
    if lower.starts_with("mark ") || lower.contains(" complete") {
        return Some(ModelResponse::Clarification { question: "This assistant can change timed events, not daily task completion. Please use the task checklist for that.".into() });
    }
    if (lower.contains("task") || lower.contains("checklist")) && lower.contains("remind") {
        return Some(ModelResponse::Clarification {
            question:
                "Task reminders are not supported. Which timed event should have the reminder?"
                    .into(),
        });
    }
    if (lower.contains("move it") || lower.contains("reschedule it")) && !has_memory {
        return Some(ModelResponse::Clarification {
            question: "Which earlier schedule change does “it” refer to?".into(),
        });
    }
    ambiguous_title(cleaned, candidates)
        .map(|(title, choices)| ModelResponse::Clarification {
            question: format!(
                "I found multiple events named “{title}”: {}. Which one should I change?",
                choices.join(", ")
            ),
        })
        .or_else(|| missing_target_or_date(cleaned, candidates))
}

fn validate_references(response: &ModelResponse, candidates: &[ScheduleEvent]) -> AppResult<()> {
    let candidate_revisions: HashMap<&str, i64> = candidates
        .iter()
        .map(|event| (event.id.as_str(), event.revision))
        .collect();
    let mut referenced = HashSet::new();
    let operations = match response {
        ModelResponse::Proposal { operations, .. } => operations,
        ModelResponse::Clarification { .. } => return Ok(()),
    };
    for operation in operations {
        let Some((id, revision)) = operation_event_reference(operation) else {
            continue;
        };
        if candidate_revisions.get(id) != Some(&revision) {
            return Err(AppError::InvalidModelResponse(
                "an operation referenced an event that is absent or stale".into(),
            ));
        }
        if !referenced.insert(id) {
            return Err(AppError::InvalidModelResponse(
                "an event was changed more than once in one proposal".into(),
            ));
        }
    }
    Ok(())
}

fn operation_event_id(operation: &MutationOperation) -> Option<&str> {
    operation_event_reference(operation).map(|(id, _)| id)
}

fn operation_event_reference(operation: &MutationOperation) -> Option<(&str, i64)> {
    match operation {
        MutationOperation::CreateEvent { .. } => None,
        MutationOperation::UpdateEvent {
            event_id,
            expected_revision,
            ..
        }
        | MutationOperation::DeleteEvent {
            event_id,
            expected_revision,
        }
        | MutationOperation::RescheduleEvent {
            event_id,
            expected_revision,
            ..
        } => Some((event_id, *expected_revision)),
    }
}

fn has_bare_twelve_hour_time(command: &str) -> bool {
    let words = command
        .to_ascii_lowercase()
        .split_whitespace()
        .map(|word| {
            word.trim_matches(|character: char| {
                !character.is_ascii_alphanumeric() && character != ':'
            })
            .to_string()
        })
        .collect::<Vec<_>>();
    for (index, word) in words.iter().enumerate() {
        if word != "at" {
            continue;
        }
        let Some(next) = words.get(index + 1) else {
            continue;
        };
        let hour = next
            .split_once(':')
            .map(|(hour, _)| hour)
            .unwrap_or(next)
            .parse::<u8>();
        if !matches!(hour, Ok(1..=12)) {
            continue;
        }
        let meridiem_follows = matches!(
            words.get(index + 2).map(String::as_str),
            Some("am") | Some("pm")
        );
        if !meridiem_follows {
            return true;
        }
    }
    false
}

fn ambiguous_title(command: &str, candidates: &[ScheduleEvent]) -> Option<(String, Vec<String>)> {
    let command = command.to_ascii_lowercase();
    let mut occurrences: HashMap<String, Vec<&ScheduleEvent>> = HashMap::new();
    for event in candidates {
        let title = event.title.trim().to_ascii_lowercase();
        if !title.is_empty() {
            occurrences.entry(title).or_default().push(event);
        }
    }
    occurrences.into_iter().find_map(|(title, events)| {
        (events.len() > 1 && command.contains(&title)).then(|| {
            let choices = events
                .iter()
                .take(4)
                .map(|event| event.start_at_utc.clone())
                .collect();
            (title, choices)
        })
    })
}

fn missing_target_or_date(command: &str, candidates: &[ScheduleEvent]) -> Option<ModelResponse> {
    let command_lower = command.to_ascii_lowercase();
    let moves_event = ["move ", "reschedule ", "shift "]
        .iter()
        .any(|verb| command_lower.contains(verb));
    let direct_event_action = moves_event
        || [
            "cancel ",
            "delete ",
            "rename ",
            "add notes",
            "extend ",
            "shorten ",
        ]
        .iter()
        .any(|verb| command_lower.contains(verb));
    if !direct_event_action
        || command_lower.contains("everything")
        || command_lower.contains("move it")
        || command_lower.contains("reschedule it")
    {
        return None;
    }
    let has_matching_title = candidates
        .iter()
        .any(|event| command_lower.contains(&event.title.to_ascii_lowercase()));
    if !has_matching_title {
        return Some(ModelResponse::Clarification { question: "I could not find a matching event in the available schedule. Which event should I change?".into() });
    }
    if moves_event && !has_date_reference(&command_lower) {
        return Some(ModelResponse::Clarification {
            question: "Which date should that event move to?".into(),
        });
    }
    None
}

fn has_date_reference(command: &str) -> bool {
    [
        "today",
        "tomorrow",
        "monday",
        "tuesday",
        "wednesday",
        "thursday",
        "friday",
        "saturday",
        "sunday",
        "next ",
    ]
    .iter()
    .any(|term| command.contains(term))
        || command
            .split_whitespace()
            .any(|word| word.chars().filter(|character| *character == '-').count() == 2)
}

fn system_instruction() -> String {
    "You are DayPlan's local schedule interpreter. You must use only the propose_schedule_changes tool exactly once. You never edit data and you may only return the four permitted event operations. Use only supplied event IDs and exact revisions. Produce a clarification instead of guessing when a title can identify multiple events, a date/time is missing or ambiguous, an event is absent, or the request is outside event scheduling. A proposal must be complete and replace any prior pending proposal: do not apply a safe subset of a compound request. Times must be ISO-8601 UTC timestamps with Z. Event reminders use minutesBefore from 0 through 10080; create defaults to null and an unchanged reminder must use {\"action\":\"unchanged\"}. Do not alter daily tasks or create task reminders. Use recent structured turns and the prior pending proposal only to resolve an explicit follow-up or clarification answer."
        .into()
}

fn planner_context(
    command: &str,
    selected_day: &str,
    time_zone: &str,
    candidates: &[ScheduleEvent],
    session: &[SessionTurn],
    prior_pending: Option<&ModelResponse>,
) -> String {
    let event_context = candidates
        .iter()
        .take(60)
        .map(|event| {
            json!({
                "id": event.id,
                "revision": event.revision,
                "title": event.title,
                "startAtUtc": event.start_at_utc,
                "timeZone": event.time_zone,
                "durationMinutes": event.duration_minutes,
                "reminderMinutesBefore": event.reminder_minutes_before,
                "reminderStatus": event.reminder_status
            })
        })
        .collect::<Vec<_>>();
    json!({
        "currentSelectedDay": selected_day,
        "viewerTimeZone": time_zone,
        "userCommand": command,
        "recentSessionTurns": session,
        "priorPendingProposal": prior_pending,
        "eventCandidates": event_context
    })
    .to_string()
}

fn proposal_schema() -> Value {
    let event_ref = json!({
        "eventId": { "type": "string", "format": "uuid" },
        "expectedRevision": { "type": "integer", "minimum": 1 }
    });
    let reminder_change = json!({
        "oneOf": [
            {
                "type": "object", "additionalProperties": false,
                "properties": { "action": { "const": "unchanged" } },
                "required": ["action"]
            },
            {
                "type": "object", "additionalProperties": false,
                "properties": { "action": { "const": "clear" } },
                "required": ["action"]
            },
            {
                "type": "object", "additionalProperties": false,
                "properties": {
                    "action": { "const": "set" },
                    "minutesBefore": {
                        "type": "integer", "minimum": 0, "maximum": MAX_REMINDER_MINUTES
                    }
                },
                "required": ["action", "minutesBefore"]
            }
        ]
    });
    json!({
        "oneOf": [
            {
                "type": "object", "additionalProperties": false,
                "properties": {
                    "kind": { "const": "proposal" },
                    "summary": { "type": "string", "minLength": 1, "maxLength": 280 },
                    "operations": {
                        "type": "array", "minItems": 1, "maxItems": MAX_OPERATIONS,
                        "items": { "oneOf": [
                            { "type": "object", "additionalProperties": false, "properties": {
                                "type": { "const": "create_event" },
                                "title": { "type": "string", "minLength": 1, "maxLength": MAX_TITLE_LENGTH },
                                "notes": { "type": "string", "maxLength": MAX_NOTES_LENGTH },
                                "startAtUtc": { "type": "string" }, "timeZone": { "type": "string" },
                                "durationMinutes": { "type": "integer", "minimum": 5, "maximum": 1440 },
                                "reminderMinutesBefore": { "type": ["integer", "null"], "minimum": 0, "maximum": MAX_REMINDER_MINUTES }
                            }, "required": ["type", "title", "notes", "startAtUtc", "timeZone", "durationMinutes", "reminderMinutesBefore"] },
                            { "type": "object", "additionalProperties": false, "properties": {
                                "type": { "const": "update_event" }, "eventId": event_ref["eventId"].clone(),
                                "expectedRevision": event_ref["expectedRevision"].clone(),
                                "title": { "type": ["string", "null"], "maxLength": MAX_TITLE_LENGTH },
                                "notes": { "type": ["string", "null"], "maxLength": MAX_NOTES_LENGTH },
                                "durationMinutes": { "type": ["integer", "null"], "minimum": 5, "maximum": 1440 },
                                "reminderChange": reminder_change.clone()
                            }, "required": ["type", "eventId", "expectedRevision", "title", "notes", "durationMinutes", "reminderChange"] },
                            { "type": "object", "additionalProperties": false, "properties": {
                                "type": { "const": "delete_event" }, "eventId": event_ref["eventId"].clone(),
                                "expectedRevision": event_ref["expectedRevision"].clone()
                            }, "required": ["type", "eventId", "expectedRevision"] },
                            { "type": "object", "additionalProperties": false, "properties": {
                                "type": { "const": "reschedule_event" }, "eventId": event_ref["eventId"].clone(),
                                "expectedRevision": event_ref["expectedRevision"].clone(),
                                "title": { "type": ["string", "null"], "maxLength": MAX_TITLE_LENGTH },
                                "notes": { "type": ["string", "null"], "maxLength": MAX_NOTES_LENGTH },
                                "startAtUtc": { "type": "string" }, "timeZone": { "type": "string" },
                                "durationMinutes": { "type": ["integer", "null"], "minimum": 5, "maximum": 1440 },
                                "reminderChange": reminder_change
                            }, "required": ["type", "eventId", "expectedRevision", "title", "notes", "startAtUtc", "timeZone", "durationMinutes", "reminderChange"] }
                        ] }
                    }
                }, "required": ["kind", "summary", "operations"]
            },
            {
                "type": "object", "additionalProperties": false,
                "properties": {
                    "kind": { "const": "clarification" },
                    "question": { "type": "string", "minLength": 1, "maxLength": 280 }
                },
                "required": ["kind", "question"]
            }
        ]
    })
}

#[derive(Deserialize)]
struct OllamaTags {
    #[serde(default)]
    models: Vec<OllamaModel>,
}

#[derive(Deserialize)]
struct OllamaModel {
    name: String,
    #[serde(default)]
    digest: String,
}

#[derive(Deserialize)]
struct OllamaVersion {
    version: String,
}

#[derive(Deserialize)]
struct OllamaShow {
    #[serde(default)]
    license: String,
}

fn summarize_license(license: &str) -> Option<String> {
    license
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(|line| line.chars().take(120).collect())
}

#[derive(Deserialize)]
struct OllamaChatResponse {
    message: OllamaMessage,
}

#[derive(Deserialize)]
struct OllamaMessage {
    #[serde(default)]
    tool_calls: Vec<OllamaToolCall>,
}

#[derive(Deserialize)]
struct OllamaToolCall {
    function: OllamaFunctionCall,
}

#[derive(Deserialize)]
struct OllamaFunctionCall {
    name: String,
    arguments: Value,
}

fn parse_tool_response(body: OllamaChatResponse) -> AppResult<ModelResponse> {
    if body.message.tool_calls.len() != 1 {
        return Err(AppError::InvalidModelResponse(
            "the model must call propose_schedule_changes exactly once".into(),
        ));
    }
    let call = body.message.tool_calls.into_iter().next().ok_or_else(|| {
        AppError::InvalidModelResponse("the model did not call propose_schedule_changes".into())
    })?;
    if call.function.name != "propose_schedule_changes" {
        return Err(AppError::InvalidModelResponse(
            "the model called an unknown tool".into(),
        ));
    }
    let value = match call.function.arguments {
        Value::String(value) => serde_json::from_str(&value)?,
        value => value,
    };
    serde_json::from_value(value).map_err(|error| AppError::InvalidModelResponse(error.to_string()))
}

fn trim_memory(session: &mut Vec<SessionTurn>) {
    if session.len() > MEMORY_LIMIT {
        session.drain(0..session.len() - MEMORY_LIMIT);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    fn event(id: &str, title: &str) -> ScheduleEvent {
        ScheduleEvent {
            id: id.into(),
            title: title.into(),
            notes: String::new(),
            start_at_utc: "2026-08-12T22:00:00.000Z".into(),
            time_zone: "America/New_York".into(),
            duration_minutes: 60,
            reminder_minutes_before: None,
            reminder_status: crate::model::ReminderStatus::None,
            revision: 1,
            created_at: "2026-08-12T10:00:00.000Z".into(),
            updated_at: "2026-08-12T10:00:00.000Z".into(),
        }
    }

    #[test]
    fn bare_12_hour_time_requires_a_clarification() {
        assert!(has_bare_twelve_hour_time("add dentist Thursday at 2"));
        assert!(has_bare_twelve_hour_time("add dentist Thursday at 2:30"));
        assert!(!has_bare_twelve_hour_time(
            "add dentist Thursday at 2:30 pm"
        ));
        assert!(!has_bare_twelve_hour_time("add dentist Thursday at 14:00"));
    }

    #[test]
    fn duplicate_title_requires_a_clarification() {
        let agent = PlannerAgent::default();
        let response = agent.preflight("move gym to 6 pm", &[event("a", "Gym"), event("b", "Gym")]);
        assert!(matches!(
            response,
            Some(ModelResponse::Clarification { .. })
        ));
    }

    #[test]
    fn a_move_without_a_date_requires_a_clarification() {
        let agent = PlannerAgent::default();
        let response = agent.preflight("move gym to 6 pm", &[event("a", "Gym")]);
        assert!(matches!(
            response,
            Some(ModelResponse::Clarification { .. })
        ));
    }

    #[test]
    fn session_memory_is_bounded_to_four_turns() {
        let agent = PlannerAgent::default();
        {
            let mut state = agent.lock_state().unwrap();
            for index in 0..5 {
                state.session.push(SessionTurn {
                    input: format!("command {index}"),
                    outcome: SessionOutcome::Clarification {
                        question: "Which one?".into(),
                    },
                });
                trim_memory(&mut state.session);
            }
        }
        assert_eq!(agent.memory_len(), 4);
    }

    #[test]
    fn malformed_tool_output_is_rejected() {
        let malformed =
            json!({ "kind": "proposal", "summary": "Hi", "operations": [], "untrusted": true });
        assert!(serde_json::from_value::<ModelResponse>(malformed).is_err());
    }

    #[test]
    fn reminder_tool_fields_are_strict_and_bounded() {
        let valid = serde_json::from_value::<ModelResponse>(json!({
            "kind": "proposal",
            "summary": "Remind before gym",
            "operations": [{
                "type": "update_event",
                "eventId": "30bb9c6a-4020-45a6-806b-5eb71c7ae76f",
                "expectedRevision": 1,
                "title": null,
                "notes": null,
                "durationMinutes": null,
                "reminderChange": { "action": "set", "minutesBefore": 15 }
            }]
        }))
        .unwrap();
        assert!(validate_model_response(&valid).is_ok());

        let oversized = serde_json::from_value::<ModelResponse>(json!({
            "kind": "proposal",
            "summary": "Remind before gym",
            "operations": [{
                "type": "update_event",
                "eventId": "30bb9c6a-4020-45a6-806b-5eb71c7ae76f",
                "expectedRevision": 1,
                "title": null,
                "notes": null,
                "durationMinutes": null,
                "reminderChange": { "action": "set", "minutesBefore": 10081 }
            }]
        }))
        .unwrap();
        assert!(validate_model_response(&oversized).is_err());
        assert!(serde_json::from_value::<ModelResponse>(json!({
            "kind": "proposal",
            "summary": "Remind before gym",
            "operations": [{
                "type": "update_event",
                "eventId": "30bb9c6a-4020-45a6-806b-5eb71c7ae76f",
                "expectedRevision": 1,
                "title": null,
                "notes": null,
                "durationMinutes": null,
                "reminderChange": { "action": "snooze", "minutesBefore": 15 }
            }]
        }))
        .is_err());
    }

    #[test]
    fn task_reminders_are_explicitly_unsupported() {
        let response =
            PlannerAgent::default().preflight("remind me about my buy milk task tomorrow", &[]);
        assert!(matches!(
            response,
            Some(ModelResponse::Clarification { .. })
        ));
    }

    #[test]
    fn multiple_tool_calls_are_rejected() {
        let tool = OllamaToolCall {
            function: OllamaFunctionCall {
                name: "propose_schedule_changes".into(),
                arguments: json!({ "kind": "clarification", "question": "Which one?" }),
            },
        };
        let response = OllamaChatResponse {
            message: OllamaMessage {
                tool_calls: vec![
                    tool,
                    OllamaToolCall {
                        function: OllamaFunctionCall {
                            name: "propose_schedule_changes".into(),
                            arguments: json!({ "kind": "clarification", "question": "Again?" }),
                        },
                    },
                ],
            },
        };
        assert!(matches!(
            parse_tool_response(response),
            Err(AppError::InvalidModelResponse(_))
        ));
    }

    #[test]
    fn pending_proposals_are_single_use() {
        let agent = PlannerAgent::default();
        let public = agent
            .finish_response(
                0,
                "add lunch tomorrow at noon",
                ModelResponse::proposal(
                    "Add lunch",
                    vec![MutationOperation::CreateEvent {
                        title: "Lunch".into(),
                        notes: String::new(),
                        start_at_utc: "2026-08-13T16:00:00Z".into(),
                        time_zone: "America/New_York".into(),
                        duration_minutes: 60,
                        reminder_minutes_before: None,
                    }],
                ),
            )
            .unwrap();
        let PlannerResponse::Proposal { proposal_id, .. } = public else {
            panic!("expected proposal");
        };
        assert!(agent.claim_pending(&proposal_id).is_ok());
        assert!(matches!(
            agent.claim_pending(&proposal_id),
            Err(AppError::ProposalUnavailable)
        ));
    }

    #[tokio::test]
    async fn production_http_path_rejects_a_missing_tool_call() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            for _ in 0..4 {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut request = vec![0; 16 * 1024];
                let count = stream.read(&mut request).await.unwrap();
                let request = String::from_utf8_lossy(&request[..count]);
                let body = if request.contains("/api/tags") {
                    r#"{"models":[{"name":"qwen3:8b","digest":"sha256:test"}]}"#
                } else if request.contains("/api/version") {
                    r#"{"version":"test"}"#
                } else if request.contains("/api/show") {
                    r#"{"license":"Apache-2.0"}"#
                } else {
                    r#"{"message":{"tool_calls":[]}}"#
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                stream.write_all(response.as_bytes()).await.unwrap();
            }
        });
        let agent = PlannerAgent::new(format!("http://{address}"), MODEL_NAME);
        let result = agent
            .propose(
                "add lunch tomorrow at noon",
                "2026-08-12",
                "America/New_York",
                &[],
            )
            .await;
        assert!(matches!(result, Err(AppError::InvalidModelResponse(_))));
    }
}
