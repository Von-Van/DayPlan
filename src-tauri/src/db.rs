use crate::error::{AppError, AppResult};
use crate::model::{
    CreateEventInput, CreateTaskInput, DailyTask, MutationOperation, PlannerResponse,
    RescheduleEventInput, ScheduleEvent, UpdateEventInput, UpdateTaskInput,
};
use chrono::{DateTime, NaiveDate, TimeZone, Utc};
use chrono_tz::Tz;
use rusqlite::{params, Connection, OptionalExtension, Row, Transaction, TransactionBehavior};
use uuid::Uuid;

pub struct PlannerDatabase {
    connection: Connection,
}

impl PlannerDatabase {
    pub fn open(path: &std::path::Path) -> AppResult<Self> {
        let connection = Connection::open(path)?;
        connection.execute_batch(
            "PRAGMA foreign_keys = ON;
             PRAGMA journal_mode = WAL;
             CREATE TABLE IF NOT EXISTS schedule_events (
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
        Ok(Self { connection })
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
        let duration_minutes = input.duration_minutes.unwrap_or(existing.duration_minutes);
        validate_title(&title)?;
        validate_duration(duration_minutes)?;
        let now = now();
        let changed = self.connection.execute(
            "UPDATE schedule_events
             SET title = ?1, notes = ?2, duration_minutes = ?3, revision = revision + 1, updated_at = ?4
             WHERE id = ?5 AND revision = ?6",
            params![title.trim(), notes.trim(), duration_minutes, now, input.id, input.revision],
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
             WHERE start_at_utc >= ?1 AND start_at_utc < ?2
             ORDER BY start_at_utc ASC, created_at ASC",
        )?;
        let rows = statement.query_map(params![start, end], event_from_row)?;
        collect(rows)
    }

    pub fn candidate_events(&self, limit: usize) -> AppResult<Vec<ScheduleEvent>> {
        let mut statement = self.connection.prepare(
            "SELECT id, title, notes, start_at_utc, time_zone, duration_minutes, revision, created_at, updated_at
             FROM schedule_events ORDER BY start_at_utc ASC, created_at ASC LIMIT ?1",
        )?;
        let rows = statement.query_map(params![limit as i64], event_from_row)?;
        collect(rows)
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
    if operations.is_empty() || operations.len() > 12 {
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
    if !(1..=140).contains(&length) {
        return Err(AppError::Validation(
            "Event and task titles must be 1–140 characters.".into(),
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
}
