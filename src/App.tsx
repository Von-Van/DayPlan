import {
  FormEvent,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  isPermissionGranted,
  requestPermission,
} from "@tauri-apps/plugin-notification";
import {
  ArrowLeft,
  ArrowRight,
  Bell,
  Bot,
  CalendarDays,
  Check,
  ChevronDown,
  CirclePlus,
  Clock3,
  Command,
  ExternalLink,
  LoaderCircle,
  MoreHorizontal,
  Plus,
  RotateCcw,
  Sparkles,
  Settings2,
  Trash2,
  TriangleAlert,
  X,
} from "lucide-react";
import {
  api,
  DailyTask,
  LocalDateTimeResolution,
  OllamaStatus,
  PlannerResponse,
  ReminderChange,
  ScheduleEvent,
} from "./api";
import {
  dateTimeFields,
  dayLabel,
  dayShort,
  localTimeZone,
  offsetDay,
  timeLabel,
  todayDay,
} from "./date";
import { Onboarding } from "./Onboarding";
import { SettingsModal } from "./SettingsModal";

type DraftEvent = {
  title: string;
  notes: string;
  day: string;
  time: string;
  durationMinutes: number;
  reminderMinutesBefore: number | null;
};

const defaultAgenda = {
  events: [] as ScheduleEvent[],
  tasks: [] as DailyTask[],
};

function draftFor(day: string, event?: ScheduleEvent): DraftEvent {
  if (!event)
    return {
      title: "",
      notes: "",
      day,
      time: "09:00",
      durationMinutes: 60,
      reminderMinutesBefore: null,
    };
  const fields = dateTimeFields(event.startAtUtc);
  return {
    title: event.title,
    notes: event.notes,
    day: fields.day,
    time: fields.time,
    durationMinutes: event.durationMinutes,
    reminderMinutesBefore: event.reminderMinutesBefore,
  };
}

const reminderPresets = [
  { value: "", label: "No reminder" },
  { value: "0", label: "At start time" },
  { value: "5", label: "5 minutes before" },
  { value: "10", label: "10 minutes before" },
  { value: "15", label: "15 minutes before" },
  { value: "30", label: "30 minutes before" },
  { value: "60", label: "1 hour before" },
  { value: "1440", label: "1 day before" },
];

export default function App() {
  const [day, setDay] = useState(todayDay());
  const [agenda, setAgenda] = useState(defaultAgenda);
  const [status, setStatus] = useState<OllamaStatus | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editor, setEditor] = useState<ScheduleEvent | "new" | null>(null);
  const [taskTitle, setTaskTitle] = useState("");
  const [command, setCommand] = useState("");
  const [agentResponse, setAgentResponse] = useState<PlannerResponse | null>(
    null,
  );
  const [isThinking, setIsThinking] = useState(false);
  const [isApplying, setIsApplying] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [onboardingOpen, setOnboardingOpen] = useState(
    () => localStorage.getItem("dayplan-onboarding") !== "complete",
  );

  const refresh = useCallback(async () => {
    setIsLoading(true);
    try {
      setAgenda(await api.listAgenda(day, localTimeZone));
    } catch (cause) {
      setError(messageFor(cause));
    } finally {
      setIsLoading(false);
    }
  }, [day]);

  const refreshStatus = useCallback(async () => {
    try {
      setStatus(await api.status());
    } catch (cause) {
      setError(messageFor(cause));
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);
  useEffect(() => {
    void refreshStatus();
  }, [refreshStatus]);

  async function saveEvent(
    draft: DraftEvent,
    event: ScheduleEvent | undefined,
    startAtUtc: string,
  ) {
    try {
      if (draft.reminderMinutesBefore !== null)
        await ensureNotificationPermission();
      if (!event) {
        await api.createEvent({
          title: draft.title,
          notes: draft.notes,
          startAtUtc,
          timeZone: localTimeZone,
          durationMinutes: draft.durationMinutes,
          reminderMinutesBefore: draft.reminderMinutesBefore,
        });
      } else {
        await api.updateEvent({
          id: event.id,
          revision: event.revision,
          title: draft.title,
          notes: draft.notes,
          startAtUtc,
          timeZone: localTimeZone,
          durationMinutes: draft.durationMinutes,
          reminderChange: reminderChangeFor(
            event.reminderMinutesBefore,
            draft.reminderMinutesBefore,
          ),
        });
      }
      setEditor(null);
      await refresh();
    } catch (cause) {
      setError(messageFor(cause));
    }
  }

  async function removeEvent(event: ScheduleEvent) {
    if (!window.confirm(`Delete “${event.title}”?`)) return;
    try {
      await api.deleteEvent(event.id, event.revision);
      await refresh();
    } catch (cause) {
      setError(messageFor(cause));
    }
  }

  async function addTask(submit: FormEvent) {
    submit.preventDefault();
    const title = taskTitle.trim();
    if (!title) return;
    try {
      await api.createTask({ title, day });
      setTaskTitle("");
      await refresh();
    } catch (cause) {
      setError(messageFor(cause));
    }
  }

  async function toggleTask(task: DailyTask) {
    try {
      await api.updateTask({ id: task.id, completed: !task.completed });
      await refresh();
    } catch (cause) {
      setError(messageFor(cause));
    }
  }

  async function removeTask(task: DailyTask) {
    try {
      await api.deleteTask(task.id);
      await refresh();
    } catch (cause) {
      setError(messageFor(cause));
    }
  }

  async function askPlanner(submit: FormEvent) {
    submit.preventDefault();
    if (!command.trim() || isThinking) return;
    setIsThinking(true);
    setAgentResponse(null);
    try {
      setAgentResponse(await api.propose(command, day, localTimeZone));
    } catch (cause) {
      setError(messageFor(cause));
    } finally {
      setIsThinking(false);
    }
  }

  async function applyProposal() {
    if (!agentResponse || agentResponse.kind !== "proposal") return;
    setIsApplying(true);
    try {
      if (proposalEnablesReminder(agentResponse))
        await ensureNotificationPermission();
      await api.apply(agentResponse.proposalId);
      setAgentResponse(null);
      setCommand("");
      await refresh();
    } catch (cause) {
      setError(messageFor(cause));
    } finally {
      setIsApplying(false);
    }
  }

  async function discardProposal() {
    if (!agentResponse || agentResponse.kind !== "proposal") return;
    try {
      await api.discardProposal(agentResponse.proposalId);
      setAgentResponse(null);
    } catch (cause) {
      setError(messageFor(cause));
    }
  }

  async function clearContext() {
    try {
      await api.clearContext();
      setAgentResponse(null);
      setCommand("");
    } catch (cause) {
      setError(messageFor(cause));
    }
  }

  const visibleDays = useMemo(
    () => Array.from({ length: 7 }, (_, index) => offsetDay(day, index - 3)),
    [day],
  );

  return (
    <main className="app-shell">
      <aside className="rail">
        <div className="brand">
          <span className="brand-mark">D</span>
          <span>DayPlan</span>
        </div>
        <div className="rail-date">
          <span>LOCAL AGENDA</span>
          <strong>{dayShort(day)}</strong>
        </div>
        <nav aria-label="Workspace sections">
          <button className="rail-link active">
            <CalendarDays size={18} /> Agenda
          </button>
          <button className="rail-link" onClick={() => setSettingsOpen(true)}>
            <Settings2 size={18} /> Settings
          </button>
        </nav>
        <section className="privacy-note">
          <span className="privacy-dot" />
          <div>
            <strong>Private by design</strong>
            <p>Your schedule stays on this device.</p>
          </div>
        </section>
        <div className="rail-footer">
          DAYPLAN / DESKTOP
          <br />
          LOCAL-FIRST PLANNER
        </div>
      </aside>

      <section className="workspace">
        <header className="topbar">
          <div className="date-heading">
            <p>YOUR DAY</p>
            <h1>{dayLabel(day)}</h1>
          </div>
          <div className="date-controls">
            <button
              className="icon-button"
              aria-label="Previous day"
              onClick={() => setDay(offsetDay(day, -1))}
            >
              <ArrowLeft size={18} />
            </button>
            <button className="today-button" onClick={() => setDay(todayDay())}>
              Today
            </button>
            <button
              className="icon-button"
              aria-label="Next day"
              onClick={() => setDay(offsetDay(day, 1))}
            >
              <ArrowRight size={18} />
            </button>
            <button
              className="new-event-button"
              onClick={() => setEditor("new")}
            >
              <Plus size={17} /> New event
            </button>
          </div>
        </header>

        <div className="week-strip" aria-label="Date picker">
          {visibleDays.map((candidate) => (
            <button
              key={candidate}
              className={`day-chip ${candidate === day ? "selected" : ""}`}
              onClick={() => setDay(candidate)}
            >
              <span>
                {candidate === todayDay()
                  ? "TODAY"
                  : dayShort(candidate).slice(0, 3).toUpperCase()}
              </span>
              <strong>{candidate.slice(-2)}</strong>
            </button>
          ))}
          <button
            className="calendar-jump"
            title="Jump to today"
            onClick={() => setDay(todayDay())}
          >
            <CalendarDays size={18} />
          </button>
        </div>

        <div className="content-grid">
          <section className="agenda-panel">
            <div className="section-header">
              <div>
                <p>TIME BLOCKS</p>
                <h2>Agenda</h2>
              </div>
              <span>{agenda.events.length} scheduled</span>
            </div>
            {isLoading ? (
              <LoadingLine label="Opening your local schedule" />
            ) : (
              <Agenda
                events={agenda.events}
                onEdit={setEditor}
                onDelete={removeEvent}
                onAdd={() => setEditor("new")}
              />
            )}
            <section className="task-area">
              <div className="section-header">
                <div>
                  <p>LOOSE ENDS</p>
                  <h2>Daily tasks</h2>
                </div>
                <span>
                  {agenda.tasks.filter((task) => task.completed).length}/
                  {agenda.tasks.length}
                </span>
              </div>
              <form className="task-add" onSubmit={addTask}>
                <CirclePlus size={19} />
                <input
                  value={taskTitle}
                  onChange={(event) => setTaskTitle(event.target.value)}
                  placeholder="Add a task for this day"
                  aria-label="Add task"
                />
                <button aria-label="Add task" disabled={!taskTitle.trim()}>
                  <ArrowRight size={16} />
                </button>
              </form>
              <div className="task-list">
                {agenda.tasks.length === 0 ? (
                  <p className="empty-tasks">
                    A clear list leaves room to think.
                  </p>
                ) : (
                  agenda.tasks.map((task) => (
                    <TaskRow
                      key={task.id}
                      task={task}
                      onToggle={() => toggleTask(task)}
                      onDelete={() => removeTask(task)}
                    />
                  ))
                )}
              </div>
            </section>
          </section>

          <aside className="ai-column">
            <PlannerCard
              status={status}
              events={agenda.events}
              command={command}
              onCommand={setCommand}
              onSubmit={askPlanner}
              thinking={isThinking}
              response={agentResponse}
              onApply={applyProposal}
              applying={isApplying}
              onDiscard={discardProposal}
              onClear={clearContext}
              onRefreshStatus={refreshStatus}
            />
            <section className="quiet-card">
              <Clock3 size={18} />
              <div>
                <strong>All times are local</strong>
                <p>
                  {localTimeZone}. Events persist as UTC with their IANA time
                  zone.
                </p>
              </div>
            </section>
          </aside>
        </div>
      </section>

      {editor && (
        <EventEditor
          day={day}
          event={editor === "new" ? undefined : editor}
          onClose={() => setEditor(null)}
          onSave={saveEvent}
        />
      )}
      {settingsOpen && (
        <SettingsModal
          status={status}
          onClose={() => setSettingsOpen(false)}
          onDataChanged={refresh}
          onRefreshStatus={refreshStatus}
          onMessage={setError}
        />
      )}
      {onboardingOpen && (
        <Onboarding
          status={status}
          onRefresh={refreshStatus}
          onComplete={() => setOnboardingOpen(false)}
          onMessage={setError}
        />
      )}
      {error && (
        <div className="toast" role="alert">
          <TriangleAlert size={17} />
          <span>{error}</span>
          <button onClick={() => setError(null)} aria-label="Dismiss message">
            <X size={17} />
          </button>
        </div>
      )}
    </main>
  );
}

function Agenda({
  events,
  onEdit,
  onDelete,
  onAdd,
}: {
  events: ScheduleEvent[];
  onEdit: (event: ScheduleEvent) => void;
  onDelete: (event: ScheduleEvent) => void;
  onAdd: () => void;
}) {
  if (events.length === 0)
    return (
      <div className="empty-agenda">
        <div className="sun-motif" />
        <p>Nothing is carved into this day yet.</p>
        <button onClick={onAdd}>
          <Plus size={16} /> Add the first block
        </button>
      </div>
    );
  return (
    <div className="agenda-list">
      {events.map((event) => (
        <EventRow
          key={event.id}
          event={event}
          onEdit={() => onEdit(event)}
          onDelete={() => onDelete(event)}
        />
      ))}
    </div>
  );
}

function EventRow({
  event,
  onEdit,
  onDelete,
}: {
  event: ScheduleEvent;
  onEdit: () => void;
  onDelete: () => void;
}) {
  return (
    <article className="event-row">
      <time>
        {timeLabel(event.startAtUtc)}
        <span>{event.durationMinutes} min</span>
      </time>
      <div className="event-connector">
        <i />
      </div>
      <button className="event-card" onClick={onEdit}>
        <span className="event-swatch" />
        <span className="event-main">
          <strong>{event.title}</strong>
          {event.notes && <small>{event.notes}</small>}
          {event.reminderMinutesBefore !== null && (
            <small className={`reminder-badge ${event.reminderStatus}`}>
              <Bell size={11} /> {reminderLabel(event.reminderMinutesBefore)} ·{" "}
              {event.reminderStatus.replace("_", " ")}
            </small>
          )}
        </span>
        <ChevronDown size={16} />
      </button>
      <button
        className="event-menu"
        onClick={onDelete}
        aria-label={`Delete ${event.title}`}
      >
        <Trash2 size={15} />
      </button>
    </article>
  );
}

function TaskRow({
  task,
  onToggle,
  onDelete,
}: {
  task: DailyTask;
  onToggle: () => void;
  onDelete: () => void;
}) {
  return (
    <div className={`task-row ${task.completed ? "done" : ""}`}>
      <button
        onClick={onToggle}
        className="check-box"
        aria-label={`Mark ${task.title} ${task.completed ? "incomplete" : "complete"}`}
      >
        {task.completed && <Check size={13} />}
      </button>
      <span>{task.title}</span>
      <button
        className="task-delete"
        onClick={onDelete}
        aria-label={`Delete ${task.title}`}
      >
        <X size={14} />
      </button>
    </div>
  );
}

function PlannerCard({
  status,
  events,
  command,
  onCommand,
  onSubmit,
  thinking,
  response,
  onApply,
  applying,
  onDiscard,
  onClear,
  onRefreshStatus,
}: {
  status: OllamaStatus | null;
  events: ScheduleEvent[];
  command: string;
  onCommand: (value: string) => void;
  onSubmit: (event: FormEvent) => void;
  thinking: boolean;
  response: PlannerResponse | null;
  onApply: () => void;
  applying: boolean;
  onDiscard: () => void;
  onClear: () => void;
  onRefreshStatus: () => void;
}) {
  const ready = status?.running && status.modelInstalled;
  return (
    <section className="planner-card">
      <div className="planner-heading">
        <div className="bot-orb">
          <Bot size={19} />
        </div>
        <div>
          <p>LOCAL PLANNER</p>
          <h2>Say it messily.</h2>
        </div>
        <button
          onClick={onClear}
          title="Clear conversational context"
          className="reset-button"
        >
          <RotateCcw size={15} />
        </button>
      </div>
      <div className={`model-state ${ready ? "ready" : "not-ready"}`}>
        <span />
        <div>
          <strong>
            {ready ? "Local model ready" : "Local model setup needed"}
          </strong>
          <p>{status?.detail ?? "Checking your local model…"}</p>
        </div>
        <button onClick={onRefreshStatus} aria-label="Refresh model status">
          <RotateCcw size={14} />
        </button>
      </div>
      <form onSubmit={onSubmit} className="command-form">
        <textarea
          maxLength={1000}
          value={command}
          onChange={(event) => onCommand(event.target.value)}
          placeholder="“Move gym to 6pm tomorrow, add dentist Thursday…”"
          disabled={!ready || thinking}
        />
        <div>
          <span>
            <Command size={14} /> The model proposes; you decide.
          </span>
          <button disabled={!command.trim() || !ready || thinking}>
            {thinking ? (
              <LoaderCircle className="spin" size={16} />
            ) : (
              <Sparkles size={16} />
            )}{" "}
            Plan changes
          </button>
        </div>
      </form>
      <div aria-live="polite">
        {response?.kind === "clarification" && (
          <div className="clarification">
            <span>?</span>
            <p>{response.question}</p>
          </div>
        )}
        {response?.kind === "proposal" && (
          <div className="proposal">
            <p className="proposal-kicker">REVIEW BEFORE APPLYING</p>
            <strong>{response.summary}</strong>
            <ul>
              {response.operations.map((operation, index) => (
                <li key={`${operation.type}-${index}`}>
                  <i className={`operation-dot ${operation.type}`} />
                  {operationLabel(operation, events)}
                </li>
              ))}
            </ul>
            <div className="proposal-actions">
              <button className="cancel-proposal" onClick={onDiscard}>
                Discard proposal
              </button>
              <button
                className="apply-proposal"
                onClick={onApply}
                disabled={applying}
              >
                {applying ? (
                  <LoaderCircle className="spin" size={15} />
                ) : (
                  <Check size={15} />
                )}{" "}
                Apply {response.operations.length} change
                {response.operations.length === 1 ? "" : "s"}
              </button>
            </div>
          </div>
        )}
      </div>
      <p className="planner-footnote">
        <span>◌</span> No API key. No cloud fallback. Context clears when you
        clear this session.
      </p>
    </section>
  );
}

function EventEditor({
  day,
  event,
  onClose,
  onSave,
}: {
  day: string;
  event?: ScheduleEvent;
  onClose: () => void;
  onSave: (
    draft: DraftEvent,
    event: ScheduleEvent | undefined,
    startAtUtc: string,
  ) => Promise<void>;
}) {
  const [draft, setDraft] = useState(() => draftFor(day, event));
  const dialogRef = useRef<HTMLFormElement>(null);
  const [saving, setSaving] = useState(false);
  const [resolution, setResolution] = useState<LocalDateTimeResolution | null>(
    null,
  );
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    const onKey = (key: KeyboardEvent) => {
      if (key.key === "Escape" && !saving) onClose();
      if (key.key !== "Tab" || !dialogRef.current) return;
      const items = dialogRef.current.querySelectorAll<HTMLElement>(
        'button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex="0"]',
      );
      if (!items.length) return;
      const first = items[0];
      const last = items[items.length - 1];
      if (key.shiftKey && document.activeElement === first) {
        key.preventDefault();
        last.focus();
      } else if (!key.shiftKey && document.activeElement === last) {
        key.preventDefault();
        first.focus();
      }
    };
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      previous?.focus();
    };
  }, [onClose, saving]);
  async function persist(startAtUtc: string) {
    setSaving(true);
    try {
      await onSave(draft, event, startAtUtc);
    } finally {
      setSaving(false);
    }
  }
  async function submit(form: FormEvent) {
    form.preventDefault();
    setSaving(true);
    try {
      const next = await api.resolveLocalDateTime(
        draft.day,
        draft.time,
        localTimeZone,
      );
      setResolution(next);
      if (next.kind === "resolved") await onSave(draft, event, next.startAtUtc);
    } finally {
      setSaving(false);
    }
  }
  const updateDraft = (next: DraftEvent) => {
    setDraft(next);
    setResolution(null);
  };
  return (
    <div
      className="modal-backdrop"
      role="presentation"
      onMouseDown={(click) => {
        if (click.target === click.currentTarget && !saving) onClose();
      }}
    >
      <form
        ref={dialogRef}
        className="event-editor"
        onSubmit={submit}
        role="dialog"
        aria-modal="true"
        aria-label={event ? "Edit event" : "New event"}
      >
        <header>
          <div>
            <p>{event ? "EDIT TIME BLOCK" : "NEW TIME BLOCK"}</p>
            <h2>{event ? "Refine the details" : "Make room for it"}</h2>
          </div>
          <button type="button" onClick={onClose} aria-label="Close editor">
            <X size={19} />
          </button>
        </header>
        <label>
          Title
          <input
            autoFocus
            value={draft.title}
            onChange={(input) =>
              updateDraft({ ...draft, title: input.target.value })
            }
            required
            maxLength={140}
            placeholder="What needs your time?"
          />
        </label>
        <div className="form-pair">
          <label>
            Date
            <input
              type="date"
              value={draft.day}
              onChange={(input) =>
                updateDraft({ ...draft, day: input.target.value })
              }
              required
            />
          </label>
          <label>
            Time
            <input
              type="time"
              value={draft.time}
              onChange={(input) =>
                updateDraft({ ...draft, time: input.target.value })
              }
              required
            />
          </label>
        </div>
        {resolution?.kind === "nonexistent" && (
          <div className="time-resolution" role="alert">
            {resolution.message}
          </div>
        )}
        {resolution?.kind === "ambiguous" && (
          <div className="time-resolution">
            <strong>This time happens twice.</strong>
            <p>Choose which clock occurrence you mean:</p>
            {resolution.options.map((option) => (
              <button
                type="button"
                key={option.startAtUtc}
                onClick={() => void persist(option.startAtUtc)}
              >
                {option.label}
              </button>
            ))}
          </div>
        )}
        <label>
          Duration <span>{draft.durationMinutes} minutes</span>
          <input
            className="range"
            type="range"
            min="5"
            max="240"
            step="5"
            value={draft.durationMinutes}
            onChange={(input) =>
              updateDraft({
                ...draft,
                durationMinutes: Number(input.target.value),
              })
            }
          />
        </label>
        <label>
          Reminder
          <select
            value={draft.reminderMinutesBefore ?? ""}
            onChange={(input) =>
              updateDraft({
                ...draft,
                reminderMinutesBefore:
                  input.target.value === "" ? null : Number(input.target.value),
              })
            }
          >
            {reminderPresets.map((preset) => (
              <option key={preset.value} value={preset.value}>
                {preset.label}
              </option>
            ))}
          </select>
          <span>
            DayPlan must remain running in the tray to deliver desktop
            reminders.
          </span>
        </label>
        <label>
          Notes
          <textarea
            value={draft.notes}
            onChange={(input) =>
              updateDraft({ ...draft, notes: input.target.value })
            }
            placeholder="Optional context for your future self"
            maxLength={800}
          />
        </label>
        <footer>
          <button type="button" className="editor-cancel" onClick={onClose}>
            Cancel
          </button>
          <button
            className="editor-save"
            disabled={saving || !draft.title.trim()}
          >
            {saving && <LoaderCircle className="spin" size={15} />}
            {event ? "Save changes" : "Create event"}
          </button>
        </footer>
      </form>
    </div>
  );
}

function LoadingLine({ label }: { label: string }) {
  return (
    <div className="loading-line">
      <LoaderCircle className="spin" size={18} />
      {label}
    </div>
  );
}

function operationLabel(
  operation: Extract<
    PlannerResponse,
    { kind: "proposal" }
  >["operations"][number],
  events: ScheduleEvent[],
) {
  const eventTitle = (id: string) =>
    events.find((event) => event.id === id)?.title ?? "the selected event";
  switch (operation.type) {
    case "create_event":
      return `Create “${operation.title}” at ${timeLabel(operation.startAtUtc)}${operation.reminderMinutesBefore === null ? "" : ` with ${reminderLabel(operation.reminderMinutesBefore)}`}`;
    case "update_event":
      return `Update “${eventTitle(operation.eventId)}”${operation.reminderChange.action === "set" ? ` with ${reminderLabel(operation.reminderChange.minutesBefore)}` : operation.reminderChange.action === "clear" ? " and clear its reminder" : ""}`;
    case "delete_event":
      return `Delete “${eventTitle(operation.eventId)}”`;
    case "reschedule_event":
      return `Move “${eventTitle(operation.eventId)}” to ${timeLabel(operation.startAtUtc)}${operation.reminderChange.action === "set" ? ` with ${reminderLabel(operation.reminderChange.minutesBefore)}` : operation.reminderChange.action === "clear" ? " and clear its reminder" : ""}`;
  }
}

function reminderChangeFor(
  current: number | null,
  next: number | null,
): ReminderChange {
  if (current === next) return { action: "unchanged" };
  return next === null
    ? { action: "clear" }
    : { action: "set", minutesBefore: next };
}

function proposalEnablesReminder(
  response: Extract<PlannerResponse, { kind: "proposal" }>,
) {
  return response.operations.some((operation) =>
    operation.type === "create_event"
      ? operation.reminderMinutesBefore !== null
      : (operation.type === "update_event" ||
          operation.type === "reschedule_event") &&
        operation.reminderChange.action === "set",
  );
}

async function ensureNotificationPermission() {
  if (await isPermissionGranted()) return;
  const permission = await requestPermission();
  if (permission !== "granted") {
    throw new Error(
      "Notification permission was not granted. No schedule changes were applied.",
    );
  }
}

function reminderLabel(minutes: number) {
  if (minutes === 0) return "reminder at start";
  if (minutes === 1_440) return "reminder 1 day before";
  if (minutes === 60) return "reminder 1 hour before";
  return `reminder ${minutes} minutes before`;
}

function messageFor(cause: unknown) {
  return cause instanceof Error ? cause.message : String(cause);
}
