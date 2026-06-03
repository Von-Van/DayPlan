# DayPlan iOS

Native SwiftUI rewrite of DayPlan for iPhone.

This app is intentionally local-first. Planner data, collection data, reminder
settings, and content digests are stored on-device with SwiftData. There is no
Flask backend, account system, cloud sync, or server dependency.

## App Shape

- By Day: daily checklist with historical calendar selection.
- Collections: non-date-bound task lists.
- Yesterday: local content digest fed by explicit source adapters.
- Settings: notification permission, source toggles, and future data tools.

## Notification Scope

iOS apps can schedule and manage their own notifications. They cannot read all
notifications from other apps in Notification Center through public APIs. The
Yesterday tab therefore uses an adapter-based local inbox, with a sample adapter
included for v1 until specific real sources are chosen.

## Requirements

- Xcode 15 or newer
- iOS 17 or newer
- SwiftData

Open `DayPlan.xcodeproj` in Xcode and run the `DayPlan` scheme on an iPhone
simulator or device.
