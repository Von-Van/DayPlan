import { FormEvent, useCallback, useEffect, useMemo, useState } from "react";
import {
  ArrowLeft, ArrowRight, Bot, CalendarDays, Check, ChevronDown, CirclePlus, Clock3,
  Command, ExternalLink, LoaderCircle, MoreHorizontal, Plus, RotateCcw, Sparkles,
  Trash2, TriangleAlert, X
} from "lucide-react";
import { api, DailyTask, OllamaStatus, PlannerResponse, ScheduleEvent } from "./api";
import { dateTimeFields, dayLabel, dayShort, localDateTimeToUtc, localTimeZone, offsetDay, timeLabel, todayDay } from "./date";

type DraftEvent = { title: string; notes: string; day: string; time: string; durationMinutes: number };

const defaultAgenda = { events: [] as ScheduleEvent[], tasks: [] as DailyTask[] };

function draftFor(day: string, event?: ScheduleEvent): DraftEvent {
  if (!event) return { title: "", notes: "", day, time: "09:00", durationMinutes: 60 };
  const fields = dateTimeFields(event.startAtUtc);
  return { title: event.title, notes: event.notes, day: fields.day, time: fields.time, durationMinutes: event.durationMinutes };
}

export default function App() {
  const [day, setDay] = useState(todayDay());
  const [agenda, setAgenda] = useState(defaultAgenda);
  const [status, setStatus] = useState<OllamaStatus | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editor, setEditor] = useState<ScheduleEvent | "new" | null>(null);
  const [taskTitle, setTaskTitle] = useState("");
  const [command, setCommand] = useState("");
  const [agentResponse, setAgentResponse] = useState<PlannerResponse | null>(null);
  const [isThinking, setIsThinking] = useState(false);
  const [isApplying, setIsApplying] = useState(false);

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
    try { setStatus(await api.status()); } catch (cause) { setError(messageFor(cause)); }
  }, []);

  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => { void refreshStatus(); }, [refreshStatus]);

  async function saveEvent(draft: DraftEvent, event?: ScheduleEvent) {
    try {
      const startAtUtc = localDateTimeToUtc(draft.day, draft.time);
      if (!event) {
        await api.createEvent({ title: draft.title, notes: draft.notes, startAtUtc, timeZone: localTimeZone, durationMinutes: draft.durationMinutes });
      } else {
        const renamed = draft.title !== event.title || draft.notes !== event.notes;
        const original = dateTimeFields(event.startAtUtc);
        const timingChanged = original.day !== draft.day || original.time !== draft.time || event.durationMinutes !== draft.durationMinutes;
        let current = event;
        if (renamed) current = await api.updateEvent({ id: current.id, revision: current.revision, title: draft.title, notes: draft.notes, durationMinutes: timingChanged ? event.durationMinutes : draft.durationMinutes });
        if (timingChanged) await api.rescheduleEvent({ id: current.id, revision: current.revision, startAtUtc, timeZone: localTimeZone, durationMinutes: draft.durationMinutes });
      }
      setEditor(null);
      await refresh();
    } catch (cause) { setError(messageFor(cause)); }
  }

  async function removeEvent(event: ScheduleEvent) {
    if (!window.confirm(`Delete “${event.title}”?`)) return;
    try { await api.deleteEvent(event.id, event.revision); await refresh(); } catch (cause) { setError(messageFor(cause)); }
  }

  async function addTask(submit: FormEvent) {
    submit.preventDefault();
    const title = taskTitle.trim();
    if (!title) return;
    try { await api.createTask({ title, day }); setTaskTitle(""); await refresh(); } catch (cause) { setError(messageFor(cause)); }
  }

  async function toggleTask(task: DailyTask) {
    try { await api.updateTask({ id: task.id, completed: !task.completed }); await refresh(); } catch (cause) { setError(messageFor(cause)); }
  }

  async function removeTask(task: DailyTask) {
    try { await api.deleteTask(task.id); await refresh(); } catch (cause) { setError(messageFor(cause)); }
  }

  async function askPlanner(submit: FormEvent) {
    submit.preventDefault();
    if (!command.trim() || isThinking) return;
    setIsThinking(true);
    setAgentResponse(null);
    try { setAgentResponse(await api.propose(command, day, localTimeZone)); }
    catch (cause) { setError(messageFor(cause)); }
    finally { setIsThinking(false); }
  }

  async function applyProposal() {
    if (!agentResponse || agentResponse.kind !== "proposal") return;
    setIsApplying(true);
    try {
      await api.apply(agentResponse);
      setAgentResponse(null);
      setCommand("");
      await refresh();
    } catch (cause) { setError(messageFor(cause)); }
    finally { setIsApplying(false); }
  }

  async function clearContext() {
    try { await api.clearContext(); setAgentResponse(null); setCommand(""); }
    catch (cause) { setError(messageFor(cause)); }
  }

  const visibleDays = useMemo(() => Array.from({ length: 7 }, (_, index) => offsetDay(day, index - 3)), [day]);

  return (
    <main className="app-shell">
      <aside className="rail">
        <div className="brand"><span className="brand-mark">D</span><span>DayPlan</span></div>
        <div className="rail-date"><span>LOCAL AGENDA</span><strong>{dayShort(day)}</strong></div>
        <nav aria-label="Workspace sections">
          <button className="rail-link active"><CalendarDays size={18} /> Today <span>⌘1</span></button>
          <button className="rail-link" disabled><Check size={18} /> Tasks <span>⌘2</span></button>
        </nav>
        <section className="privacy-note">
          <span className="privacy-dot" />
          <div><strong>Private by design</strong><p>Your schedule stays on this device.</p></div>
        </section>
        <div className="rail-footer">DAYPLAN / DESKTOP<br />LOCAL-FIRST PLANNER</div>
      </aside>

      <section className="workspace">
        <header className="topbar">
          <div className="date-heading">
            <p>YOUR DAY</p>
            <h1>{dayLabel(day)}</h1>
          </div>
          <div className="date-controls">
            <button className="icon-button" aria-label="Previous day" onClick={() => setDay(offsetDay(day, -1))}><ArrowLeft size={18} /></button>
            <button className="today-button" onClick={() => setDay(todayDay())}>Today</button>
            <button className="icon-button" aria-label="Next day" onClick={() => setDay(offsetDay(day, 1))}><ArrowRight size={18} /></button>
            <button className="new-event-button" onClick={() => setEditor("new")}><Plus size={17} /> New event</button>
          </div>
        </header>

        <div className="week-strip" aria-label="Date picker">
          {visibleDays.map((candidate) => (
            <button key={candidate} className={`day-chip ${candidate === day ? "selected" : ""}`} onClick={() => setDay(candidate)}>
              <span>{candidate === todayDay() ? "TODAY" : dayShort(candidate).slice(0, 3).toUpperCase()}</span><strong>{candidate.slice(-2)}</strong>
            </button>
          ))}
          <button className="calendar-jump" title="Jump to today" onClick={() => setDay(todayDay())}><CalendarDays size={18} /></button>
        </div>

        <div className="content-grid">
          <section className="agenda-panel">
            <div className="section-header"><div><p>TIME BLOCKS</p><h2>Agenda</h2></div><span>{agenda.events.length} scheduled</span></div>
            {isLoading ? <LoadingLine label="Opening your local schedule" /> : <Agenda events={agenda.events} onEdit={setEditor} onDelete={removeEvent} onAdd={() => setEditor("new")} />}
            <section className="task-area">
              <div className="section-header"><div><p>LOOSE ENDS</p><h2>Daily tasks</h2></div><span>{agenda.tasks.filter((task) => task.completed).length}/{agenda.tasks.length}</span></div>
              <form className="task-add" onSubmit={addTask}>
                <CirclePlus size={19} /><input value={taskTitle} onChange={(event) => setTaskTitle(event.target.value)} placeholder="Add a task for this day" aria-label="Add task" /><button aria-label="Add task" disabled={!taskTitle.trim()}><ArrowRight size={16} /></button>
              </form>
              <div className="task-list">
                {agenda.tasks.length === 0 ? <p className="empty-tasks">A clear list leaves room to think.</p> : agenda.tasks.map((task) => <TaskRow key={task.id} task={task} onToggle={() => toggleTask(task)} onDelete={() => removeTask(task)} />)}
              </div>
            </section>
          </section>

          <aside className="ai-column">
            <PlannerCard status={status} events={agenda.events} command={command} onCommand={setCommand} onSubmit={askPlanner} thinking={isThinking} response={agentResponse} onApply={applyProposal} applying={isApplying} onClear={clearContext} onRefreshStatus={refreshStatus} />
            <section className="quiet-card"><Clock3 size={18} /><div><strong>All times are local</strong><p>{localTimeZone}. Events persist as UTC with their IANA time zone.</p></div></section>
          </aside>
        </div>
      </section>

      {editor && <EventEditor day={day} event={editor === "new" ? undefined : editor} onClose={() => setEditor(null)} onSave={saveEvent} />}
      {error && <div className="toast" role="alert"><TriangleAlert size={17} /><span>{error}</span><button onClick={() => setError(null)} aria-label="Dismiss message"><X size={17} /></button></div>}
    </main>
  );
}

function Agenda({ events, onEdit, onDelete, onAdd }: { events: ScheduleEvent[]; onEdit: (event: ScheduleEvent) => void; onDelete: (event: ScheduleEvent) => void; onAdd: () => void }) {
  if (events.length === 0) return <div className="empty-agenda"><div className="sun-motif" /><p>Nothing is carved into this day yet.</p><button onClick={onAdd}><Plus size={16} /> Add the first block</button></div>;
  return <div className="agenda-list">{events.map((event) => <EventRow key={event.id} event={event} onEdit={() => onEdit(event)} onDelete={() => onDelete(event)} />)}</div>;
}

function EventRow({ event, onEdit, onDelete }: { event: ScheduleEvent; onEdit: () => void; onDelete: () => void }) {
  return <article className="event-row">
    <time>{timeLabel(event.startAtUtc)}<span>{event.durationMinutes} min</span></time>
    <div className="event-connector"><i /></div>
    <button className="event-card" onClick={onEdit}>
      <span className="event-swatch" /><span className="event-main"><strong>{event.title}</strong>{event.notes && <small>{event.notes}</small>}</span><ChevronDown size={16} />
    </button>
    <button className="event-menu" onClick={onDelete} aria-label={`Delete ${event.title}`}><Trash2 size={15} /></button>
  </article>
}

function TaskRow({ task, onToggle, onDelete }: { task: DailyTask; onToggle: () => void; onDelete: () => void }) {
  return <div className={`task-row ${task.completed ? "done" : ""}`}><button onClick={onToggle} className="check-box" aria-label={`Mark ${task.title} ${task.completed ? "incomplete" : "complete"}`}>{task.completed && <Check size={13} />}</button><span>{task.title}</span><button className="task-delete" onClick={onDelete} aria-label={`Delete ${task.title}`}><X size={14} /></button></div>
}

function PlannerCard({ status, events, command, onCommand, onSubmit, thinking, response, onApply, applying, onClear, onRefreshStatus }: {
  status: OllamaStatus | null; events: ScheduleEvent[]; command: string; onCommand: (value: string) => void; onSubmit: (event: FormEvent) => void; thinking: boolean; response: PlannerResponse | null; onApply: () => void; applying: boolean; onClear: () => void; onRefreshStatus: () => void;
}) {
  const ready = status?.running && status.modelInstalled;
  return <section className="planner-card">
    <div className="planner-heading"><div className="bot-orb"><Bot size={19} /></div><div><p>LOCAL PLANNER</p><h2>Say it messily.</h2></div><button onClick={onClear} title="Clear conversational context" className="reset-button"><RotateCcw size={15} /></button></div>
    <div className={`model-state ${ready ? "ready" : "not-ready"}`}><span /><div><strong>{ready ? "Local model ready" : "Ollama setup needed"}</strong><p>{status?.detail ?? "Checking your local model…"}</p></div><button onClick={onRefreshStatus} aria-label="Refresh model status"><RotateCcw size={14} /></button></div>
    <form onSubmit={onSubmit} className="command-form">
      <textarea value={command} onChange={(event) => onCommand(event.target.value)} placeholder='“Move gym to 6pm tomorrow, add dentist Thursday…”' disabled={!ready || thinking} />
      <div><span><Command size={14} /> The model proposes; you decide.</span><button disabled={!command.trim() || !ready || thinking}>{thinking ? <LoaderCircle className="spin" size={16} /> : <Sparkles size={16} />} Plan changes</button></div>
    </form>
    {response?.kind === "clarification" && <div className="clarification"><span>?</span><p>{response.question}</p></div>}
    {response?.kind === "proposal" && <div className="proposal"><p className="proposal-kicker">REVIEW BEFORE APPLYING</p><strong>{response.summary}</strong><ul>{response.operations.map((operation, index) => <li key={`${operation.type}-${index}`}><i className={`operation-dot ${operation.type}`} />{operationLabel(operation, events)}</li>)}</ul><div className="proposal-actions"><button className="cancel-proposal" onClick={onClear}>Discard</button><button className="apply-proposal" onClick={onApply} disabled={applying}>{applying ? <LoaderCircle className="spin" size={15} /> : <Check size={15} />} Apply {response.operations.length} change{response.operations.length === 1 ? "" : "s"}</button></div></div>}
    <p className="planner-footnote"><span>◌</span> No API key. No cloud fallback. Context clears when you clear this session.</p>
  </section>;
}

function EventEditor({ day, event, onClose, onSave }: { day: string; event?: ScheduleEvent; onClose: () => void; onSave: (draft: DraftEvent, event?: ScheduleEvent) => Promise<void> }) {
  const [draft, setDraft] = useState(() => draftFor(day, event));
  const [saving, setSaving] = useState(false);
  async function submit(form: FormEvent) { form.preventDefault(); setSaving(true); try { await onSave(draft, event); } finally { setSaving(false); } }
  return <div className="modal-backdrop" role="presentation"><form className="event-editor" onSubmit={submit} aria-label={event ? "Edit event" : "New event"}><header><div><p>{event ? "EDIT TIME BLOCK" : "NEW TIME BLOCK"}</p><h2>{event ? "Refine the details" : "Make room for it"}</h2></div><button type="button" onClick={onClose} aria-label="Close editor"><X size={19} /></button></header><label>Title<input autoFocus value={draft.title} onChange={(input) => setDraft({ ...draft, title: input.target.value })} required maxLength={140} placeholder="What needs your time?" /></label><div className="form-pair"><label>Date<input type="date" value={draft.day} onChange={(input) => setDraft({ ...draft, day: input.target.value })} required /></label><label>Time<input type="time" value={draft.time} onChange={(input) => setDraft({ ...draft, time: input.target.value })} required /></label></div><label>Duration <span>{draft.durationMinutes} minutes</span><input className="range" type="range" min="5" max="240" step="5" value={draft.durationMinutes} onChange={(input) => setDraft({ ...draft, durationMinutes: Number(input.target.value) })} /></label><label>Notes<textarea value={draft.notes} onChange={(input) => setDraft({ ...draft, notes: input.target.value })} placeholder="Optional context for your future self" maxLength={800} /></label><footer><button type="button" className="editor-cancel" onClick={onClose}>Cancel</button><button className="editor-save" disabled={saving || !draft.title.trim()}>{saving && <LoaderCircle className="spin" size={15} />}{event ? "Save changes" : "Create event"}</button></footer></form></div>;
}

function LoadingLine({ label }: { label: string }) { return <div className="loading-line"><LoaderCircle className="spin" size={18} />{label}</div>; }

function operationLabel(operation: Extract<PlannerResponse, { kind: "proposal" }> ["operations"][number], events: ScheduleEvent[]) {
  const eventTitle = (id: string) => events.find((event) => event.id === id)?.title ?? "the selected event";
  switch (operation.type) {
    case "create_event": return `Create “${operation.title}” at ${timeLabel(operation.startAtUtc)}`;
    case "update_event": return `Update “${eventTitle(operation.eventId)}”`;
    case "delete_event": return `Delete “${eventTitle(operation.eventId)}”`;
    case "reschedule_event": return `Move “${eventTitle(operation.eventId)}” to ${timeLabel(operation.startAtUtc)}`;
  }
}

function messageFor(cause: unknown) { return cause instanceof Error ? cause.message : String(cause); }
