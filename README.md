# DayPlan iOS

Native SwiftUI rewrite of DayPlan for iPhone.

This app is intentionally local-first. Planner data, collection data, reminder
settings, and content digests are stored on-device with SwiftData. There is no
Flask backend, account system, cloud sync, or server dependency.

The previous Flask desktop prototype is preserved on the
`codex/legacy-dayplan-desktop` branch.

## App Shape

- By Day: daily checklist with historical calendar selection.
- Collections: non-date-bound task lists.
- Yesterday: local content digest fed by explicit source adapters.
- Settings: notification permission, source toggles, and future data tools.

## Yesterday Sources

Add RSS or Atom feeds from Settings to fill Yesterday with real content. Each
source can be enabled independently and configured with:

- A category used in the daily digest.
- Optional comma-separated include and exclude keywords.
- A per-refresh item limit.

Refreshing Yesterday fetches every enabled source, applies its filters, and
rebuilds the deterministic local summary. A failing source does not block the
others.

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
```
