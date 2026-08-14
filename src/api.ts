import { invoke } from "@tauri-apps/api/core";
import { z } from "zod";

export const eventSchema = z
  .object({
    id: z.string().uuid(),
    title: z.string(),
    notes: z.string(),
    startAtUtc: z.string().datetime({ offset: true }),
    timeZone: z.string(),
    durationMinutes: z.number().int().min(5).max(1440),
    reminderMinutesBefore: z.number().int().min(0).max(10_080).nullable(),
    reminderStatus: z.enum([
      "none",
      "pending",
      "scheduled",
      "needs_permission",
      "error",
      "expired",
    ]),
    revision: z.number().int().positive(),
    createdAt: z.string().datetime({ offset: true }),
    updatedAt: z.string().datetime({ offset: true }),
  })
  .strict();

export const reminderChangeSchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("unchanged") }).strict(),
  z.object({ action: z.literal("clear") }).strict(),
  z
    .object({
      action: z.literal("set"),
      minutesBefore: z.number().int().min(0).max(10_080),
    })
    .strict(),
]);

export const taskSchema = z
  .object({
    id: z.string().uuid(),
    title: z.string(),
    day: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    completed: z.boolean(),
    completedAt: z.string().datetime({ offset: true }).nullable(),
    sortOrder: z.number().int(),
    createdAt: z.string().datetime({ offset: true }),
    updatedAt: z.string().datetime({ offset: true }),
  })
  .strict();

export const operationSchema = z.discriminatedUnion("type", [
  z
    .object({
      type: z.literal("create_event"),
      title: z.string().min(1).max(140),
      notes: z.string(),
      startAtUtc: z.string().datetime({ offset: true }),
      timeZone: z.string(),
      durationMinutes: z.number().int().min(5).max(1440),
      reminderMinutesBefore: z.number().int().min(0).max(10_080).nullable(),
    })
    .strict(),
  z
    .object({
      type: z.literal("update_event"),
      eventId: z.string().uuid(),
      expectedRevision: z.number().int().positive(),
      title: z.string().nullable(),
      notes: z.string().nullable(),
      durationMinutes: z.number().int().min(5).max(1440).nullable(),
      reminderChange: reminderChangeSchema,
    })
    .strict(),
  z
    .object({
      type: z.literal("delete_event"),
      eventId: z.string().uuid(),
      expectedRevision: z.number().int().positive(),
    })
    .strict(),
  z
    .object({
      type: z.literal("reschedule_event"),
      eventId: z.string().uuid(),
      expectedRevision: z.number().int().positive(),
      title: z.string().min(1).max(140).nullable(),
      notes: z.string().max(800).nullable(),
      startAtUtc: z.string().datetime({ offset: true }),
      timeZone: z.string(),
      durationMinutes: z.number().int().min(5).max(1440).nullable(),
      reminderChange: reminderChangeSchema,
    })
    .strict(),
]);

export const plannerResponseSchema = z.discriminatedUnion("kind", [
  z
    .object({
      kind: z.literal("proposal"),
      proposalId: z.string().uuid(),
      summary: z.string().min(1).max(280),
      operations: z.array(operationSchema).min(1).max(12),
      expiresAt: z.string().datetime({ offset: true }),
    })
    .strict(),
  z
    .object({
      kind: z.literal("clarification"),
      question: z.string().min(1).max(280),
    })
    .strict(),
]);

const agendaSchema = z
  .object({ events: z.array(eventSchema), tasks: z.array(taskSchema) })
  .strict();
const statusSchema = z
  .object({
    phase: z.enum([
      "unavailable",
      "starting",
      "ready_without_model",
      "downloading",
      "model_ready",
      "update_required",
      "error",
    ]),
    running: z.boolean(),
    modelInstalled: z.boolean(),
    modelName: z.string(),
    modelDigest: z.string().nullable(),
    ollamaVersion: z.string().nullable(),
    modelLicense: z.string().nullable(),
    detail: z.string(),
    download: z
      .object({
        completed: z.number().nonnegative(),
        total: z.number().nonnegative().nullable(),
        percent: z.number().int().min(0).max(100).nullable(),
        status: z.string(),
      })
      .strict()
      .nullable(),
    storageBytes: z.number().nonnegative().nullable(),
  })
  .strict();
const commandErrorSchema = z
  .object({
    code: z.string(),
    message: z.string(),
    retryable: z.boolean(),
    details: z.unknown().optional(),
  })
  .strict();
const localTimeOptionSchema = z
  .object({
    startAtUtc: z.string().datetime({ offset: true }),
    utcOffsetMinutes: z.number().int(),
    label: z.string(),
  })
  .strict();
const localDateTimeResolutionSchema = z.discriminatedUnion("kind", [
  z
    .object({
      kind: z.literal("resolved"),
      startAtUtc: z.string().datetime({ offset: true }),
    })
    .strict(),
  z
    .object({
      kind: z.literal("ambiguous"),
      options: z.array(localTimeOptionSchema).length(2),
    })
    .strict(),
  z.object({ kind: z.literal("nonexistent"), message: z.string() }).strict(),
]);
const backupSchema = z
  .object({
    name: z.string(),
    createdAt: z.string().datetime({ offset: true }),
    sizeBytes: z.number().nonnegative(),
  })
  .strict();
const databaseStatusSchema = z
  .object({
    ready: z.boolean(),
    schemaVersion: z.number().int().nonnegative(),
    error: commandErrorSchema.nullable(),
    backups: z.array(backupSchema),
  })
  .strict();
const importPreviewSchema = z
  .object({
    eventCount: z.number().int().nonnegative(),
    taskCount: z.number().int().nonnegative(),
    earliestDay: z.string().nullable(),
    latestDay: z.string().nullable(),
  })
  .strict();
const importSelectionSchema = z
  .object({ token: z.string().uuid(), preview: importPreviewSchema })
  .strict();
const fileActionResultSchema = z
  .object({ completed: z.boolean(), fileName: z.string().nullable() })
  .strict();

export type ScheduleEvent = z.infer<typeof eventSchema>;
export type DailyTask = z.infer<typeof taskSchema>;
export type PlannerResponse = z.infer<typeof plannerResponseSchema>;
export type ReminderChange = z.infer<typeof reminderChangeSchema>;
export type OllamaStatus = z.infer<typeof statusSchema>;
export type CommandErrorPayload = z.infer<typeof commandErrorSchema>;
export type LocalDateTimeResolution = z.infer<
  typeof localDateTimeResolutionSchema
>;
export type DatabaseStatus = z.infer<typeof databaseStatusSchema>;
export type ImportSelection = z.infer<typeof importSelectionSchema>;

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
    return agendaSchema.parse(
      await invokeCommand("list_agenda", { day, timeZone }),
    );
  },
  async createEvent(input: {
    title: string;
    notes: string;
    startAtUtc: string;
    timeZone: string;
    durationMinutes: number;
    reminderMinutesBefore: number | null;
  }) {
    return eventSchema.parse(await invokeCommand("create_event", { input }));
  },
  async updateEvent(input: {
    id: string;
    revision: number;
    title?: string;
    notes?: string;
    startAtUtc?: string;
    timeZone?: string;
    durationMinutes?: number;
    reminderChange?: ReminderChange;
  }) {
    return eventSchema.parse(await invokeCommand("update_event", { input }));
  },
  async deleteEvent(id: string, revision: number) {
    await invokeCommand("delete_event", { id, revision });
  },
  async rescheduleEvent(input: {
    id: string;
    revision: number;
    startAtUtc: string;
    timeZone: string;
    durationMinutes: number;
    reminderChange?: ReminderChange;
  }) {
    return eventSchema.parse(
      await invokeCommand("reschedule_event", { input }),
    );
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
  async downloadModel() {
    await invokeCommand("download_ollama_model");
  },
  async cancelModelDownload() {
    await invokeCommand("cancel_ollama_model_download");
  },
  async restartModelRuntime() {
    await invokeCommand("restart_ollama_runtime");
  },
  async removeModel() {
    await invokeCommand("remove_ollama_model");
  },
  async propose(command: string, day: string, timeZone: string) {
    return plannerResponseSchema.parse(
      await invokeCommand("propose_schedule_changes", {
        command,
        day,
        timeZone,
      }),
    );
  },
  async apply(proposalId: string) {
    return z
      .array(eventSchema)
      .parse(await invokeCommand("apply_schedule_changes", { proposalId }));
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
    return localDateTimeResolutionSchema.parse(
      await invokeCommand("resolve_local_datetime", {
        input: { day, time, timeZone },
      }),
    );
  },
  async databaseStatus() {
    return databaseStatusSchema.parse(await invokeCommand("database_status"));
  },
  async exportFile() {
    return fileActionResultSchema.parse(
      await invokeCommand("export_planner_file"),
    );
  },
  async selectImport() {
    return importSelectionSchema
      .nullable()
      .parse(await invokeCommand("select_planner_import"));
  },
  async applySelectedImport(token: string) {
    return importPreviewSchema.parse(
      await invokeCommand("apply_selected_import", { token }),
    );
  },
  async discardSelectedImport() {
    await invokeCommand("discard_selected_import");
  },
  async exportDiagnostics() {
    return fileActionResultSchema.parse(
      await invokeCommand("export_diagnostic_bundle"),
    );
  },
  async restoreBackup(backupName: string) {
    await invokeCommand("restore_database_backup", { backupName });
  },
};
