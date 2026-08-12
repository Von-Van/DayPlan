# DayPlan

Native SwiftUI rewrite of DayPlan for iPhone and Mac.

This app is intentionally local-first. Planner data, collection data, reminder
settings, and content digests are stored on-device with SwiftData. There is no
Flask backend, account system, cloud sync, or server dependency.

The previous Flask desktop prototype is preserved on the
`codex/legacy-dayplan-desktop` branch.

## App Shape

- By Day: daily checklist with historical calendar selection.
- Goals: native Mac workspace for larger outcomes, goal action backlogs, and
  scheduling actions into daily checklists.
- Collections: non-date-bound task lists.
- Yesterday: local content digest fed by explicit source adapters.
- Settings: notification permission, source toggles, and future data tools.

The Mac app is a separate native target named `DayPlanMac`. It uses its own
local SwiftData store and opens to a Goals + Today workspace. It does not sync
automatically with the iPhone app; use JSON export/import to move data between
devices.

## Checklist Widget

DayPlan includes an interactive checklist widget for the iPhone Lock Screen and
Home Screen. Opening today's checklist publishes a minimal snapshot containing
task titles, completion state, and reminder identifiers to a private App Group.
The widget never receives notes, collections, Yesterday content, or the main
SwiftData store.

Checking an item in the widget updates the widget immediately and stores a
bounded mutation queue. DayPlan reconciles those changes into completion history
when the app next becomes active. iOS requires authentication before interactive
Lock Screen widget actions run on a locked device.

Both the `DayPlan` and `DayPlanWidget` targets must use the
`group.com.jakemauldin.DayPlan` App Group in Signing & Capabilities.

## Yesterday Sources

Add RSS or Atom feeds from Settings to fill Yesterday with real content. Each
source can be enabled independently and configured with:

- A category used in the daily digest.
- Optional comma-separated include and exclude keywords.
- A per-refresh item limit.

Refreshing Yesterday fetches every enabled source, applies its filters, and
rebuilds the deterministic local summary. A failing source does not block the
others.

## Suggested Items

When viewing today in By Day, DayPlan deterministically selects one
high-priority follow-up from locally stored Yesterday content. Accepting adds a
non-persistent, reminder-free checklist item with source context; dismissing
permanently excludes that source event. Decisions and scoring remain on-device,
and no content is sent to a cloud AI service.

Suggestion source controls in Settings let each source be disabled for
suggestions, marked low/normal/high priority, and filtered with suggestion-only
include/exclude keywords. Dismissed suggestion decisions can be cleared without
reintroducing already accepted suggestions.

## Stats And Data

Stats summarize today, recent daily checklist completion, streaks, and
collection completion from local SwiftData history.

Settings can export a JSON backup of local DayPlan data and import a backup by
replacing the current on-device data after confirmation.

## Notification Scope

iOS apps can schedule and manage their own notifications. They cannot read all
notifications from other apps in Notification Center through public APIs. The
Yesterday tab therefore uses an adapter-based local inbox, with a sample adapter
included for v1 until specific real sources are chosen.

## Feed Security

- Feed URLs must use public HTTPS hosts and cannot contain credentials.
- Redirect destinations are checked with the same URL policy.
- Feed downloads use an ephemeral, cookie-free URL session and stop at 2 MB.
- XML external-entity resolution is disabled.
- Feed HTML is reduced to bounded plain text before it is stored.
- Content remains on-device and links open externally.

## Requirements

- Xcode 15 or newer
- iOS 17 or newer
- SwiftData

Open `DayPlan.xcodeproj` in Xcode and run the `DayPlan` scheme on an iPhone
simulator or device.

## Command Line Checks

```bash
xcodebuild -project DayPlan.xcodeproj -scheme DayPlan -destination 'platform=iOS Simulator,name=iPhone 17' test
xcodebuild -project DayPlan.xcodeproj -scheme DayPlanMac -destination 'platform=macOS' build
```
