import { invoke } from "@tauri-apps/api/core";
import { z } from "zod";

export const eventSchema = z.object({
  id: z.string().uuid(),
  title: z.string(),
  notes: z.string(),
  startAtUtc: z.string().datetime({ offset: true }),
  timeZone: z.string(),
  durationMinutes: z.number().int().min(5).max(1440),
  revision: z.number().int().positive(),
  createdAt: z.string().datetime({ offset: true }),
  updatedAt: z.string().datetime({ offset: true })
}).strict();

export const taskSchema = z.object({
  id: z.string().uuid(),
  title: z.string(),
  day: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  completed: z.boolean(),
  completedAt: z.string().datetime({ offset: true }).nullable(),
  sortOrder: z.number().int(),
  createdAt: z.string().datetime({ offset: true }),
  updatedAt: z.string().datetime({ offset: true })
}).strict();

export const operationSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("create_event"), title: z.string().min(1).max(140), notes: z.string(), startAtUtc: z.string().datetime({ offset: true }), timeZone: z.string(), durationMinutes: z.number().int().min(5).max(1440) }).strict(),
  z.object({ type: z.literal("update_event"), eventId: z.string().uuid(), expectedRevision: z.number().int().positive(), title: z.string().nullable(), notes: z.string().nullable(), durationMinutes: z.number().int().min(5).max(1440).nullable() }).strict(),
  z.object({ type: z.literal("delete_event"), eventId: z.string().uuid(), expectedRevision: z.number().int().positive() }).strict(),
  z.object({ type: z.literal("reschedule_event"), eventId: z.string().uuid(), expectedRevision: z.number().int().positive(), title: z.string().min(1).max(140).nullable(), notes: z.string().max(800).nullable(), startAtUtc: z.string().datetime({ offset: true }), timeZone: z.string(), durationMinutes: z.number().int().min(5).max(1440).nullable() }).strict()
]);

export const plannerResponseSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("proposal"), proposalId: z.string().uuid(), summary: z.string().min(1).max(280), operations: z.array(operationSchema).min(1).max(12), expiresAt: z.string().datetime({ offset: true }) }).strict(),
  z.object({ kind: z.literal("clarification"), question: z.string().min(1).max(280) }).strict()
]);

const agendaSchema = z.object({ events: z.array(eventSchema), tasks: z.array(taskSchema) }).strict();
const statusSchema = z.object({ running: z.boolean(), modelInstalled: z.boolean(), modelName: z.string(), modelDigest: z.string().nullable(), ollamaVersion: z.string().nullable(), detail: z.string() }).strict();
const commandErrorSchema = z.object({
  code: z.string(),
  message: z.string(),
  retryable: z.boolean(),
  details: z.unknown().optional()
}).strict();
const localTimeOptionSchema = z.object({ startAtUtc: z.string().datetime({ offset: true }), utcOffsetMinutes: z.number().int(), label: z.string() }).strict();
const localDateTimeResolutionSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("resolved"), startAtUtc: z.string().datetime({ offset: true }) }).strict(),
  z.object({ kind: z.literal("ambiguous"), options: z.array(localTimeOptionSchema).length(2) }).strict(),
  z.object({ kind: z.literal("nonexistent"), message: z.string() }).strict()
]);
const backupSchema = z.object({ name: z.string(), createdAt: z.string().datetime({ offset: true }), sizeBytes: z.number().nonnegative() }).strict();
const databaseStatusSchema = z.object({ ready: z.boolean(), schemaVersion: z.number().int().nonnegative(), error: commandErrorSchema.nullable(), backups: z.array(backupSchema) }).strict();
const exportBundleSchema = z.object({
  formatVersion: z.literal(1),
  exportedAt: z.string().datetime({ offset: true }),
  events: z.array(eventSchema).max(100_000),
  tasks: z.array(taskSchema).max(100_000)
}).strict();
const importPreviewSchema = z.object({ eventCount: z.number().int().nonnegative(), taskCount: z.number().int().nonnegative(), earliestDay: z.string().nullable(), latestDay: z.string().nullable() }).strict();

export type ScheduleEvent = z.infer<typeof eventSchema>;
export type DailyTask = z.infer<typeof taskSchema>;
export type PlannerResponse = z.infer<typeof plannerResponseSchema>;
export type OllamaStatus = z.infer<typeof statusSchema>;
export type CommandErrorPayload = z.infer<typeof commandErrorSchema>;
export type LocalDateTimeResolution = z.infer<typeof localDateTimeResolutionSchema>;
export type ExportBundle = z.infer<typeof exportBundleSchema>;
export type DatabaseStatus = z.infer<typeof databaseStatusSchema>;
export type EventInput = Omit<ScheduleEvent, "id" | "revision" | "createdAt" | "updatedAt">;

export class DayPlanError extends Error {
  code: string;
  retryable: boolean;
  details?: unknown;

  constructor(payload: CommandErrorPayload) {
    super(payload.message);
    this.name = "DayPlanError";
    this.code = payload.code;
    this.retryable = payload.retryable;
    this.details = payload.details;
  }
}

async function invokeCommand<T>(name: string, args?: Record<string, unknown>) {
  try {
    return await invoke<T>(name, args);
  } catch (cause) {
    const parsed = commandErrorSchema.safeParse(cause);
    if (parsed.success) throw new DayPlanError(parsed.data);
    throw cause instanceof Error ? cause : new Error(String(cause));
  }
}

export const api = {
  async listAgenda(day: string, timeZone: string) {
    return agendaSchema.parse(await invokeCommand("list_agenda", { day, timeZone }));
  },
  async createEvent(input: Pick<EventInput, "title" | "notes" | "startAtUtc" | "timeZone" | "durationMinutes">) {
    return eventSchema.parse(await invokeCommand("create_event", { input }));
  },
  async updateEvent(input: { id: string; revision: number; title?: string; notes?: string; startAtUtc?: string; timeZone?: string; durationMinutes?: number }) {
    return eventSchema.parse(await invokeCommand("update_event", { input }));
  },
  async deleteEvent(id: string, revision: number) {
    await invokeCommand("delete_event", { id, revision });
  },
  async rescheduleEvent(input: { id: string; revision: number; startAtUtc: string; timeZone: string; durationMinutes: number }) {
    return eventSchema.parse(await invokeCommand("reschedule_event", { input }));
  },
  async createTask(input: { title: string; day: string }) {
    return taskSchema.parse(await invokeCommand("create_task", { input }));
  },
  async updateTask(input: { id: string; title?: string; completed?: boolean }) {
    return taskSchema.parse(await invokeCommand("update_task", { input }));
  },
  async deleteTask(id: string) {
    await invokeCommand("delete_task", { id });
  },
  async status() {
    return statusSchema.parse(await invokeCommand("current_ollama_status"));
  },
  async propose(command: string, day: string, timeZone: string) {
    return plannerResponseSchema.parse(await invokeCommand("propose_schedule_changes", { command, day, timeZone }));
  },
  async apply(proposalId: string) {
    return z.array(eventSchema).parse(await invokeCommand("apply_schedule_changes", { proposalId }));
  },
  async discardProposal(proposalId: string) {
    await invokeCommand("discard_schedule_proposal", { proposalId });
  },
  async cancelPlannerRequest() {
    await invokeCommand("cancel_planner_request");
  },
  async clearContext() {
    await invokeCommand("clear_planner_context");
  },
  async resolveLocalDateTime(day: string, time: string, timeZone: string) {
    return localDateTimeResolutionSchema.parse(await invokeCommand("resolve_local_datetime", { input: { day, time, timeZone } }));
  },
  async databaseStatus() {
    return databaseStatusSchema.parse(await invokeCommand("database_status"));
  },
  async exportData() {
    return exportBundleSchema.parse(await invokeCommand("export_planner_data"));
  },
  async previewImport(bundle: ExportBundle) {
    return importPreviewSchema.parse(await invokeCommand("preview_planner_import", { bundle }));
  },
  async importData(bundle: ExportBundle) {
    return importPreviewSchema.parse(await invokeCommand("import_planner_data", { bundle }));
  },
  async restoreBackup(backupName: string) {
    await invokeCommand("restore_database_backup", { backupName });
  }
};
