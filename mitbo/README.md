# mitbo

mitbo is a bouldering beta assistant: point your phone's camera at a climbing wall and it pose-tracks the climber in real time, then speaks move-by-move cues (beta) as you climb, so you get live coaching without a human spotter reading the route for you.

## Status

Flutter app targeting iOS and Android. It currently has one-time height/wingspan onboarding (saved on the device), go_router navigation, and a live back-camera preview with full permission handling. Pose tracking, hold marking, beta generation, and text-to-speech aren't built yet — see the root [../CONTEXT.md](../CONTEXT.md) and [../FUTURE_PLANS.md](../FUTURE_PLANS.md) for the product plan and roadmap.

## Project layout

- `lib/screens/` — top-level app screens
- `lib/widgets/` — reusable UI components
- `lib/services/` — device/platform integrations: `profile_service.dart` (saves the climber profile on the device) and `pose_service.dart` (ML Kit pose detection on camera frames). The camera UI lives in `lib/screens/camera_screen.dart`.
- `lib/models/` — data models
- `lib/state/` — app state management

## Getting started

```
flutter pub get
flutter run
```
