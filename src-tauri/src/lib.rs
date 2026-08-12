pub mod agent;
pub mod db;
pub mod error;
pub mod model;

use agent::{ollama_status, OllamaStatus, PlannerAgent};
use db::PlannerDatabase;
use model::{
    CreateEventInput, CreateTaskInput, DailyTask, PlannerResponse, RescheduleEventInput,
    ScheduleEvent, UpdateEventInput, UpdateTaskInput,
};
use reqwest::blocking::Client;
use serde::Serialize;
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{Manager, State};

struct AppState {
    database_path: PathBuf,
    agent: Mutex<PlannerAgent>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Agenda {
    events: Vec<ScheduleEvent>,
    tasks: Vec<DailyTask>,
}

fn open_database(state: &State<'_, AppState>) -> Result<PlannerDatabase, String> {
    PlannerDatabase::open(&state.database_path).map_err(|error| error.to_string())
}

#[tauri::command]
fn list_agenda(
    state: State<'_, AppState>,
    day: String,
    time_zone: String,
) -> Result<Agenda, String> {
    let database = open_database(&state)?;
    Ok(Agenda {
        events: database
            .events_for_day(&day, &time_zone)
            .map_err(|error| error.to_string())?,
        tasks: database
            .tasks_for_day(&day)
            .map_err(|error| error.to_string())?,
    })
}

#[tauri::command]
fn create_event(
    state: State<'_, AppState>,
    input: CreateEventInput,
) -> Result<ScheduleEvent, String> {
    open_database(&state)?
        .create_event(input)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn update_event(
    state: State<'_, AppState>,
    input: UpdateEventInput,
) -> Result<ScheduleEvent, String> {
    open_database(&state)?
        .update_event(input)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn delete_event(state: State<'_, AppState>, id: String, revision: i64) -> Result<(), String> {
    open_database(&state)?
        .delete_event(&id, revision)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn reschedule_event(
    state: State<'_, AppState>,
    input: RescheduleEventInput,
) -> Result<ScheduleEvent, String> {
    open_database(&state)?
        .reschedule_event(input)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn create_task(state: State<'_, AppState>, input: CreateTaskInput) -> Result<DailyTask, String> {
    open_database(&state)?
        .create_task(input)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn update_task(state: State<'_, AppState>, input: UpdateTaskInput) -> Result<DailyTask, String> {
    open_database(&state)?
        .update_task(input)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn delete_task(state: State<'_, AppState>, id: String) -> Result<(), String> {
    open_database(&state)?
        .delete_task(&id)
        .map_err(|error| error.to_string())
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
) -> Result<PlannerResponse, String> {
    let candidates = open_database(&state)?
        .candidate_events(60)
        .map_err(|error| error.to_string())?;
    let mut agent = state
        .agent
        .lock()
        .map_err(|_| "The local planner session is unavailable.".to_string())?;
    agent
        .propose(&command, &day, &time_zone, &candidates)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn apply_schedule_changes(
    state: State<'_, AppState>,
    proposal: PlannerResponse,
) -> Result<Vec<ScheduleEvent>, String> {
    open_database(&state)?
        .apply_proposal(&proposal)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn clear_planner_context(state: State<'_, AppState>) -> Result<(), String> {
    state
        .agent
        .lock()
        .map_err(|_| "The local planner session is unavailable.".to_string())?
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
                database_path: directory.join("dayplan.sqlite3"),
                agent: Mutex::new(PlannerAgent::default()),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_agenda,
            create_event,
            update_event,
            delete_event,
            reschedule_event,
            create_task,
            update_task,
            delete_task,
            current_ollama_status,
            propose_schedule_changes,
            apply_schedule_changes,
            clear_planner_context,
        ])
        .run(tauri::generate_context!())
        .expect("error while running DayPlan desktop");
}
