import { describe, expect, it } from "vitest";
import { plannerResponseSchema } from "./api";

describe("planner response boundary", () => {
  it("rejects fields outside the approved operation schema", () => {
    expect(() => plannerResponseSchema.parse({
      kind: "proposal", summary: "Move gym", operations: [{
        type: "delete_event", eventId: "30bb9c6a-4020-45a6-806b-5eb71c7ae76f", expectedRevision: 1, sql: "DROP TABLE schedule_events"
      }]
    })).toThrow();
  });

  it("accepts a clarification without mutations", () => {
    expect(plannerResponseSchema.parse({ kind: "clarification", question: "Which Gym event should I move?" }).kind).toBe("clarification");
  });
});

