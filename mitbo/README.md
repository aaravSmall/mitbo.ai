# mitbo

mitbo is a bouldering beta assistant: point your phone's camera at a climbing wall and it pose-tracks the climber in real time, then speaks move-by-move cues (beta) as you climb, so you get live coaching without a human spotter reading the route for you.

## Status

This is a bare Flutter scaffold (default counter app) targeting iOS and Android. No camera, pose-tracking, or text-to-speech functionality has been added yet — see the root [../CONTEXT.md](../CONTEXT.md) and [../FUTURE_PLANS.md](../FUTURE_PLANS.md) for the product plan and roadmap.

## Project layout

- `lib/screens/` — top-level app screens
- `lib/widgets/` — reusable UI components
- `lib/services/` — device/platform integrations (camera, TTS, etc. — not yet added)
- `lib/models/` — data models
- `lib/state/` — app state management

## Getting started

```
flutter pub get
flutter run
```
