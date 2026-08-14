# DayPlan — Local AI Desktop Planner

DayPlan is a local-first day planner for macOS and Windows. It pairs a timed agenda, daily tasks, per-event reminders, recovery tooling, and a natural-language planner that turns messy requests into reviewed, typed schedule proposals.

> “Move gym to 6pm tomorrow, add dentist Thursday at 2pm, push everything after lunch back 30 minutes.”

The portfolio story is the permission boundary, not the chat box: the model never receives a database handle and cannot write planner data. It can emit exactly one strict tool call containing a proposal or a clarification. DayPlan validates that response twice, shows a human-readable preview, and applies only a server-owned, single-use proposal ID after explicit confirmation.

The earlier SwiftUI / SwiftData / WidgetKit app remains available on the [`ios-swiftui`](https://github.com/Von-Van/DayPlan/tree/ios-swiftui) branch. This desktop edition starts with a fresh local database and intentionally does not sync or migrate iOS data.

## Architecture

```mermaid
flowchart LR
  U["React + TypeScript UI"] -->|"Typed Tauri commands"| R["Rust services"]
  R --> D["SQLite repository"]
  U -->|"Natural-language command"| A["Rust PlannerAgent"]
  A -->|"Ranked event context; no notes"| O["Ollama qwen3:8b on localhost"]
  O -->|"Exactly one tool call"| V["Strict schema + Serde validation"]
  V -->|"Proposal ID + preview"| U
  U -->|"Confirm proposal ID"| P["Pending proposal registry"]
  P -->|"Revision recheck"| T["One SQLite transaction"]
  T --> D
  D --> X["Reminder outbox"]
  X --> N["Official Tauri notification plugin"]
```

- **Tauri 2 + React + TypeScript** provides one desktop codebase for macOS 13+ universal binaries and Windows 10 22H2/11 x64.
- **Rust services** own validation, local-time resolution, AI context selection, proposal state, file import/export, and every database mutation.
- **SQLite** stores `ScheduleEvent` and `DailyTask` records. Transactional migrations use `PRAGMA user_version`; startup runs `quick_check`; migration/import/restore operations create checkpointed backups, with the latest five retained.
- **Ollama** runs `qwen3:8b` at `127.0.0.1`. DayPlan has no account, API key, hosted backend, cloud fallback, or per-command API fee.

## AI permission boundary

The renderer cannot submit invented mutations. `PlannerAgent` keeps one pending proposal per in-memory session for ten minutes. Applying accepts only its opaque `proposalId`; the Rust layer retrieves the validated operations, rechecks event IDs and revisions, and consumes the proposal after one attempt. Clearing conversation removes all four retained turns and pending proposals; discarding a proposal does not erase the conversation.

The only permitted operations are:

| Operation          | Typed fields                                                                                         |
| ------------------ | ---------------------------------------------------------------------------------------------------- |
| `create_event`     | title, notes, UTC start, IANA time zone, duration, optional reminder offset                          |
| `update_event`     | event ID + revision, optional title/notes/duration, typed reminder change                            |
| `delete_event`     | event ID + revision                                                                                  |
| `reschedule_event` | event ID + revision, UTC start, IANA time zone, optional title/notes/duration, typed reminder change |

The model must call `propose_schedule_changes` exactly once. Extra calls, unknown fields, malformed JSON, invalid UTC timestamps/time zones, duplicate targets, stale references, more than 12 operations, or an oversized response are rejected with no mutation. React validates the public response with strict Zod schemas; Rust deserializes with `deny_unknown_fields` and validates it again before it can enter the pending-proposal registry.

Ambiguous titles, missing targets/dates, bare 12-hour times such as `at 2`, duplicated DST clock times, nonexistent DST times, unsupported recurrence/task changes, and conflicting compound requests produce a clarification. Compound commands are all-or-nothing.

AI context is intentionally small: current day/time zone, title/date-ranked event candidates, session-referenced IDs, and the previous four structured turns. It sends at most 60 events and never sends event notes. Conversation state is not persisted.

## Storage, recovery, and privacy

The current database schema is version 2. Existing beta databases are migrated transactionally. Day queries include events that overlap the selected day, not just events that begin during it. Manual edits atomically update title, notes, time, time zone, duration, and reminder under one revision check.

Settings offers:

- strict, versioned JSON export;
- import preview and explicit confirmation before replacement;
- automatic backup before import and recovery from the five retained backups;
- model/version diagnostics;
- a private diagnostic ZIP generated only on request; and
- manual update checks.

Rotating local logs retain five 512 KB files. DayPlan does not log commands, event/task titles, notes, proposal contents, or database paths. Diagnostic bundles contain only version/health metadata and those redacted logs. SQLite relies on normal OS account permissions and FileVault or BitLocker when enabled; application-level database encryption is deferred.

## Event reminders

An event can have one reminder from its start time through seven days beforehand. The UI includes presets for start, 5, 10, 15, 30, and 60 minutes, plus one day. AI operations use either `reminderMinutesBefore` or a typed `ReminderChange` (`unchanged`, `clear`, or `set`). Rescheduling retains the offset unless explicitly changed, deleting cancels it, and imports generate new internal notification IDs.

Desired reminder state and the retryable outbox are stored in the same SQLite transaction as the event. Notifications contain the event title and localized start time—never notes. Permission is requested only when a reminder is first enabled, and denial leaves an AI proposal unapplied.

Desktop caveat: the official Tauri notification plugin sends the OS notification, while DayPlan’s Rust worker owns timing. Closing the window keeps DayPlan in the system tray so reminders continue; fully choosing **Quit DayPlan** stops delivery. Windows notification acceptance testing must use the installed NSIS build.

## First run and local model

The first-run flow explains local storage, Ollama, the model download, and optional notification permission.

1. Install [Ollama for macOS or Windows](https://ollama.com/download).
2. Download the model once:

   ```bash
   ollama pull qwen3:8b
   ```

3. Start DayPlan and refresh model diagnostics.

`qwen3:8b` is about 5.2 GB. The supported beta baseline is macOS 13+ or Windows 10 22H2/11 x64, with 16 GB RAM recommended and roughly 10 GB free for Ollama plus the model. Inference latency depends on local hardware, but calendar data stays on the machine after installation. [Ollama quickstart](https://docs.ollama.com/quickstart) · [Qwen3 model](https://ollama.com/library/qwen3%3A8b)

## Evaluation harness

[`eval/cases.json`](eval/cases.json) contains 68 hand-labeled cases covering creates/updates/deletes/reschedules, compound changes, bulk shifts, conversational refinements, reminders, DST transitions, date rollover, noon/midnight, duplicate titles, prompt injection, unsupported requests, and ambiguity.

The evaluator uses the production `PlannerAgent` and ranked repository context—not a separate parser—and runs three times against one model digest:

```bash
npm run eval
```

It records the Ollama version, model tag/digest, per-case failures, schema compliance, normalized-order exact proposal accuracy, and field accuracy in `eval/results/latest.json`. Every run must meet:

- 100% schema compliance;
- 100% safety/ambiguity cases;
- at least 85% exact proposal accuracy; and
- at least 95% field accuracy.

### Current baseline

No valid live baseline is committed yet. The 68-case suite was invoked on August 13, 2026, but stopped before scoring because Ollama was not running. The harness exits with a non-success status in that state rather than reporting an availability failure as model quality. A three-run result against one recorded `qwen3:8b` digest is a beta release blocker.

## Development and quality gates

Toolchains are pinned by [`.nvmrc`](.nvmrc), [`rust-toolchain.toml`](rust-toolchain.toml), `package-lock.json`, and `Cargo.lock`.

```bash
npm ci
npm run tauri dev

npm run format:check
npm run version:check
npm test
npm run build
cargo fmt --manifest-path src-tauri/Cargo.toml --check
cargo test --manifest-path src-tauri/Cargo.toml
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings
```

PR CI adds production-only npm auditing, `cargo-audit`, `cargo-deny` advisory/license/source checks, and unsigned native bundles on macOS and Windows. The frontend includes keyboard navigation, modal focus containment, Escape handling, screen-reader live regions, visible focus indicators, and reduced-motion support.

## Signed beta delivery

A `v*` tag triggers a fail-closed draft-release workflow:

- arm64 and Intel macOS app builds are merged into a universal binary, Developer ID signed, notarized with App Store Connect API credentials, stapled, and packaged as a DMG;
- the Windows x64 NSIS installer is signed with Azure Artifact Signing and verified with `Get-AuthenticodeSignature`;
- updater packages are signed after native signing, and `latest.json`, SHA-256 checksums, release notes, and a CycloneDX SBOM are attached; and
- the GitHub Release remains a draft.

The updater contacts GitHub only after **Check for updates** is selected, shows release notes, and asks again before installing a signed package. A separate manually dispatched workflow, protected by the `public-beta-publish` environment, publishes the already-verified draft only after native smoke tests are confirmed. See the [release checklist](RELEASE_CHECKLIST.md), [Tauri updater documentation](https://v2.tauri.app/plugin/updater/), and [Tauri distribution guidance](https://v2.tauri.app/distribute/).

## Deliberate scope limits

Recurrence, sync, accounts, cloud AI, task reminders, collaboration, iOS widgets, goals, collections, feeds, and application-level database encryption remain out of scope. DayPlan is local-first and single-device.
