pub mod agent;
pub mod db;
pub mod error;
pub mod model;

use agent::{ollama_status, OllamaStatus, PlannerAgent};
use db::{backups_for_path, restore_backup, PlannerDatabase, CURRENT_SCHEMA_VERSION};
use error::{AppError, CommandError};
use model::{
    CreateEventInput, CreateTaskInput, DailyTask, DatabaseStatus, ExportBundle, ImportPreview,
    LocalDateTimeInput, LocalDateTimeResolution, PlannerResponse, RescheduleEventInput,
    ScheduleEvent, UpdateEventInput, UpdateTaskInput,
};
use reqwest::blocking::Client;
use serde::Serialize;
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{Manager, State};

struct AppState {
    database: Mutex<DatabaseRuntime>,
    agent: Mutex<PlannerAgent>,
}

struct DatabaseRuntime {
    path: PathBuf,
    database: Option<PlannerDatabase>,
    startup_error: Option<CommandError>,
}

impl DatabaseRuntime {
    fn new(path: PathBuf) -> Self {
        match PlannerDatabase::open(&path) {
            Ok(database) => Self {
                path,
                database: Some(database),
                startup_error: None,
            },
            Err(error) => Self {
                path,
                database: None,
                startup_error: Some(error.into()),
            },
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Agenda {
    events: Vec<ScheduleEvent>,
    tasks: Vec<DailyTask>,
}

fn with_database<T>(
    state: &State<'_, AppState>,
    operation: impl FnOnce(&mut PlannerDatabase) -> Result<T, AppError>,
) -> Result<T, CommandError> {
    let mut runtime = state
        .database
        .lock()
        .map_err(|_| CommandError::internal("The local database session is unavailable."))?;
    if runtime.database.is_none() {
        return Err(runtime
            .startup_error
            .clone()
            .unwrap_or_else(|| CommandError::internal("The local database could not be opened.")));
    }
    let database = runtime
        .database
        .as_mut()
        .expect("database presence checked");
    operation(database).map_err(CommandError::from)
}

#[tauri::command]
fn list_agenda(
    state: State<'_, AppState>,
    day: String,
    time_zone: String,
) -> Result<Agenda, CommandError> {
    with_database(&state, |database| {
        Ok(Agenda {
            events: database.events_for_day(&day, &time_zone)?,
            tasks: database.tasks_for_day(&day)?,
        })
    })
}

#[tauri::command]
fn database_status(state: State<'_, AppState>) -> Result<DatabaseStatus, CommandError> {
    let runtime = state
        .database
        .lock()
        .map_err(|_| CommandError::internal("The local database session is unavailable."))?;
    let backups = backups_for_path(&runtime.path).unwrap_or_default();
    let schema_version = runtime
        .database
        .as_ref()
        .and_then(|database| database.schema_version().ok())
        .unwrap_or(CURRENT_SCHEMA_VERSION);
    Ok(DatabaseStatus {
        ready: runtime.database.is_some(),
        schema_version,
        error: runtime.startup_error.clone(),
        backups,
    })
}

#[tauri::command]
fn create_event(
    state: State<'_, AppState>,
    input: CreateEventInput,
) -> Result<ScheduleEvent, CommandError> {
    with_database(&state, |database| database.create_event(input))
}

#[tauri::command]
fn update_event(
    state: State<'_, AppState>,
    input: UpdateEventInput,
) -> Result<ScheduleEvent, CommandError> {
    with_database(&state, |database| database.update_event(input))
}

#[tauri::command]
fn delete_event(state: State<'_, AppState>, id: String, revision: i64) -> Result<(), CommandError> {
    with_database(&state, |database| database.delete_event(&id, revision))
}

#[tauri::command]
fn reschedule_event(
    state: State<'_, AppState>,
    input: RescheduleEventInput,
) -> Result<ScheduleEvent, CommandError> {
    with_database(&state, |database| database.reschedule_event(input))
}

#[tauri::command]
fn create_task(
    state: State<'_, AppState>,
    input: CreateTaskInput,
) -> Result<DailyTask, CommandError> {
    with_database(&state, |database| database.create_task(input))
}

#[tauri::command]
fn update_task(
    state: State<'_, AppState>,
    input: UpdateTaskInput,
) -> Result<DailyTask, CommandError> {
    with_database(&state, |database| database.update_task(input))
}

#[tauri::command]
fn delete_task(state: State<'_, AppState>, id: String) -> Result<(), CommandError> {
    with_database(&state, |database| database.delete_task(&id))
}

#[tauri::command]
fn resolve_local_datetime(
    input: LocalDateTimeInput,
) -> Result<LocalDateTimeResolution, CommandError> {
    PlannerDatabase::resolve_local_datetime(&input).map_err(CommandError::from)
}

#[tauri::command]
fn export_planner_data(state: State<'_, AppState>) -> Result<ExportBundle, CommandError> {
    with_database(&state, |database| database.export_bundle())
}

#[tauri::command]
fn preview_planner_import(bundle: ExportBundle) -> Result<ImportPreview, CommandError> {
    PlannerDatabase::preview_import(&bundle).map_err(CommandError::from)
}

#[tauri::command]
fn import_planner_data(
    state: State<'_, AppState>,
    bundle: ExportBundle,
) -> Result<ImportPreview, CommandError> {
    with_database(&state, |database| database.import_bundle(&bundle))
}

#[tauri::command]
fn restore_database_backup(
    state: State<'_, AppState>,
    backup_name: String,
) -> Result<(), CommandError> {
    let mut runtime = state
        .database
        .lock()
        .map_err(|_| CommandError::internal("The local database session is unavailable."))?;
    if let Some(database) = runtime.database.as_ref() {
        database.backup("pre-restore").map_err(CommandError::from)?;
    }
    runtime.database.take();
    let result = restore_backup(&runtime.path, &backup_name)
        .and_then(|()| PlannerDatabase::open(&runtime.path));
    match result {
        Ok(database) => {
            runtime.database = Some(database);
            runtime.startup_error = None;
            Ok(())
        }
        Err(error) => {
            let command_error = CommandError::from(error);
            runtime.database = PlannerDatabase::open(&runtime.path).ok();
            runtime.startup_error = Some(command_error.clone());
            Err(command_error)
        }
    }
}

#[tauri::command]
fn current_ollama_status() -> OllamaStatus {
    ollama_status(&Client::new())
}

#[tauri::command]
fn propose_schedule_changes(
    state: State<'_, AppState>,
    command: String,
    day: String,
    time_zone: String,
) -> Result<PlannerResponse, CommandError> {
    let candidates = with_database(&state, |database| {
        database.candidate_events(&command, &day, &time_zone, &[], 60)
    })?;
    let mut agent = state
        .agent
        .lock()
        .map_err(|_| CommandError::internal("The local planner session is unavailable."))?;
    agent
        .propose(&command, &day, &time_zone, &candidates)
        .map_err(CommandError::from)
}

#[tauri::command]
fn apply_schedule_changes(
    state: State<'_, AppState>,
    proposal: PlannerResponse,
) -> Result<Vec<ScheduleEvent>, CommandError> {
    with_database(&state, |database| database.apply_proposal(&proposal))
}

#[tauri::command]
fn clear_planner_context(state: State<'_, AppState>) -> Result<(), CommandError> {
    state
        .agent
        .lock()
        .map_err(|_| CommandError::internal("The local planner session is unavailable."))?
        .clear_context();
    Ok(())
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let directory = app
                .path()
                .app_data_dir()
                .map_err(|error| error.to_string())?;
            fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
            app.manage(AppState {
                database: Mutex::new(DatabaseRuntime::new(directory.join("dayplan.sqlite3"))),
                agent: Mutex::new(PlannerAgent::default()),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_agenda,
            database_status,
            create_event,
            update_event,
            delete_event,
            reschedule_event,
            create_task,
            update_task,
            delete_task,
            resolve_local_datetime,
            export_planner_data,
            preview_planner_import,
            import_planner_data,
            restore_database_backup,
            current_ollama_status,
            propose_schedule_changes,
            apply_schedule_changes,
            clear_planner_context,
        ])
        .run(tauri::generate_context!())
        .expect("error while running DayPlan desktop");
}
