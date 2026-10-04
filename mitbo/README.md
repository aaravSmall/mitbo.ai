# mitbo

mitbo is a bouldering beta assistant: point your phone's camera at a climbing wall and it pose-tracks the climber in real time, then speaks move-by-move cues (beta) as you climb, so you get live coaching without a human spotter reading the route for you.

## Status

Flutter app targeting iOS and Android. It currently has one-time height/wingspan onboarding (saved on the device), go_router navigation, a live back-camera preview with full permission handling, live pose tracking (ML Kit) with a skeleton overlay and smoothed hand/foot/hip keypoints for the beta engine, and manual hold marking on a captured frame (with the marked holds drawn on the live view). Debug builds add a pose debug chip and tuning sheet via the bug icon. Automatic hold detection, beta generation, and text-to-speech aren't built yet — see the root [../CONTEXT.md](../CONTEXT.md) and [../FUTURE_PLANS.md](../FUTURE_PLANS.md) for the product plan and roadmap.

## Project layout

- `lib/screens/` — top-level app screens: onboarding, edit profile, `camera_screen.dart` (camera preview, lifecycle, the "Mark holds" flow, and the debug UI), and `hold_marking_screen.dart` (marking holds on a frozen frame)
- `lib/holds/` — hold marking: `hold.dart` and `problem.dart` (immutable models with JSON), `hold_detector.dart` (the `HoldDetector` interface auto-detection plugs into, plus the placeholder `NoopHoldDetector`), and `hold_geometry.dart` (pure hit-testing and color sampling)
- `lib/widgets/` — reusable UI components: `profile_form.dart`, `pose_overlay.dart` (skeleton and smoothed-keypoint painter), `holds_overlay.dart` (hold circles painter), `pose_mapping.dart` (pure image/normalized-to-preview coordinate mapping, both directions), and the debug-only `pose_debug_chip.dart` and `pose_debug_sheet.dart`
- `lib/services/` — device/platform integrations: `profile_service.dart` (saves the climber profile on the device), `pose_service.dart` (ML Kit pose detection on camera frames, model switching, keypoint smoothing, frame capture), and `frame_converter.dart` (pure NV21/BGRA-to-upright-RGBA conversion)
- `lib/models/` — data models: `climber_profile.dart`, `climber_keypoints.dart` (hands/feet/hip-center keypoints plus `KeypointSmoother`), and `captured_frame.dart` (an upright RGBA frame)
- `lib/state/` — app state management: `profile_controller.dart`

## Getting started

```
flutter pub get
flutter run
```
