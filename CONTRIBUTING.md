# Contributing

Thanks for your interest. This repository is a **portfolio preview** and intentionally incomplete. Contributions should prioritize clarity, readability, and presentability rather than feature completeness.

## Guidelines

- Keep PRs small and focused
- Explain intent and tradeoffs in the PR description
- Avoid introducing new dependencies unless necessary
- Update documentation when behavior changes

## Development

- Xcode 15 or newer
- iOS 17 or newer
- Open `DayPlan.xcodeproj` and run the `DayPlan` scheme
- Run tests with `xcodebuild -project DayPlan.xcodeproj -scheme DayPlan -destination 'platform=iOS Simulator,name=iPhone 17' test`
