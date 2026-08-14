use chrono::{SecondsFormat, Utc};
use dayplan_desktop::agent::{PlannerAgent, MODEL_NAME};
use dayplan_desktop::db::PlannerDatabase;
use dayplan_desktop::model::{
    CreateEventInput, MutationOperation, PlannerResponse, ReminderChange,
};
use dayplan_desktop::runtime::OllamaRuntimeManager;
use serde::{Deserialize, Serialize};
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
    #[serde(default)]
    reminder_minutes_before: Option<i64>,
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
        #[serde(default)]
        reminder_minutes_before: Option<i64>,
    },
    #[serde(rename = "update_event")]
    Update {
        event_title: String,
        title: Option<String>,
        notes: Option<String>,
        duration_minutes: Option<i64>,
        #[serde(default)]
        reminder_change: Option<ReminderChange>,
    },
    #[serde(rename = "delete_event")]
    Delete { event_title: String },
    #[serde(rename = "reschedule_event")]
    Reschedule {
        event_title: String,
        title: Option<String>,
        notes: Option<String>,
        start_at_utc: String,
        time_zone: String,
        duration_minutes: Option<i64>,
        #[serde(default)]
        reminder_change: Option<ReminderChange>,
    },
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EvalReport {
    generated_at: String,
    model_name: String,
    model_digest: Option<String>,
    ollama_version: Option<String>,
    fixture_count: usize,
    runs: Vec<RunReport>,
    passed: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RunReport {
    run: usize,
    schema_valid: usize,
    exact: usize,
    fields_correct: usize,
    fields_total: usize,
    safety_exact: usize,
    safety_total: usize,
    failures: Vec<String>,
    passed: bool,
}

struct EvalOptions {
    fixtures: PathBuf,
    runs: usize,
    json_output: Option<PathBuf>,
}

#[tokio::main]
async fn main() {
    let options = eval_options().unwrap_or_else(|error| {
        eprintln!("{error}");
        std::process::exit(2)
    });
    let contents = fs::read_to_string(&options.fixtures).unwrap_or_else(|error| {
        eprintln!("Could not read {}: {error}", options.fixtures.display());
        std::process::exit(2)
    });
    let cases: Vec<EvalCase> = serde_json::from_str(&contents).unwrap_or_else(|error| {
        eprintln!("Invalid eval fixture JSON: {error}");
        std::process::exit(2)
    });
    let runtime = OllamaRuntimeManager::new(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")),
        eval_data_directory(),
    )
    .unwrap_or_else(|error| {
        eprintln!("Live evaluation cannot initialize DayPlan's bundled runtime: {error}");
        std::process::exit(2)
    });
    let agent = PlannerAgent::new(runtime.endpoint(), MODEL_NAME);
    let status = runtime.status(&agent).await;
    if !status.running || !status.model_installed {
        eprintln!("Live evaluation cannot start: {}", status.detail);
        std::process::exit(2);
    }
    let mut runs = Vec::new();
    for run in 1..=options.runs {
        let result = evaluate_run(run, &cases, runtime.endpoint()).await;
        print_run(&result, cases.len());
        runs.push(result);
    }
    let passed = runs.iter().all(|run| run.passed);
    let report = EvalReport {
        generated_at: Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
        model_name: status.model_name,
        model_digest: status.model_digest,
        ollama_version: status.ollama_version,
        fixture_count: cases.len(),
        runs,
        passed,
    };
    if let Some(path) = options.json_output {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap_or_else(|error| {
                eprintln!("Could not create {}: {error}", parent.display());
                std::process::exit(2)
            });
        }
        fs::write(
            &path,
            serde_json::to_vec_pretty(&report).expect("serialize report"),
        )
        .unwrap_or_else(|error| {
            eprintln!("Could not write {}: {error}", path.display());
            std::process::exit(2)
        });
        println!("Machine-readable report: {}", path.display());
    }
    if !passed {
        std::process::exit(1);
    }
}

fn eval_data_directory() -> PathBuf {
    if let Some(path) = env::var_os("DAYPLAN_EVAL_DATA_DIR") {
        return PathBuf::from(path);
    }
    #[cfg(target_os = "macos")]
    if let Some(home) = env::var_os("HOME") {
        return PathBuf::from(home).join("Library/Application Support/com.vonvan.dayplan.desktop");
    }
    #[cfg(target_os = "windows")]
    if let Some(app_data) = env::var_os("APPDATA") {
        return PathBuf::from(app_data).join("com.vonvan.dayplan.desktop");
    }
    env::temp_dir().join("dayplan-eval-data")
}

fn eval_options() -> Result<EvalOptions, String> {
    let mut args = env::args().skip(1);
    let mut fixtures = None;
    let mut runs = 1usize;
    let mut json_output = None;
    while let Some(argument) = args.next() {
        match argument.as_str() {
            "--fixtures" => fixtures = args.next().map(PathBuf::from),
            "--runs" => {
                runs = args
                    .next()
                    .ok_or("--runs requires a positive integer")?
                    .parse()
                    .map_err(|_| "--runs requires a positive integer")?;
                if runs == 0 {
                    return Err("--runs requires a positive integer".into());
                }
            }
            "--json-output" => json_output = args.next().map(PathBuf::from),
            _ => return Err(format!("Unknown argument: {argument}")),
        }
    }
    Ok(EvalOptions {
        fixtures: fixtures
            .ok_or("Usage: eval_agent --fixtures path [--runs 3] [--json-output path]")?,
        runs,
        json_output,
    })
}

async fn evaluate_run(run: usize, cases: &[EvalCase], endpoint: &str) -> RunReport {
    let mut result = RunReport {
        run,
        schema_valid: 0,
        exact: 0,
        fields_correct: 0,
        fields_total: 0,
        safety_exact: 0,
        safety_total: cases
            .iter()
            .filter(|case| matches!(case.expected, ExpectedResponse::Clarification))
            .count(),
        failures: Vec::new(),
        passed: false,
    };
    for case in cases {
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
                    reminder_minutes_before: event.reminder_minutes_before,
                })
                .expect("valid fixture event");
            titles_by_id.insert(created.id, created.title);
        }
        let candidates = database
            .candidate_events(&case.command, &case.day, &case.time_zone, &[], 60)
            .expect("fixture candidates");
        let agent = PlannerAgent::new(endpoint, MODEL_NAME);
        let mut history_result = Ok(());
        for previous_command in &case.history {
            if let Err(error) = agent
                .propose(previous_command, &case.day, &case.time_zone, &candidates)
                .await
            {
                history_result = Err(error);
                break;
            }
        }
        let actual = match history_result {
            Ok(()) => {
                agent
                    .propose(&case.command, &case.day, &case.time_zone, &candidates)
                    .await
            }
            Err(error) => Err(error),
        };
        match actual {
            Ok(response) => {
                result.schema_valid += 1;
                let (is_exact, correct, total) = score(&case.expected, &response, &titles_by_id);
                if is_exact {
                    result.exact += 1;
                    if matches!(case.expected, ExpectedResponse::Clarification) {
                        result.safety_exact += 1;
                    }
                } else {
                    result.failures.push(format!(
                        "{}: expected {}, got {}",
                        case.id,
                        expected_description(&case.expected),
                        actual_description(&response, &titles_by_id)
                    ));
                }
                result.fields_correct += correct;
                result.fields_total += total;
            }
            Err(error) => {
                result.fields_total += expected_field_count(&case.expected);
                result
                    .failures
                    .push(format!("{}: agent error: {error}", case.id));
            }
        }
    }
    result.passed = result.schema_valid == cases.len()
        && result.safety_exact == result.safety_total
        && percentage(result.exact, cases.len()) >= 85.0
        && percentage(result.fields_correct, result.fields_total) >= 95.0;
    result
}

fn print_run(result: &RunReport, case_count: usize) {
    println!("DayPlan qwen3:8b evaluation — run {}", result.run);
    println!(
        "Schema valid: {}/{} ({:.1}%) | exact: {}/{} ({:.1}%) | fields: {}/{} ({:.1}%) | safety: {}/{}",
        result.schema_valid,
        case_count,
        percentage(result.schema_valid, case_count),
        result.exact,
        case_count,
        percentage(result.exact, case_count),
        result.fields_correct,
        result.fields_total,
        percentage(result.fields_correct, result.fields_total),
        result.safety_exact,
        result.safety_total
    );
    if !result.failures.is_empty() {
        println!("Failures:");
        for failure in &result.failures {
            println!("- {failure}");
        }
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
            let mut expected_ordered = expected.iter().collect::<Vec<_>>();
            expected_ordered.sort_by_key(|operation| expected_operation_key(operation));
            let mut actual_ordered = actual.iter().collect::<Vec<_>>();
            actual_ordered.sort_by_key(|operation| actual_operation_key(operation, titles));
            for (expected, actual) in expected_ordered.into_iter().zip(actual_ordered) {
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

fn expected_operation_key(operation: &ExpectedOperation) -> String {
    match operation {
        ExpectedOperation::Create {
            title,
            start_at_utc,
            ..
        } => format!("create:{title}:{start_at_utc}"),
        ExpectedOperation::Update { event_title, .. } => format!("update:{event_title}"),
        ExpectedOperation::Delete { event_title } => format!("delete:{event_title}"),
        ExpectedOperation::Reschedule { event_title, .. } => {
            format!("reschedule:{event_title}")
        }
    }
}

fn actual_operation_key(operation: &MutationOperation, titles: &HashMap<String, String>) -> String {
    let event_title = |id: &str| titles.get(id).map(String::as_str).unwrap_or("<unknown>");
    match operation {
        MutationOperation::CreateEvent {
            title,
            start_at_utc,
            ..
        } => format!("create:{title}:{start_at_utc}"),
        MutationOperation::UpdateEvent { event_id, .. } => {
            format!("update:{}", event_title(event_id))
        }
        MutationOperation::DeleteEvent { event_id, .. } => {
            format!("delete:{}", event_title(event_id))
        }
        MutationOperation::RescheduleEvent { event_id, .. } => {
            format!("reschedule:{}", event_title(event_id))
        }
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
                reminder_minutes_before,
            },
            MutationOperation::CreateEvent {
                title: a_title,
                notes: a_notes,
                start_at_utc: a_start,
                time_zone: a_zone,
                duration_minutes: a_duration,
                reminder_minutes_before: a_reminder,
            },
        ) => {
            fields.extend([
                title == a_title,
                notes == a_notes,
                start_at_utc == a_start,
                time_zone == a_zone,
                duration_minutes == a_duration,
                reminder_minutes_before == a_reminder,
            ]);
        }
        (
            ExpectedOperation::Update {
                event_title,
                title,
                notes,
                duration_minutes,
                reminder_change,
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
            if let Some(value) = reminder_change {
                if let MutationOperation::UpdateEvent {
                    reminder_change: actual,
                    ..
                } = actual
                {
                    fields.push(value == actual);
                }
            }
        }
        (
            ExpectedOperation::Delete { event_title },
            MutationOperation::DeleteEvent { event_id, .. },
        ) => fields.push(event_title == actual_title(event_id)),
        (
            ExpectedOperation::Reschedule {
                event_title,
                title,
                notes,
                start_at_utc,
                time_zone,
                duration_minutes,
                reminder_change,
            },
            MutationOperation::RescheduleEvent {
                event_id,
                title: a_title,
                notes: a_notes,
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
            if let Some(value) = title {
                fields.push(Some(value) == a_title.as_ref());
            }
            if let Some(value) = notes {
                fields.push(Some(value) == a_notes.as_ref());
            }
            if let Some(value) = duration_minutes {
                fields.push(Some(value) == a_duration.as_ref());
            }
            if let Some(value) = reminder_change {
                if let MutationOperation::RescheduleEvent {
                    reminder_change: actual,
                    ..
                } = actual
                {
                    fields.push(value == actual);
                }
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
        ExpectedOperation::Create { .. } => 6,
        ExpectedOperation::Update {
            title,
            notes,
            duration_minutes,
            reminder_change,
            ..
        } => {
            1 + title.iter().count()
                + notes.iter().count()
                + duration_minutes.iter().count()
                + reminder_change.iter().count()
        }
        ExpectedOperation::Delete { .. } => 1,
        ExpectedOperation::Reschedule {
            title,
            notes,
            duration_minutes,
            reminder_change,
            ..
        } => {
            3 + title.iter().count()
                + notes.iter().count()
                + duration_minutes.iter().count()
                + reminder_change.iter().count()
        }
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
