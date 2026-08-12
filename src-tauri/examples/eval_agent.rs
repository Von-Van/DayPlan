use dayplan_desktop::agent::{ollama_status, PlannerAgent};
use dayplan_desktop::db::PlannerDatabase;
use dayplan_desktop::model::{CreateEventInput, MutationOperation, PlannerResponse};
use reqwest::blocking::Client;
use serde::Deserialize;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::PathBuf;
use tempfile::tempdir;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EvalCase {
    id: String,
    command: String,
    day: String,
    time_zone: String,
    #[serde(default)]
    events: Vec<FixtureEvent>,
    #[serde(default)]
    history: Vec<String>,
    expected: ExpectedResponse,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FixtureEvent {
    title: String,
    #[serde(default)]
    notes: String,
    start_at_utc: String,
    time_zone: String,
    duration_minutes: i64,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum ExpectedResponse {
    Proposal { operations: Vec<ExpectedOperation> },
    Clarification,
}

#[derive(Deserialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
enum ExpectedOperation {
    #[serde(rename = "create_event")]
    Create {
        title: String,
        notes: String,
        start_at_utc: String,
        time_zone: String,
        duration_minutes: i64,
    },
    #[serde(rename = "update_event")]
    Update {
        event_title: String,
        title: Option<String>,
        notes: Option<String>,
        duration_minutes: Option<i64>,
    },
    #[serde(rename = "delete_event")]
    Delete { event_title: String },
    #[serde(rename = "reschedule_event")]
    Reschedule {
        event_title: String,
        start_at_utc: String,
        time_zone: String,
        duration_minutes: Option<i64>,
    },
}

fn main() {
    let fixtures = fixture_path().unwrap_or_else(|error| {
        eprintln!("{error}");
        std::process::exit(2)
    });
    let contents = fs::read_to_string(&fixtures).unwrap_or_else(|error| {
        eprintln!("Could not read {}: {error}", fixtures.display());
        std::process::exit(2)
    });
    let cases: Vec<EvalCase> = serde_json::from_str(&contents).unwrap_or_else(|error| {
        eprintln!("Invalid eval fixture JSON: {error}");
        std::process::exit(2)
    });
    let status = ollama_status(&Client::new());
    if !status.running || !status.model_installed {
        eprintln!("Live evaluation cannot start: {}", status.detail);
        std::process::exit(2);
    }
    let mut exact = 0usize;
    let mut valid = 0usize;
    let mut fields_correct = 0usize;
    let mut fields_total = 0usize;
    let mut failures = Vec::new();

    for case in &cases {
        let directory = tempdir().expect("temporary directory");
        let path = directory.path().join("eval.sqlite3");
        let mut database = PlannerDatabase::open(&path).expect("evaluation database");
        let mut titles_by_id = HashMap::new();
        for event in &case.events {
            let created = database
                .create_event(CreateEventInput {
                    title: event.title.clone(),
                    notes: event.notes.clone(),
                    start_at_utc: event.start_at_utc.clone(),
                    time_zone: event.time_zone.clone(),
                    duration_minutes: event.duration_minutes,
                })
                .expect("valid fixture event");
            titles_by_id.insert(created.id, created.title);
        }
        let candidates = database.candidate_events(60).expect("fixture candidates");
        let mut agent = PlannerAgent::default();
        let history_result = case.history.iter().try_for_each(|previous_command| {
            agent
                .propose(previous_command, &case.day, &case.time_zone, &candidates)
                .map(|_| ())
        });
        let actual = history_result
            .and_then(|_| agent.propose(&case.command, &case.day, &case.time_zone, &candidates));
        match actual {
            Ok(response) => {
                valid += 1;
                let (is_exact, correct, total) = score(&case.expected, &response, &titles_by_id);
                if is_exact {
                    exact += 1;
                } else {
                    failures.push(format!(
                        "{}: expected {}, got {}",
                        case.id,
                        expected_description(&case.expected),
                        actual_description(&response, &titles_by_id)
                    ));
                }
                fields_correct += correct;
                fields_total += total;
            }
            Err(error) => {
                fields_total += expected_field_count(&case.expected);
                failures.push(format!("{}: agent error: {error}", case.id));
            }
        }
    }
    let count = cases.len().max(1);
    println!("DayPlan local-agent evaluation — model qwen3:8b");
    println!(
        "Cases: {} | schema-valid responses: {}/{} ({:.1}%)",
        cases.len(),
        valid,
        cases.len(),
        valid as f64 / count as f64 * 100.0
    );
    println!(
        "Exact proposal accuracy: {}/{} ({:.1}%)",
        exact,
        cases.len(),
        exact as f64 / count as f64 * 100.0
    );
    println!(
        "Field accuracy: {}/{} ({:.1}%)",
        fields_correct,
        fields_total,
        percentage(fields_correct, fields_total)
    );
    if !failures.is_empty() {
        println!("\nFailures:");
        for failure in failures {
            println!("- {failure}");
        }
        std::process::exit(1);
    }
}

fn fixture_path() -> Result<PathBuf, String> {
    let mut args = env::args().skip(1);
    match (args.next().as_deref(), args.next()) {
        (Some("--fixtures"), Some(value)) => Ok(PathBuf::from(value)),
        _ => Err("Usage: eval_agent --fixtures path/to/cases.json".into()),
    }
}

fn score(
    expected: &ExpectedResponse,
    actual: &PlannerResponse,
    titles: &HashMap<String, String>,
) -> (bool, usize, usize) {
    match (expected, actual) {
        (ExpectedResponse::Clarification, PlannerResponse::Clarification { .. }) => (true, 1, 1),
        (
            ExpectedResponse::Proposal {
                operations: expected,
            },
            PlannerResponse::Proposal {
                operations: actual, ..
            },
        ) => {
            let mut correct = 0;
            let mut total = 0;
            let mut exact = expected.len() == actual.len();
            for (expected, actual) in expected.iter().zip(actual.iter()) {
                let (matches, matching_fields, all_fields) =
                    score_operation(expected, actual, titles);
                exact &= matches;
                correct += matching_fields;
                total += all_fields;
            }
            if expected.len() != actual.len() {
                total += expected.len().abs_diff(actual.len());
            }
            (exact, correct, total)
        }
        _ => (false, 0, expected_field_count(expected)),
    }
}

fn score_operation(
    expected: &ExpectedOperation,
    actual: &MutationOperation,
    titles: &HashMap<String, String>,
) -> (bool, usize, usize) {
    let mut fields = Vec::new();
    let actual_title = |id: &str| titles.get(id).map(String::as_str).unwrap_or("<unknown>");
    match (expected, actual) {
        (
            ExpectedOperation::Create {
                title,
                notes,
                start_at_utc,
                time_zone,
                duration_minutes,
            },
            MutationOperation::CreateEvent {
                title: a_title,
                notes: a_notes,
                start_at_utc: a_start,
                time_zone: a_zone,
                duration_minutes: a_duration,
            },
        ) => {
            fields.extend([
                title == a_title,
                notes == a_notes,
                start_at_utc == a_start,
                time_zone == a_zone,
                duration_minutes == a_duration,
            ]);
        }
        (
            ExpectedOperation::Update {
                event_title,
                title,
                notes,
                duration_minutes,
            },
            MutationOperation::UpdateEvent {
                event_id,
                title: a_title,
                notes: a_notes,
                duration_minutes: a_duration,
                ..
            },
        ) => {
            fields.push(event_title == actual_title(event_id));
            if let Some(value) = title {
                fields.push(Some(value) == a_title.as_ref());
            }
            if let Some(value) = notes {
                fields.push(Some(value) == a_notes.as_ref());
            }
            if let Some(value) = duration_minutes {
                fields.push(Some(value) == a_duration.as_ref());
            }
        }
        (
            ExpectedOperation::Delete { event_title },
            MutationOperation::DeleteEvent { event_id, .. },
        ) => fields.push(event_title == actual_title(event_id)),
        (
            ExpectedOperation::Reschedule {
                event_title,
                start_at_utc,
                time_zone,
                duration_minutes,
            },
            MutationOperation::RescheduleEvent {
                event_id,
                start_at_utc: a_start,
                time_zone: a_zone,
                duration_minutes: a_duration,
                ..
            },
        ) => {
            fields.extend([
                event_title == actual_title(event_id),
                start_at_utc == a_start,
                time_zone == a_zone,
            ]);
            if let Some(value) = duration_minutes {
                fields.push(Some(value) == a_duration.as_ref());
            }
        }
        _ => return (false, 0, expected_operation_field_count(expected)),
    }
    let matches = fields.iter().all(|matches| *matches);
    (
        matches,
        fields.iter().filter(|matches| **matches).count(),
        fields.len(),
    )
}

fn expected_field_count(expected: &ExpectedResponse) -> usize {
    match expected {
        ExpectedResponse::Clarification => 1,
        ExpectedResponse::Proposal { operations } => {
            operations.iter().map(expected_operation_field_count).sum()
        }
    }
}

fn expected_operation_field_count(operation: &ExpectedOperation) -> usize {
    match operation {
        ExpectedOperation::Create { .. } => 5,
        ExpectedOperation::Update {
            title,
            notes,
            duration_minutes,
            ..
        } => 1 + title.iter().count() + notes.iter().count() + duration_minutes.iter().count(),
        ExpectedOperation::Delete { .. } => 1,
        ExpectedOperation::Reschedule {
            duration_minutes, ..
        } => 3 + duration_minutes.iter().count(),
    }
}

fn percentage(numerator: usize, denominator: usize) -> f64 {
    if denominator == 0 {
        100.0
    } else {
        numerator as f64 / denominator as f64 * 100.0
    }
}

fn expected_description(value: &ExpectedResponse) -> &'static str {
    match value {
        ExpectedResponse::Proposal { .. } => "proposal",
        ExpectedResponse::Clarification => "clarification",
    }
}

fn actual_description(value: &PlannerResponse, _titles: &HashMap<String, String>) -> &'static str {
    match value {
        PlannerResponse::Proposal { .. } => "proposal",
        PlannerResponse::Clarification { .. } => "clarification",
    }
}
