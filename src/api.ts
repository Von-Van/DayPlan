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
  z.object({ type: z.literal("reschedule_event"), eventId: z.string().uuid(), expectedRevision: z.number().int().positive(), startAtUtc: z.string().datetime({ offset: true }), timeZone: z.string(), durationMinutes: z.number().int().min(5).max(1440).nullable() }).strict()
]);

export const plannerResponseSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("proposal"), summary: z.string().min(1).max(280), operations: z.array(operationSchema).min(1).max(12) }).strict(),
  z.object({ kind: z.literal("clarification"), question: z.string().min(1).max(280) }).strict()
]);

const agendaSchema = z.object({ events: z.array(eventSchema), tasks: z.array(taskSchema) }).strict();
const statusSchema = z.object({ running: z.boolean(), modelInstalled: z.boolean(), modelName: z.string(), detail: z.string() }).strict();

export type ScheduleEvent = z.infer<typeof eventSchema>;
export type DailyTask = z.infer<typeof taskSchema>;
export type PlannerResponse = z.infer<typeof plannerResponseSchema>;
export type OllamaStatus = z.infer<typeof statusSchema>;
export type EventInput = Omit<ScheduleEvent, "id" | "revision" | "createdAt" | "updatedAt">;

export const api = {
  async listAgenda(day: string, timeZone: string) {
    return agendaSchema.parse(await invoke("list_agenda", { day, timeZone }));
  },
  async createEvent(input: Pick<EventInput, "title" | "notes" | "startAtUtc" | "timeZone" | "durationMinutes">) {
    return eventSchema.parse(await invoke("create_event", { input }));
  },
  async updateEvent(input: { id: string; revision: number; title?: string; notes?: string; durationMinutes?: number }) {
    return eventSchema.parse(await invoke("update_event", { input }));
  },
  async deleteEvent(id: string, revision: number) {
    await invoke("delete_event", { id, revision });
  },
  async rescheduleEvent(input: { id: string; revision: number; startAtUtc: string; timeZone: string; durationMinutes: number }) {
    return eventSchema.parse(await invoke("reschedule_event", { input }));
  },
  async createTask(input: { title: string; day: string }) {
    return taskSchema.parse(await invoke("create_task", { input }));
  },
  async updateTask(input: { id: string; title?: string; completed?: boolean }) {
    return taskSchema.parse(await invoke("update_task", { input }));
  },
  async deleteTask(id: string) {
    await invoke("delete_task", { id });
  },
  async status() {
    return statusSchema.parse(await invoke("current_ollama_status"));
  },
  async propose(command: string, day: string, timeZone: string) {
    return plannerResponseSchema.parse(await invoke("propose_schedule_changes", { command, day, timeZone }));
  },
  async apply(proposal: PlannerResponse) {
    return z.array(eventSchema).parse(await invoke("apply_schedule_changes", { proposal }));
  },
  async clearContext() {
    await invoke("clear_planner_context");
  }
};
