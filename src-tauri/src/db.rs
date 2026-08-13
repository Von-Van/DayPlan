use crate::error::{AppError, AppResult};
use crate::model::{
    BackupInfo, CreateEventInput, CreateTaskInput, DailyTask, ExportBundle, ImportPreview,
    LocalDateTimeInput, LocalDateTimeResolution, LocalTimeOption, MutationOperation,
    PlannerResponse, RescheduleEventInput, ScheduleEvent, UpdateEventInput, UpdateTaskInput,
    MAX_NOTES_LENGTH, MAX_OPERATIONS, MAX_TITLE_LENGTH,
};
use chrono::{DateTime, LocalResult, NaiveDate, NaiveDateTime, NaiveTime, Offset, TimeZone, Utc};
use chrono_tz::Tz;
use rusqlite::{params, Connection, OptionalExtension, Row, Transaction, TransactionBehavior};
use std::cmp::Reverse;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

pub const CURRENT_SCHEMA_VERSION: u32 = 1;
pub const EXPORT_FORMAT_VERSION: u32 = 1;
const BACKUP_RETENTION: usize = 5;

pub struct PlannerDatabase {
    connection: Connection,
    path: PathBuf,
}

impl PlannerDatabase {
    pub fn open(path: &Path) -> AppResult<Self> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let existed = path.exists()
            && path
                .metadata()
                .map(|metadata| metadata.len() > 0)
                .unwrap_or(false);
        let connection = Connection::open(path)?;
        connection.execute_batch("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")?;
        let version = schema_version(&connection)?;
        if version > CURRENT_SCHEMA_VERSION {
            return Err(AppError::UnsupportedDatabaseVersion);
        }
        if version < CURRENT_SCHEMA_VERSION {
            connection.execute_batch("PRAGMA wal_checkpoint(FULL);")?;
            if existed {
                create_backup_file(path, version, "migration")?;
            }
            migrate(&connection, version)?;
        }
        verify_integrity(&connection)?;
        Ok(Self {
            connection,
            path: path.to_path_buf(),
        })
    }

    pub fn schema_version(&self) -> AppResult<u32> {
        schema_version(&self.connection)
    }

    pub fn list_backups(&self) -> AppResult<Vec<BackupInfo>> {
        list_backup_files(&self.path)
    }

    pub fn backup(&self, reason: &str) -> AppResult<BackupInfo> {
        self.connection
            .execute_batch("PRAGMA wal_checkpoint(FULL);")?;
        create_backup_file(&self.path, self.schema_version()?, reason)
    }

    pub fn export_bundle(&self) -> AppResult<ExportBundle> {
        Ok(ExportBundle {
            format_version: EXPORT_FORMAT_VERSION,
            exported_at: now(),
            events: self.all_events()?,
            tasks: self.all_tasks()?,
        })
    }

    pub fn preview_import(bundle: &ExportBundle) -> AppResult<ImportPreview> {
        validate_export_bundle(bundle)?;
        let mut days = bundle
            .tasks
            .iter()
            .map(|task| task.day.clone())
            .collect::<Vec<_>>();
        for event in &bundle.events {
            let parsed = DateTime::parse_from_rfc3339(&event.start_at_utc).map_err(|_| {
                AppError::Validation("An imported event has an invalid start time.".into())
            })?;
            days.push(parsed.date_naive().format("%Y-%m-%d").to_string());
        }
        days.sort();
        Ok(ImportPreview {
            event_count: bundle.events.len(),
            task_count: bundle.tasks.len(),
            earliest_day: days.first().cloned(),
            latest_day: days.last().cloned(),
        })
    }

    pub fn import_bundle(&mut self, bundle: &ExportBundle) -> AppResult<ImportPreview> {
        let preview = Self::preview_import(bundle)?;
        self.backup("import")?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute("DELETE FROM daily_tasks", [])?;
        transaction.execute("DELETE FROM schedule_events", [])?;
        for event in &bundle.events {
            transaction.execute(
                "INSERT INTO schedule_events (id, title, notes, start_at_utc, time_zone, duration_minutes, revision, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![event.id, event.title.trim(), event.notes.trim(), event.start_at_utc, event.time_zone, event.duration_minutes, event.revision, event.created_at, event.updated_at],
            )?;
        }
        for task in &bundle.tasks {
            transaction.execute(
                "INSERT INTO daily_tasks (id, title, day, completed, completed_at, sort_order, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![task.id, task.title.trim(), task.day, task.completed as i64, task.completed_at, task.sort_order, task.created_at, task.updated_at],
            )?;
        }
        transaction.commit()?;
        Ok(preview)
    }

    pub fn resolve_local_datetime(
        input: &LocalDateTimeInput,
    ) -> AppResult<LocalDateTimeResolution> {
        let date = parse_day(&input.day)?;
        let time = NaiveTime::parse_from_str(&input.time, "%H:%M")
            .map_err(|_| AppError::Validation("Times must use 24-hour HH:MM format.".into()))?;
        let zone = parse_time_zone(&input.time_zone)?;
        let local = NaiveDateTime::new(date, time);
        Ok(match zone.from_local_datetime(&local) {
            LocalResult::Single(value) => LocalDateTimeResolution::Resolved {
                start_at_utc: utc_string(value.with_timezone(&Utc)),
            },
            LocalResult::Ambiguous(first, second) => LocalDateTimeResolution::Ambiguous {
                options: [first, second]
                    .into_iter()
                    .map(|value| {
                        let offset = value.offset().fix().local_minus_utc() / 60;
                        LocalTimeOption {
                            start_at_utc: utc_string(value.with_timezone(&Utc)),
                            utc_offset_minutes: offset,
                            label: format!("{} (UTC{:+03}:{:02})", value.format("%H:%M"), offset / 60, offset.abs() % 60),
                        }
                    })
                    .collect(),
            },
            LocalResult::None => LocalDateTimeResolution::Nonexistent {
                message: "That local time does not exist because the clock moves forward. Choose another time.".into(),
            },
        })
    }

    fn all_events(&self) -> AppResult<Vec<ScheduleEvent>> {
        let mut statement = self.connection.prepare(
            "SELECT id, title, notes, start_at_utc, time_zone, duration_minutes, revision, created_at, updated_at
             FROM schedule_events ORDER BY start_at_utc ASC, created_at ASC",
        )?;
        let rows = statement.query_map([], event_from_row)?;
        collect(rows)
    }

    fn all_tasks(&self) -> AppResult<Vec<DailyTask>> {
        let mut statement = self.connection.prepare(
            "SELECT id, title, day, completed, completed_at, sort_order, created_at, updated_at
             FROM daily_tasks ORDER BY day ASC, sort_order ASC, created_at ASC",
        )?;
        let rows = statement.query_map([], task_from_row)?;
        collect(rows)
    }

    fn create_latest_schema(connection: &Connection) -> AppResult<()> {
        connection.execute_batch(
            "CREATE TABLE IF NOT EXISTS schedule_events (
                 id TEXT PRIMARY KEY NOT NULL,
                 title TEXT NOT NULL,
                 notes TEXT NOT NULL DEFAULT '',
                 start_at_utc TEXT NOT NULL,
                 time_zone TEXT NOT NULL,
                 duration_minutes INTEGER NOT NULL CHECK(duration_minutes BETWEEN 5 AND 1440),
                 revision INTEGER NOT NULL DEFAULT 1,
                 created_at TEXT NOT NULL,
                 updated_at TEXT NOT NULL
             );
             CREATE INDEX IF NOT EXISTS schedule_events_start_idx ON schedule_events(start_at_utc);
             CREATE TABLE IF NOT EXISTS daily_tasks (
                 id TEXT PRIMARY KEY NOT NULL,
                 title TEXT NOT NULL,
                 day TEXT NOT NULL,
                 completed INTEGER NOT NULL DEFAULT 0,
                 completed_at TEXT,
                 sort_order INTEGER NOT NULL DEFAULT 0,
                 created_at TEXT NOT NULL,
                 updated_at TEXT NOT NULL
             );
             CREATE INDEX IF NOT EXISTS daily_tasks_day_idx ON daily_tasks(day, sort_order);",
        )?;
        Ok(())
    }

    pub fn create_event(&mut self, input: CreateEventInput) -> AppResult<ScheduleEvent> {
        let prepared = PreparedEvent::from_input(input)?;
        insert_event(&self.connection, prepared)
    }

    pub fn update_event(&mut self, input: UpdateEventInput) -> AppResult<ScheduleEvent> {
        let existing = self.event_by_id(&input.id)?.ok_or(AppError::NotFound)?;
        if existing.revision != input.revision {
            return Err(AppError::Conflict);
        }
        let title = input.title.unwrap_or(existing.title);
        let notes = input.notes.unwrap_or(existing.notes);
        let start_at_utc = input.start_at_utc.unwrap_or(existing.start_at_utc);
        let time_zone = input.time_zone.unwrap_or(existing.time_zone);
        let duration_minutes = input.duration_minutes.unwrap_or(existing.duration_minutes);
        validate_title(&title)?;
        validate_notes(&notes)?;
        let (start_at_utc, time_zone) = validate_time(&start_at_utc, &time_zone)?;
        validate_duration(duration_minutes)?;
        let now = now();
        let changed = self.connection.execute(
            "UPDATE schedule_events
             SET title = ?1, notes = ?2, start_at_utc = ?3, time_zone = ?4,
                 duration_minutes = ?5, revision = revision + 1, updated_at = ?6
             WHERE id = ?7 AND revision = ?8",
            params![
                title.trim(),
                notes.trim(),
                start_at_utc,
                time_zone,
                duration_minutes,
                now,
                input.id,
                input.revision
            ],
        )?;
        if changed != 1 {
            return Err(AppError::Conflict);
        }
        self.event_by_id(&existing.id)?.ok_or(AppError::NotFound)
    }

    pub fn delete_event(&mut self, id: &str, revision: i64) -> AppResult<()> {
        let changed = self.connection.execute(
            "DELETE FROM schedule_events WHERE id = ?1 AND revision = ?2",
            params![id, revision],
        )?;
        match changed {
            1 => Ok(()),
            0 if self.event_by_id(id)?.is_some() => Err(AppError::Conflict),
            _ => Err(AppError::NotFound),
        }
    }

    pub fn reschedule_event(&mut self, input: RescheduleEventInput) -> AppResult<ScheduleEvent> {
        let (start_at_utc, time_zone) = validate_time(&input.start_at_utc, &input.time_zone)?;
        validate_duration(input.duration_minutes)?;
        let changed = self.connection.execute(
            "UPDATE schedule_events SET start_at_utc=?1, time_zone=?2, duration_minutes=?3, revision=revision+1, updated_at=?4
             WHERE id=?5 AND revision=?6",
            params![start_at_utc, time_zone, input.duration_minutes, now(), input.id, input.revision],
        )?;
        match changed {
            1 => self.event_by_id(&input.id)?.ok_or(AppError::NotFound),
            0 if self.event_by_id(&input.id)?.is_some() => Err(AppError::Conflict),
            _ => Err(AppError::NotFound),
        }
    }

    pub fn events_for_day(&self, day: &str, time_zone: &str) -> AppResult<Vec<ScheduleEvent>> {
        let (start, end) = day_bounds(day, time_zone)?;
        let mut statement = self.connection.prepare(
            "SELECT id, title, notes, start_at_utc, time_zone, duration_minutes, revision, created_at, updated_at
             FROM schedule_events
             WHERE julianday(start_at_utc) < julianday(?2)
               AND julianday(start_at_utc, printf('+%d minutes', duration_minutes)) > julianday(?1)
             ORDER BY start_at_utc ASC, created_at ASC",
        )?;
        let rows = statement.query_map(params![start, end], event_from_row)?;
        collect(rows)
    }

    pub fn candidate_events(
        &self,
        command: &str,
        selected_day: &str,
        viewer_time_zone: &str,
        referenced_ids: &[String],
        limit: usize,
    ) -> AppResult<Vec<ScheduleEvent>> {
        let events = self.all_events()?;
        let zone = parse_time_zone(viewer_time_zone)?;
        let selected = parse_day(selected_day)?;
        let selected_noon = zone
            .from_local_datetime(
                &selected.and_hms_opt(12, 0, 0).ok_or_else(|| {
                    AppError::Validation("The selected day is out of range.".into())
                })?,
            )
            .earliest()
            .ok_or_else(|| {
                AppError::Validation("The selected day is invalid in this time zone.".into())
            })?
            .with_timezone(&Utc);
        let tokens = search_tokens(command);
        let referenced: HashSet<&str> = referenced_ids.iter().map(String::as_str).collect();
        let mut scored = events
            .into_iter()
            .map(|event| {
                let start = DateTime::parse_from_rfc3339(&event.start_at_utc)
                    .map(|value| value.with_timezone(&Utc))
                    .unwrap_or(selected_noon);
                let distance_hours = (start - selected_noon).num_hours().unsigned_abs() as usize;
                let title = event.title.to_ascii_lowercase();
                let token_matches = tokens
                    .iter()
                    .filter(|token| title.contains(token.as_str()))
                    .count();
                let score = if referenced.contains(event.id.as_str()) {
                    100_000
                } else {
                    0
                } + token_matches * 10_000
                    + 5_000usize.saturating_sub(distance_hours.min(5_000));
                (score, distance_hours, event)
            })
            .collect::<Vec<_>>();
        scored.sort_by_key(|(score, distance, _)| (Reverse(*score), *distance));
        Ok(scored
            .into_iter()
            .take(limit.min(60))
            .map(|(_, _, mut event)| {
                event.notes.clear();
                event
            })
            .collect())
    }

    pub fn create_task(&mut self, input: CreateTaskInput) -> AppResult<DailyTask> {
        validate_title(&input.title)?;
        validate_day(&input.day)?;
        let id = Uuid::new_v4().to_string();
        let timestamp = now();
        let next_order: i64 = self.connection.query_row(
            "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM daily_tasks WHERE day = ?1",
            params![input.day],
            |row| row.get(0),
        )?;
        self.connection.execute(
            "INSERT INTO daily_tasks (id, title, day, completed, completed_at, sort_order, created_at, updated_at)
             VALUES (?1, ?2, ?3, 0, NULL, ?4, ?5, ?5)",
            params![id, input.title.trim(), input.day, next_order, timestamp],
        )?;
        self.task_by_id(&id)?.ok_or(AppError::NotFound)
    }

    pub fn update_task(&mut self, input: UpdateTaskInput) -> AppResult<DailyTask> {
        let existing = self.task_by_id(&input.id)?.ok_or(AppError::NotFound)?;
        let title = input.title.unwrap_or(existing.title);
        validate_title(&title)?;
        let completed = input.completed.unwrap_or(existing.completed);
        let completed_at = if completed { Some(now()) } else { None };
        self.connection.execute(
            "UPDATE daily_tasks SET title = ?1, completed = ?2, completed_at = ?3, updated_at = ?4 WHERE id = ?5",
            params![title.trim(), completed as i64, completed_at, now(), input.id],
        )?;
        self.task_by_id(&input.id)?.ok_or(AppError::NotFound)
    }

    pub fn delete_task(&mut self, id: &str) -> AppResult<()> {
        if self
            .connection
            .execute("DELETE FROM daily_tasks WHERE id = ?1", params![id])?
            == 1
        {
            Ok(())
        } else {
            Err(AppError::NotFound)
        }
    }

    pub fn tasks_for_day(&self, day: &str) -> AppResult<Vec<DailyTask>> {
        validate_day(day)?;
        let mut statement = self.connection.prepare(
            "SELECT id, title, day, completed, completed_at, sort_order, created_at, updated_at
             FROM daily_tasks WHERE day = ?1 ORDER BY completed ASC, sort_order ASC, created_at ASC",
        )?;
        let rows = statement.query_map(params![day], task_from_row)?;
        collect(rows)
    }

    pub fn apply_proposal(&mut self, proposal: &PlannerResponse) -> AppResult<Vec<ScheduleEvent>> {
        let PlannerResponse::Proposal { operations, .. } = proposal else {
            return Err(AppError::Validation(
                "Clarifications cannot be applied as schedule changes.".into(),
            ));
        };
        validate_operations(operations)?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut affected_ids = Vec::new();
        for operation in operations {
            match operation {
                MutationOperation::CreateEvent {
                    title,
                    notes,
                    start_at_utc,
                    time_zone,
                    duration_minutes,
                } => {
                    let event = insert_event(
                        &transaction,
                        PreparedEvent::from_parts(
                            title,
                            notes,
                            start_at_utc,
                            time_zone,
                            *duration_minutes,
                        )?,
                    )?;
                    affected_ids.push(event.id);
                }
                MutationOperation::UpdateEvent {
                    event_id,
                    expected_revision,
                    title,
                    notes,
                    duration_minutes,
                } => {
                    let current = event_by_id(&transaction, event_id)?.ok_or(AppError::NotFound)?;
                    if current.revision != *expected_revision {
                        return Err(AppError::Conflict);
                    }
                    let next_title = title.as_deref().unwrap_or(&current.title);
                    let next_notes = notes.as_deref().unwrap_or(&current.notes);
                    let next_duration = duration_minutes.unwrap_or(current.duration_minutes);
                    validate_title(next_title)?;
                    validate_duration(next_duration)?;
                    let count = transaction.execute(
                        "UPDATE schedule_events SET title=?1, notes=?2, duration_minutes=?3, revision=revision+1, updated_at=?4
                         WHERE id=?5 AND revision=?6",
                        params![next_title.trim(), next_notes.trim(), next_duration, now(), event_id, expected_revision],
                    )?;
                    if count != 1 {
                        return Err(AppError::Conflict);
                    }
                    affected_ids.push(event_id.clone());
                }
                MutationOperation::DeleteEvent {
                    event_id,
                    expected_revision,
                } => {
                    let count = transaction.execute(
                        "DELETE FROM schedule_events WHERE id=?1 AND revision=?2",
                        params![event_id, expected_revision],
                    )?;
                    if count != 1 {
                        return Err(AppError::Conflict);
                    }
                }
                MutationOperation::RescheduleEvent {
                    event_id,
                    expected_revision,
                    start_at_utc,
                    time_zone,
                    duration_minutes,
                } => {
                    let current = event_by_id(&transaction, event_id)?.ok_or(AppError::NotFound)?;
                    if current.revision != *expected_revision {
                        return Err(AppError::Conflict);
                    }
                    let (start, zone) = validate_time(start_at_utc, time_zone)?;
                    let next_duration = duration_minutes.unwrap_or(current.duration_minutes);
                    validate_duration(next_duration)?;
                    let count = transaction.execute(
                        "UPDATE schedule_events SET start_at_utc=?1, time_zone=?2, duration_minutes=?3, revision=revision+1, updated_at=?4
                         WHERE id=?5 AND revision=?6",
                        params![start, zone, next_duration, now(), event_id, expected_revision],
                    )?;
                    if count != 1 {
                        return Err(AppError::Conflict);
                    }
                    affected_ids.push(event_id.clone());
                }
            }
        }
        transaction.commit()?;
        affected_ids
            .iter()
            .map(|id| self.event_by_id(id)?.ok_or(AppError::NotFound))
            .collect()
    }

    fn event_by_id(&self, id: &str) -> AppResult<Option<ScheduleEvent>> {
        event_by_id(&self.connection, id)
    }

    fn task_by_id(&self, id: &str) -> AppResult<Option<DailyTask>> {
        self.connection
            .query_row(
                "SELECT id, title, day, completed, completed_at, sort_order, created_at, updated_at FROM daily_tasks WHERE id = ?1",
                params![id],
                task_from_row,
            )
            .optional()
            .map_err(AppError::from)
    }
}

struct PreparedEvent {
    title: String,
    notes: String,
    start_at_utc: String,
    time_zone: String,
    duration_minutes: i64,
}

impl PreparedEvent {
    fn from_input(input: CreateEventInput) -> AppResult<Self> {
        Self::from_parts(
            &input.title,
            &input.notes,
            &input.start_at_utc,
            &input.time_zone,
            input.duration_minutes,
        )
    }

    fn from_parts(
        title: &str,
        notes: &str,
        start_at_utc: &str,
        time_zone: &str,
        duration_minutes: i64,
    ) -> AppResult<Self> {
        validate_title(title)?;
        validate_notes(notes)?;
        let (start_at_utc, time_zone) = validate_time(start_at_utc, time_zone)?;
        validate_duration(duration_minutes)?;
        Ok(Self {
            title: title.trim().to_string(),
            notes: notes.trim().to_string(),
            start_at_utc,
            time_zone,
            duration_minutes,
        })
    }
}

trait SqlConnection {
    fn connection(&self) -> &Connection;
}

impl SqlConnection for Connection {
    fn connection(&self) -> &Connection {
        self
    }
}

impl SqlConnection for Transaction<'_> {
    fn connection(&self) -> &Connection {
        self
    }
}

fn insert_event<C: SqlConnection>(
    connection: &C,
    input: PreparedEvent,
) -> AppResult<ScheduleEvent> {
    let id = Uuid::new_v4().to_string();
    let timestamp = now();
    connection.connection().execute(
        "INSERT INTO schedule_events (id, title, notes, start_at_utc, time_zone, duration_minutes, revision, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, ?7, ?7)",
        params![id, input.title, input.notes, input.start_at_utc, input.time_zone, input.duration_minutes, timestamp],
    )?;
    event_by_id(connection, &id)?.ok_or(AppError::NotFound)
}

fn event_by_id<C: SqlConnection>(connection: &C, id: &str) -> AppResult<Option<ScheduleEvent>> {
    connection
        .connection()
        .query_row(
            "SELECT id, title, notes, start_at_utc, time_zone, duration_minutes, revision, created_at, updated_at
             FROM schedule_events WHERE id = ?1",
            params![id],
            event_from_row,
        )
        .optional()
        .map_err(AppError::from)
}

fn event_from_row(row: &Row<'_>) -> rusqlite::Result<ScheduleEvent> {
    Ok(ScheduleEvent {
        id: row.get(0)?,
        title: row.get(1)?,
        notes: row.get(2)?,
        start_at_utc: row.get(3)?,
        time_zone: row.get(4)?,
        duration_minutes: row.get(5)?,
        revision: row.get(6)?,
        created_at: row.get(7)?,
        updated_at: row.get(8)?,
    })
}

fn task_from_row(row: &Row<'_>) -> rusqlite::Result<DailyTask> {
    Ok(DailyTask {
        id: row.get(0)?,
        title: row.get(1)?,
        day: row.get(2)?,
        completed: row.get::<_, i64>(3)? != 0,
        completed_at: row.get(4)?,
        sort_order: row.get(5)?,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
    })
}

fn collect<T>(
    rows: rusqlite::MappedRows<'_, impl FnMut(&Row<'_>) -> rusqlite::Result<T>>,
) -> AppResult<Vec<T>> {
    rows.collect::<Result<Vec<_>, _>>().map_err(AppError::from)
}

fn day_bounds(day: &str, time_zone: &str) -> AppResult<(String, String)> {
    let date = parse_day(day)?;
    let next_day = date
        .succ_opt()
        .ok_or_else(|| AppError::Validation("That date is out of range.".into()))?;
    let zone = parse_time_zone(time_zone)?;
    let start = zone
        .from_local_datetime(&date.and_hms_opt(0, 0, 0).unwrap())
        .earliest()
        .ok_or_else(|| {
            AppError::Validation("That day has no local midnight in this time zone.".into())
        })?;
    let end = zone
        .from_local_datetime(&next_day.and_hms_opt(0, 0, 0).unwrap())
        .earliest()
        .ok_or_else(|| {
            AppError::Validation("That day has no local midnight in this time zone.".into())
        })?;
    Ok((
        utc_string(start.with_timezone(&Utc)),
        utc_string(end.with_timezone(&Utc)),
    ))
}

fn validate_operations(operations: &[MutationOperation]) -> AppResult<()> {
    if operations.is_empty() || operations.len() > MAX_OPERATIONS {
        return Err(AppError::Validation(
            "A schedule proposal must contain between 1 and 12 operations.".into(),
        ));
    }
    for operation in operations {
        match operation {
            MutationOperation::CreateEvent {
                title,
                notes,
                start_at_utc,
                time_zone,
                duration_minutes,
            } => {
                PreparedEvent::from_parts(
                    title,
                    notes,
                    start_at_utc,
                    time_zone,
                    *duration_minutes,
                )?;
            }
            MutationOperation::UpdateEvent {
                event_id,
                expected_revision,
                title,
                notes,
                duration_minutes,
            } => {
                validate_id(event_id)?;
                validate_revision(*expected_revision)?;
                if let Some(title) = title {
                    validate_title(title)?;
                }
                if let Some(notes) = notes {
                    validate_notes(notes)?;
                }
                if let Some(duration) = duration_minutes {
                    validate_duration(*duration)?;
                }
                if title.is_none() && notes.is_none() && duration_minutes.is_none() {
                    return Err(AppError::Validation(
                        "An event update must change at least one permitted field.".into(),
                    ));
                }
            }
            MutationOperation::DeleteEvent {
                event_id,
                expected_revision,
            } => {
                validate_id(event_id)?;
                validate_revision(*expected_revision)?;
            }
            MutationOperation::RescheduleEvent {
                event_id,
                expected_revision,
                start_at_utc,
                time_zone,
                duration_minutes,
            } => {
                validate_id(event_id)?;
                validate_revision(*expected_revision)?;
                validate_time(start_at_utc, time_zone)?;
                if let Some(duration) = duration_minutes {
                    validate_duration(*duration)?;
                }
            }
        }
    }
    Ok(())
}

pub fn validate_model_response(response: &PlannerResponse) -> AppResult<()> {
    match response {
        PlannerResponse::Proposal {
            summary,
            operations,
        } => {
            if summary.trim().is_empty() || summary.chars().count() > 280 {
                return Err(AppError::Validation(
                    "A proposal needs a short summary.".into(),
                ));
            }
            validate_operations(operations)
        }
        PlannerResponse::Clarification { question }
            if question.trim().is_empty() || question.chars().count() > 280 =>
        {
            Err(AppError::Validation(
                "A clarification needs one short question.".into(),
            ))
        }
        PlannerResponse::Clarification { .. } => Ok(()),
    }
}

pub fn validate_title(value: &str) -> AppResult<()> {
    let length = value.trim().chars().count();
    if !(1..=MAX_TITLE_LENGTH).contains(&length) {
        return Err(AppError::Validation(
            "Event and task titles must be 1–140 characters.".into(),
        ));
    }
    Ok(())
}

pub fn validate_notes(value: &str) -> AppResult<()> {
    if value.trim().chars().count() > MAX_NOTES_LENGTH {
        return Err(AppError::Validation(
            "Event notes must be 800 characters or fewer.".into(),
        ));
    }
    Ok(())
}

fn validate_duration(value: i64) -> AppResult<()> {
    if !(5..=1440).contains(&value) {
        return Err(AppError::Validation(
            "Event duration must be between 5 and 1,440 minutes.".into(),
        ));
    }
    Ok(())
}

fn validate_id(id: &str) -> AppResult<()> {
    Uuid::parse_str(id)
        .map(|_| ())
        .map_err(|_| AppError::Validation("An operation used an invalid event identifier.".into()))
}

fn validate_revision(value: i64) -> AppResult<()> {
    if value > 0 {
        Ok(())
    } else {
        Err(AppError::Validation(
            "An operation used an invalid event revision.".into(),
        ))
    }
}

fn validate_day(day: &str) -> AppResult<()> {
    parse_day(day).map(|_| ())
}

fn parse_day(day: &str) -> AppResult<NaiveDate> {
    NaiveDate::parse_from_str(day, "%Y-%m-%d")
        .map_err(|_| AppError::Validation("Dates must use YYYY-MM-DD.".into()))
}

fn parse_time_zone(time_zone: &str) -> AppResult<Tz> {
    time_zone
        .parse::<Tz>()
        .map_err(|_| AppError::Validation("A valid IANA time zone is required.".into()))
}

fn validate_time(start_at_utc: &str, time_zone: &str) -> AppResult<(String, String)> {
    let parsed = DateTime::parse_from_rfc3339(start_at_utc).map_err(|_| {
        AppError::Validation("Event start times must be ISO-8601 UTC timestamps.".into())
    })?;
    if parsed.offset().local_minus_utc() != 0 {
        return Err(AppError::Validation(
            "Event start times must be expressed in UTC (Z).".into(),
        ));
    }
    let zone = parse_time_zone(time_zone)?;
    Ok((
        utc_string(parsed.with_timezone(&Utc)),
        zone.name().to_string(),
    ))
}

fn utc_string(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
fn now() -> String {
    utc_string(Utc::now())
}

fn schema_version(connection: &Connection) -> AppResult<u32> {
    connection
        .query_row("PRAGMA user_version", [], |row| row.get::<_, u32>(0))
        .map_err(AppError::from)
}

fn migrate(connection: &Connection, from_version: u32) -> AppResult<()> {
    connection.execute_batch("BEGIN IMMEDIATE")?;
    let result = (|| {
        if from_version == 0 {
            PlannerDatabase::create_latest_schema(connection)?;
            connection.pragma_update(None, "user_version", CURRENT_SCHEMA_VERSION)?;
        }
        Ok::<(), AppError>(())
    })();
    match result {
        Ok(()) => {
            connection.execute_batch("COMMIT")?;
            Ok(())
        }
        Err(error) => {
            let _ = connection.execute_batch("ROLLBACK");
            Err(error)
        }
    }
}

fn verify_integrity(connection: &Connection) -> AppResult<()> {
    let result: String = connection.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
    if result.eq_ignore_ascii_case("ok") {
        Ok(())
    } else {
        Err(AppError::CorruptDatabase)
    }
}

fn backup_directory(path: &Path) -> AppResult<PathBuf> {
    let parent = path
        .parent()
        .ok_or_else(|| AppError::Validation("The database path has no parent directory.".into()))?;
    let directory = parent.join("backups");
    fs::create_dir_all(&directory)?;
    Ok(directory)
}

fn create_backup_file(path: &Path, schema: u32, reason: &str) -> AppResult<BackupInfo> {
    if !path.exists() {
        return Err(AppError::NotFound);
    }
    let safe_reason = reason
        .chars()
        .filter(|character| character.is_ascii_alphanumeric() || *character == '-')
        .take(24)
        .collect::<String>();
    let timestamp = Utc::now().format("%Y%m%dT%H%M%SZ");
    let name = format!("dayplan-v{schema}-{timestamp}-{safe_reason}.sqlite3");
    let destination = backup_directory(path)?.join(&name);
    fs::copy(path, &destination)?;
    prune_backups(path)?;
    let metadata = destination.metadata()?;
    Ok(BackupInfo {
        name,
        created_at: utc_string(DateTime::<Utc>::from(metadata.modified()?)),
        size_bytes: metadata.len(),
    })
}

fn list_backup_files(path: &Path) -> AppResult<Vec<BackupInfo>> {
    let directory = backup_directory(path)?;
    let mut backups = fs::read_dir(directory)?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.starts_with("dayplan-v") || !name.ends_with(".sqlite3") {
                return None;
            }
            let metadata = entry.metadata().ok()?;
            Some(BackupInfo {
                name,
                created_at: utc_string(DateTime::<Utc>::from(metadata.modified().ok()?)),
                size_bytes: metadata.len(),
            })
        })
        .collect::<Vec<_>>();
    backups.sort_by(|left, right| right.created_at.cmp(&left.created_at));
    Ok(backups)
}

pub fn backups_for_path(path: &Path) -> AppResult<Vec<BackupInfo>> {
    list_backup_files(path)
}

fn prune_backups(path: &Path) -> AppResult<()> {
    let directory = backup_directory(path)?;
    for backup in list_backup_files(path)?.into_iter().skip(BACKUP_RETENTION) {
        let backup_path = directory.join(backup.name);
        if backup_path.is_file() {
            fs::remove_file(backup_path)?;
        }
    }
    Ok(())
}

pub fn restore_backup(path: &Path, backup_name: &str) -> AppResult<()> {
    let backup = list_backup_files(path)?
        .into_iter()
        .find(|backup| backup.name == backup_name)
        .ok_or(AppError::BackupNotFound)?;
    let source = backup_directory(path)?.join(backup.name);
    let temporary = path.with_extension("restore.sqlite3");
    fs::copy(source, &temporary)?;
    let candidate = Connection::open(&temporary)?;
    verify_integrity(&candidate)?;
    drop(candidate);

    let displaced = path.with_extension("before-restore.sqlite3");
    if displaced.exists() {
        fs::remove_file(&displaced)?;
    }
    fs::rename(path, &displaced)?;
    if let Err(error) = fs::rename(&temporary, path) {
        let _ = fs::rename(&displaced, path);
        return Err(AppError::Io(error));
    }
    if displaced.exists() {
        fs::remove_file(displaced)?;
    }
    for suffix in ["sqlite3-wal", "sqlite3-shm"] {
        let sidecar = path.with_extension(suffix);
        if sidecar.exists() {
            fs::remove_file(sidecar)?;
        }
    }
    Ok(())
}

fn validate_export_bundle(bundle: &ExportBundle) -> AppResult<()> {
    if bundle.format_version != EXPORT_FORMAT_VERSION {
        return Err(AppError::Validation(format!(
            "Unsupported DayPlan export format {}.",
            bundle.format_version
        )));
    }
    if bundle.events.len() > 100_000 || bundle.tasks.len() > 100_000 {
        return Err(AppError::Validation(
            "That export contains too many records.".into(),
        ));
    }
    validate_timestamp(&bundle.exported_at)?;
    let mut event_ids = HashSet::new();
    for event in &bundle.events {
        validate_id(&event.id)?;
        if !event_ids.insert(&event.id) {
            return Err(AppError::Validation(
                "The export contains duplicate event identifiers.".into(),
            ));
        }
        validate_title(&event.title)?;
        validate_notes(&event.notes)?;
        validate_time(&event.start_at_utc, &event.time_zone)?;
        validate_duration(event.duration_minutes)?;
        validate_revision(event.revision)?;
        validate_timestamp(&event.created_at)?;
        validate_timestamp(&event.updated_at)?;
    }
    let mut task_ids = HashSet::new();
    for task in &bundle.tasks {
        validate_id(&task.id)?;
        if !task_ids.insert(&task.id) {
            return Err(AppError::Validation(
                "The export contains duplicate task identifiers.".into(),
            ));
        }
        validate_title(&task.title)?;
        validate_day(&task.day)?;
        if task.sort_order < 0 {
            return Err(AppError::Validation(
                "Task ordering values cannot be negative.".into(),
            ));
        }
        if task.completed != task.completed_at.is_some() {
            return Err(AppError::Validation(
                "A task completion timestamp does not match its completion state.".into(),
            ));
        }
        if let Some(completed_at) = &task.completed_at {
            validate_timestamp(completed_at)?;
        }
        validate_timestamp(&task.created_at)?;
        validate_timestamp(&task.updated_at)?;
    }
    Ok(())
}

fn validate_timestamp(value: &str) -> AppResult<()> {
    let parsed = DateTime::parse_from_rfc3339(value)
        .map_err(|_| AppError::Validation("Imported timestamps must use ISO-8601.".into()))?;
    if parsed.offset().local_minus_utc() != 0 {
        return Err(AppError::Validation(
            "Imported timestamps must be expressed in UTC (Z).".into(),
        ));
    }
    Ok(())
}

fn search_tokens(command: &str) -> Vec<String> {
    const IGNORED: &[&str] = &[
        "add",
        "after",
        "at",
        "back",
        "cancel",
        "change",
        "delete",
        "event",
        "for",
        "later",
        "make",
        "move",
        "next",
        "on",
        "reschedule",
        "shift",
        "the",
        "to",
        "today",
        "tomorrow",
        "update",
    ];
    command
        .to_ascii_lowercase()
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|token| token.len() >= 2 && !IGNORED.contains(token))
        .map(str::to_string)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::MutationOperation;
    use tempfile::tempdir;

    fn database() -> PlannerDatabase {
        let directory = tempdir().unwrap();
        let path = directory.keep().join("dayplan.sqlite3");
        PlannerDatabase::open(&path).unwrap()
    }

    fn event_input(title: &str, start: &str) -> CreateEventInput {
        CreateEventInput {
            title: title.into(),
            notes: String::new(),
            start_at_utc: start.into(),
            time_zone: "America/New_York".into(),
            duration_minutes: 60,
        }
    }

    #[test]
    fn rejects_non_utc_event_times() {
        let mut db = database();
        let result = db.create_event(event_input("Gym", "2026-08-12T10:00:00-04:00"));
        assert!(matches!(result, Err(AppError::Validation(_))));
    }

    #[test]
    fn daylight_saving_day_queries_the_right_window() {
        let mut db = database();
        db.create_event(event_input("Breakfast", "2026-03-08T05:30:00Z"))
            .unwrap();
        let events = db.events_for_day("2026-03-08", "America/New_York").unwrap();
        assert_eq!(events.len(), 1);
    }

    #[test]
    fn stale_proposal_rolls_back_everything() {
        let mut db = database();
        let existing = db
            .create_event(event_input("Gym", "2026-08-12T22:00:00Z"))
            .unwrap();
        let proposal = PlannerResponse::proposal(
            "Two changes",
            vec![
                MutationOperation::CreateEvent {
                    title: "Dentist".into(),
                    notes: String::new(),
                    start_at_utc: "2026-08-13T18:00:00Z".into(),
                    time_zone: "America/New_York".into(),
                    duration_minutes: 60,
                },
                MutationOperation::RescheduleEvent {
                    event_id: existing.id,
                    expected_revision: 99,
                    start_at_utc: "2026-08-13T22:00:00Z".into(),
                    time_zone: "America/New_York".into(),
                    duration_minutes: None,
                },
            ],
        );
        assert!(matches!(
            db.apply_proposal(&proposal),
            Err(AppError::Conflict)
        ));
        assert!(db
            .events_for_day("2026-08-13", "America/New_York")
            .unwrap()
            .is_empty());
    }

    #[test]
    fn migrates_a_legacy_database_and_keeps_a_backup() {
        let directory = tempdir().unwrap().keep();
        let path = directory.join("dayplan.sqlite3");
        let database = PlannerDatabase::open(&path).unwrap();
        database
            .connection
            .pragma_update(None, "user_version", 0)
            .unwrap();
        drop(database);

        let migrated = PlannerDatabase::open(&path).unwrap();
        assert_eq!(migrated.schema_version().unwrap(), CURRENT_SCHEMA_VERSION);
        assert_eq!(migrated.list_backups().unwrap().len(), 1);
    }

    #[test]
    fn import_replaces_data_only_after_full_validation() {
        let mut database = database();
        database
            .create_event(event_input("Original", "2026-08-12T14:00:00Z"))
            .unwrap();
        let mut invalid = database.export_bundle().unwrap();
        invalid.events[0].id = "not-a-uuid".into();
        assert!(matches!(
            database.import_bundle(&invalid),
            Err(AppError::Validation(_))
        ));
        assert_eq!(
            database
                .events_for_day("2026-08-12", "America/New_York")
                .unwrap()[0]
                .title,
            "Original"
        );
        assert!(database.list_backups().unwrap().is_empty());
    }

    #[test]
    fn an_event_edit_updates_every_field_with_one_revision() {
        let mut database = database();
        let original = database
            .create_event(event_input("Gym", "2026-08-12T22:00:00Z"))
            .unwrap();
        let updated = database
            .update_event(UpdateEventInput {
                id: original.id,
                revision: original.revision,
                title: Some("Evening gym".into()),
                notes: Some("Bring water".into()),
                start_at_utc: Some("2026-08-13T23:00:00Z".into()),
                time_zone: Some("America/Chicago".into()),
                duration_minutes: Some(75),
            })
            .unwrap();
        assert_eq!(updated.revision, 2);
        assert_eq!(updated.title, "Evening gym");
        assert_eq!(updated.start_at_utc, "2026-08-13T23:00:00.000Z");
        assert_eq!(updated.time_zone, "America/Chicago");
        assert_eq!(updated.duration_minutes, 75);
    }

    #[test]
    fn agenda_includes_an_event_that_overlaps_midnight() {
        let mut database = database();
        database
            .create_event(CreateEventInput {
                title: "Overnight flight".into(),
                notes: String::new(),
                start_at_utc: "2026-08-13T03:30:00Z".into(),
                time_zone: "America/New_York".into(),
                duration_minutes: 180,
            })
            .unwrap();
        assert_eq!(
            database
                .events_for_day("2026-08-13", "America/New_York")
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn daylight_saving_overlap_returns_both_clock_occurrences() {
        let result = PlannerDatabase::resolve_local_datetime(&LocalDateTimeInput {
            day: "2026-11-01".into(),
            time: "01:30".into(),
            time_zone: "America/New_York".into(),
        })
        .unwrap();
        assert!(matches!(
            result,
            LocalDateTimeResolution::Ambiguous { options } if options.len() == 2
        ));
    }

    #[test]
    fn daylight_saving_gap_is_never_silently_normalized() {
        let result = PlannerDatabase::resolve_local_datetime(&LocalDateTimeInput {
            day: "2026-03-08".into(),
            time: "02:30".into(),
            time_zone: "America/New_York".into(),
        })
        .unwrap();
        assert!(matches!(
            result,
            LocalDateTimeResolution::Nonexistent { .. }
        ));
    }
}
