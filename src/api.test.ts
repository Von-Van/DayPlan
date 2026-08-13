import { describe, expect, it } from "vitest";
import { plannerResponseSchema } from "./api";

describe("planner response boundary", () => {
  it("rejects fields outside the approved operation schema", () => {
    expect(() =>
      plannerResponseSchema.parse({
        kind: "proposal",
        proposalId: "30bb9c6a-4020-45a6-806b-5eb71c7ae76f",
        summary: "Move gym",
        expiresAt: "2026-08-12T20:00:00.000Z",
        operations: [
          {
            type: "delete_event",
            eventId: "30bb9c6a-4020-45a6-806b-5eb71c7ae76f",
            expectedRevision: 1,
            sql: "DROP TABLE schedule_events",
          },
        ],
      }),
    ).toThrow();
  });

  it("accepts a clarification without mutations", () => {
    expect(
      plannerResponseSchema.parse({
        kind: "clarification",
        question: "Which Gym event should I move?",
      }).kind,
    ).toBe("clarification");
  });

  it("accepts only typed reminder changes within seven days", () => {
    const base = {
      kind: "proposal",
      proposalId: "30bb9c6a-4020-45a6-806b-5eb71c7ae76f",
      summary: "Remind before gym",
      expiresAt: "2030-05-10T20:00:00.000Z",
    } as const;
    expect(
      plannerResponseSchema.parse({
        ...base,
        operations: [
          {
            type: "update_event",
            eventId: "f67fcad6-2827-4668-829f-1950f441d054",
            expectedRevision: 1,
            title: null,
            notes: null,
            durationMinutes: null,
            reminderChange: { action: "set", minutesBefore: 15 },
          },
        ],
      }).kind,
    ).toBe("proposal");
    expect(() =>
      plannerResponseSchema.parse({
        ...base,
        operations: [
          {
            type: "update_event",
            eventId: "f67fcad6-2827-4668-829f-1950f441d054",
            expectedRevision: 1,
            title: null,
            notes: null,
            durationMinutes: null,
            reminderChange: { action: "set", minutesBefore: 10_081 },
          },
        ],
      }),
    ).toThrow();
  });
});
