# mitbo

mitbo is a bouldering beta assistant: point your phone's camera at a climbing wall and it pose-tracks the climber in real time, then speaks move-by-move cues (beta) as you climb, so you get live coaching without a human spotter reading the route for you.

## Status

Flutter app targeting iOS and Android. It currently has one-time height/wingspan onboarding (saved on the device), go_router navigation, a live back-camera preview with full permission handling, and live pose tracking (ML Kit) with a skeleton overlay and smoothed hand/foot/hip keypoints for the beta engine. Debug builds add a pose debug chip and tuning sheet via the bug icon. Automatic color-based hold detection is the current milestone; beta generation and text-to-speech aren't built yet — see the root [../CONTEXT.md](../CONTEXT.md) and [../FUTURE_PLANS.md](../FUTURE_PLANS.md) for the product plan and roadmap.

## Project layout

- `lib/screens/` — top-level app screens: onboarding, edit profile, and `camera_screen.dart` (camera preview, lifecycle, and the debug UI)
- `lib/widgets/` — reusable UI components: `profile_form.dart`, `pose_overlay.dart` (skeleton and smoothed-keypoint painter), `pose_mapping.dart` (pure image-to-preview coordinate mapping), and the debug-only `pose_debug_chip.dart` and `pose_debug_sheet.dart`
- `lib/services/` — device/platform integrations: `profile_service.dart` (saves the climber profile on the device) and `pose_service.dart` (ML Kit pose detection on camera frames, model switching, keypoint smoothing)
- `lib/models/` — data models: `climber_profile.dart` and `climber_keypoints.dart` (hands/feet/hip-center keypoints plus `KeypointSmoother`)
- `lib/state/` — app state management: `profile_controller.dart`

## Getting started

```
flutter pub get
flutter run
```
