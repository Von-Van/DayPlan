use crate::db::validate_model_response;
use crate::error::{AppError, AppResult};
use crate::model::{MutationOperation, PlannerResponse, ScheduleEvent};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::time::Duration;

const OLLAMA_BASE_URL: &str = "http://127.0.0.1:11434";
const MODEL_NAME: &str = "qwen3:8b";
const MEMORY_LIMIT: usize = 4;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OllamaStatus {
    pub running: bool,
    pub model_installed: bool,
    pub model_name: String,
    pub detail: String,
}

#[derive(Debug, Clone)]
struct SessionTurn {
    input: String,
    outcome: String,
}

pub struct PlannerAgent {
    client: Client,
    session: Vec<SessionTurn>,
}

impl Default for PlannerAgent {
    fn default() -> Self {
        Self {
            client: Client::builder()
                .timeout(Duration::from_secs(50))
                .build()
                .expect("HTTP client configuration is valid"),
            session: Vec::new(),
        }
    }
}

impl PlannerAgent {
    pub fn clear_context(&mut self) {
        self.session.clear();
    }

    pub fn memory_len(&self) -> usize {
        self.session.len()
    }

    pub fn preflight(
        &self,
        command: &str,
        candidates: &[ScheduleEvent],
    ) -> Option<PlannerResponse> {
        let cleaned = command.trim();
        if cleaned.is_empty() {
            return Some(PlannerResponse::Clarification {
                question: "What would you like to change in your schedule?".into(),
            });
        }
        if has_bare_twelve_hour_time(cleaned) {
            return Some(PlannerResponse::Clarification {
                question:
                    "Is that time AM or PM? Please include it so I can prepare the change safely."
                        .into(),
            });
        }
        let lower = cleaned.to_ascii_lowercase();
        if lower.contains("repeat")
            || lower.contains("every weekday")
            || lower.contains("recurring")
        {
            return Some(PlannerResponse::Clarification { question: "Recurring events are not supported in this version of DayPlan. What one-time event should I change?".into() });
        }
        if lower.starts_with("mark ") || lower.contains(" complete") {
            return Some(PlannerResponse::Clarification { question: "This assistant can change timed events, not daily task completion. Please use the task checklist for that.".into() });
        }
        if (lower.contains("move it") || lower.contains("reschedule it")) && self.session.is_empty()
        {
            return Some(PlannerResponse::Clarification {
                question: "Which earlier schedule change does “it” refer to?".into(),
            });
        }
        ambiguous_title(cleaned, candidates)
            .map(|title| PlannerResponse::Clarification {
                question: format!(
                    "I found multiple events named “{title}.” Which one should I change?"
                ),
            })
            .or_else(|| missing_target_or_date(cleaned, candidates))
    }

    pub fn propose(
        &mut self,
        command: &str,
        selected_day: &str,
        time_zone: &str,
        candidates: &[ScheduleEvent],
    ) -> AppResult<PlannerResponse> {
        if let Some(response) = self.preflight(command, candidates) {
            self.record(command, &response);
            return Ok(response);
        }

        let status = ollama_status(&self.client);
        if !status.running || !status.model_installed {
            return Err(AppError::OllamaUnavailable);
        }

        let request = json!({
            "model": MODEL_NAME,
            "stream": false,
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
                { "role": "user", "content": planner_context(command, selected_day, time_zone, candidates, &self.session) }
            ],
            "options": { "temperature": 0 }
        });
        let response = self
            .client
            .post(format!("{OLLAMA_BASE_URL}/api/chat"))
            .json(&request)
            .send()
            .map_err(|_| AppError::OllamaUnavailable)?;
        if !response.status().is_success() {
            return Err(AppError::OllamaUnavailable);
        }
        let body: OllamaChatResponse = response
            .json()
            .map_err(|error| AppError::InvalidModelResponse(error.to_string()))?;
        let response = parse_tool_response(body)?;
        validate_model_response(&response)
            .map_err(|error| AppError::InvalidModelResponse(error.to_string()))?;
        validate_references(&response, candidates)?;
        self.record(command, &response);
        Ok(response)
    }

    fn record(&mut self, command: &str, response: &PlannerResponse) {
        let outcome = match response {
            PlannerResponse::Proposal {
                summary,
                operations,
            } => format!("Proposed {} operation(s): {summary}", operations.len()),
            PlannerResponse::Clarification { question } => format!("Asked: {question}"),
        };
        self.session.push(SessionTurn {
            input: command.trim().to_string(),
            outcome,
        });
        if self.session.len() > MEMORY_LIMIT {
            self.session.drain(0..self.session.len() - MEMORY_LIMIT);
        }
    }
}

pub fn ollama_status(client: &Client) -> OllamaStatus {
    let response = match client.get(format!("{OLLAMA_BASE_URL}/api/tags")).send() {
        Ok(response) if response.status().is_success() => response,
        _ => {
            return OllamaStatus {
                running: false,
                model_installed: false,
                model_name: MODEL_NAME.into(),
                detail: "Ollama is not running on this computer.".into(),
            }
        }
    };
    let body: OllamaTags = match response.json() {
        Ok(body) => body,
        Err(_) => {
            return OllamaStatus {
                running: true,
                model_installed: false,
                model_name: MODEL_NAME.into(),
                detail: "Ollama replied with an unreadable model list.".into(),
            }
        }
    };
    let installed = body
        .models
        .into_iter()
        .any(|model| model.name == MODEL_NAME || model.name.starts_with("qwen3:8b-"));
    OllamaStatus {
        running: true,
        model_installed: installed,
        model_name: MODEL_NAME.into(),
        detail: if installed {
            "Local model is ready. Nothing is sent to a cloud service.".into()
        } else {
            "Ollama is running, but qwen3:8b is not installed. Run: ollama pull qwen3:8b".into()
        },
    }
}

fn validate_references(response: &PlannerResponse, candidates: &[ScheduleEvent]) -> AppResult<()> {
    let candidate_revisions: HashMap<&str, i64> = candidates
        .iter()
        .map(|event| (event.id.as_str(), event.revision))
        .collect();
    let mut referenced = HashSet::new();
    let operations = match response {
        PlannerResponse::Proposal { operations, .. } => operations,
        PlannerResponse::Clarification { .. } => return Ok(()),
    };
    for operation in operations {
        let (id, revision) = match operation {
            MutationOperation::CreateEvent { .. } => continue,
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
            } => (event_id, expected_revision),
        };
        if candidate_revisions.get(id.as_str()) != Some(revision) {
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

fn has_bare_twelve_hour_time(command: &str) -> bool {
    let words: Vec<String> = command
        .to_ascii_lowercase()
        .split_whitespace()
        .map(|word| {
            word.trim_matches(|character: char| {
                !character.is_ascii_alphanumeric() && character != ':'
            })
            .to_string()
        })
        .collect();
    for (index, word) in words.iter().enumerate() {
        if word != "at" {
            continue;
        }
        let Some(next) = words.get(index + 1) else {
            continue;
        };
        let Ok(hour) = next.parse::<u8>() else {
            continue;
        };
        if !(1..=12).contains(&hour) {
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

fn ambiguous_title(command: &str, candidates: &[ScheduleEvent]) -> Option<String> {
    let command = command.to_ascii_lowercase();
    let mut occurrences: HashMap<String, usize> = HashMap::new();
    for event in candidates {
        let title = event.title.trim().to_ascii_lowercase();
        if !title.is_empty() {
            *occurrences.entry(title).or_default() += 1;
        }
    }
    occurrences
        .into_iter()
        .find_map(|(title, count)| (count > 1 && command.contains(&title)).then_some(title))
}

fn missing_target_or_date(command: &str, candidates: &[ScheduleEvent]) -> Option<PlannerResponse> {
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
        return Some(PlannerResponse::Clarification { question: "I could not find a matching event in the available schedule. Which event should I change?".into() });
    }
    if moves_event && !has_date_reference(&command_lower) {
        return Some(PlannerResponse::Clarification {
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
    "You are DayPlan's local schedule interpreter. You must use only the propose_schedule_changes tool. You never edit data and you may only return the four permitted event operations. Use only supplied event IDs and exact revisions. Produce a clarification instead of guessing when a title can identify multiple events, a date/time is missing or ambiguous, an event is absent, or the request is outside event scheduling. A proposal must be complete: do not apply a safe subset of a compound request. Times must be ISO-8601 UTC timestamps with Z. Do not alter daily tasks. Use the supplied session context only to resolve an explicit follow-up such as ‘move it later’.".into()
}

fn planner_context(
    command: &str,
    selected_day: &str,
    time_zone: &str,
    candidates: &[ScheduleEvent],
    session: &[SessionTurn],
) -> String {
    let event_context: Vec<Value> = candidates.iter().take(60).map(|event| json!({
        "id": event.id, "revision": event.revision, "title": event.title,
        "startAtUtc": event.start_at_utc, "timeZone": event.time_zone, "durationMinutes": event.duration_minutes
    })).collect();
    let memory: Vec<Value> = session
        .iter()
        .map(|turn| json!({ "input": turn.input, "outcome": turn.outcome }))
        .collect();
    json!({
        "currentSelectedDay": selected_day,
        "viewerTimeZone": time_zone,
        "userCommand": command.trim(),
        "recentSessionTurns": memory,
        "eventCandidates": event_context
    })
    .to_string()
}

fn proposal_schema() -> Value {
    let event_ref = json!({
        "eventId": { "type": "string" }, "expectedRevision": { "type": "integer", "minimum": 1 }
    });
    json!({
        "oneOf": [
            {
                "type": "object", "additionalProperties": false,
                "properties": {
                    "kind": { "const": "proposal" }, "summary": { "type": "string" },
                    "operations": {
                        "type": "array", "minItems": 1, "maxItems": 12,
                        "items": { "oneOf": [
                            { "type": "object", "additionalProperties": false, "properties": {
                                "type": { "const": "create_event" }, "title": { "type": "string" }, "notes": { "type": "string" },
                                "startAtUtc": { "type": "string" }, "timeZone": { "type": "string" }, "durationMinutes": { "type": "integer" }
                            }, "required": ["type", "title", "notes", "startAtUtc", "timeZone", "durationMinutes"] },
                            { "type": "object", "additionalProperties": false, "properties": {
                                "type": { "const": "update_event" }, "eventId": event_ref["eventId"].clone(), "expectedRevision": event_ref["expectedRevision"].clone(),
                                "title": { "type": ["string", "null"] }, "notes": { "type": ["string", "null"] }, "durationMinutes": { "type": ["integer", "null"] }
                            }, "required": ["type", "eventId", "expectedRevision", "title", "notes", "durationMinutes"] },
                            { "type": "object", "additionalProperties": false, "properties": {
                                "type": { "const": "delete_event" }, "eventId": event_ref["eventId"].clone(), "expectedRevision": event_ref["expectedRevision"].clone()
                            }, "required": ["type", "eventId", "expectedRevision"] },
                            { "type": "object", "additionalProperties": false, "properties": {
                                "type": { "const": "reschedule_event" }, "eventId": event_ref["eventId"].clone(), "expectedRevision": event_ref["expectedRevision"].clone(),
                                "startAtUtc": { "type": "string" }, "timeZone": { "type": "string" }, "durationMinutes": { "type": ["integer", "null"] }
                            }, "required": ["type", "eventId", "expectedRevision", "startAtUtc", "timeZone", "durationMinutes"] }
                        ] }
                    }
                }, "required": ["kind", "summary", "operations"]
            },
            {
                "type": "object", "additionalProperties": false,
                "properties": { "kind": { "const": "clarification" }, "question": { "type": "string" } },
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

fn parse_tool_response(body: OllamaChatResponse) -> AppResult<PlannerResponse> {
    let Some(call) = body.message.tool_calls.into_iter().next() else {
        return Err(AppError::InvalidModelResponse(
            "the model did not call propose_schedule_changes".into(),
        ));
    };
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

#[cfg(test)]
mod tests {
    use super::*;

    fn event(id: &str, title: &str) -> ScheduleEvent {
        ScheduleEvent {
            id: id.into(),
            title: title.into(),
            notes: String::new(),
            start_at_utc: "2026-08-12T22:00:00.000Z".into(),
            time_zone: "America/New_York".into(),
            duration_minutes: 60,
            revision: 1,
            created_at: String::new(),
            updated_at: String::new(),
        }
    }

    #[test]
    fn bare_12_hour_time_requires_a_clarification() {
        assert!(has_bare_twelve_hour_time("add dentist Thursday at 2"));
        assert!(!has_bare_twelve_hour_time("add dentist Thursday at 2 pm"));
        assert!(!has_bare_twelve_hour_time("add dentist Thursday at 14:00"));
    }

    #[test]
    fn duplicate_title_requires_a_clarification() {
        let agent = PlannerAgent::default();
        let response = agent.preflight("move gym to 6 pm", &[event("a", "Gym"), event("b", "Gym")]);
        assert!(matches!(
            response,
            Some(PlannerResponse::Clarification { .. })
        ));
    }

    #[test]
    fn a_move_without_a_date_requires_a_clarification() {
        let agent = PlannerAgent::default();
        let response = agent.preflight("move gym to 6 pm", &[event("a", "Gym")]);
        assert!(matches!(
            response,
            Some(PlannerResponse::Clarification { .. })
        ));
    }

    #[test]
    fn session_memory_is_bounded_to_four_turns() {
        let mut agent = PlannerAgent::default();
        for index in 0..5 {
            agent.record(
                &format!("command {index}"),
                &PlannerResponse::Clarification {
                    question: "Which one?".into(),
                },
            );
        }
        assert_eq!(agent.memory_len(), 4);
    }

    #[test]
    fn malformed_tool_output_is_rejected() {
        let malformed =
            json!({ "kind": "proposal", "summary": "Hi", "operations": [], "untrusted": true });
        assert!(serde_json::from_value::<PlannerResponse>(malformed).is_err());
    }
}
