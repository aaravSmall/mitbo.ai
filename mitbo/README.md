# mitbo

mitbo is a bouldering beta assistant: point your phone's camera at a climbing wall and it pose-tracks the climber in real time, then speaks move-by-move cues (beta) as you climb, so you get live coaching without a human spotter reading the route for you.

## Status

Flutter app targeting iOS and Android. It currently has one-time height/wingspan onboarding (saved on the device), go_router navigation, a live back-camera preview with full permission handling, and live pose tracking (ML Kit) with a skeleton overlay and smoothed hand/foot/hip keypoints for the beta engine. It also detects the problem automatically: once you step out of frame it snapshots the wall, and when you settle on the start holds it reads their color and outlines every hold of that color (start holds marked S, the top hold T), with a status pill at the bottom. Debug builds add a pose/holds debug chip, readout and tuning sheet via the bug icon. Beta generation and text-to-speech aren't built yet — see the root [../CONTEXT.md](../CONTEXT.md) and [../FUTURE_PLANS.md](../FUTURE_PLANS.md) for the product plan and roadmap.

## Project layout

- `lib/screens/` — top-level app screens: onboarding, edit profile, and `camera_screen.dart` (camera preview, lifecycle, and the debug UI)
- `lib/widgets/` — reusable UI components: `profile_form.dart`, `pose_overlay.dart` (skeleton and smoothed-keypoint painter), `pose_mapping.dart` (pure image-to-preview coordinate mapping), `hold_overlay.dart` (problem hold outlines), `problem_status_pill.dart` (detection status + reset), and the debug-only `pose_debug_chip.dart`, `pose_debug_sheet.dart` and `problem_debug_panel.dart`
- `lib/services/` — device/platform integrations: `profile_service.dart` (saves the climber profile on the device), `pose_service.dart` (ML Kit pose detection on camera frames, model switching, keypoint smoothing) and `frame_grabber.dart` (on-demand wall snapshots from the camera stream)
- `lib/models/` — data models: `climber_profile.dart` and `climber_keypoints.dart` (hands/feet/hip-center keypoints plus `KeypointSmoother`)
- `lib/vision/` — pure-Dart hold detection: `wall_frame.dart` (upright RGB snapshots from NV21/BGRA), `hold_color.dart` (HSV color sampling and matching), `hold_segmenter.dart` (color mask → hold blobs), `wall_reference.dart` (clean wall snapshot timing), `start_detector.dart` (start-position detection) and `problem_detector.dart` (start color → problem holds)
- `lib/state/` — app state management: `profile_controller.dart` and `problem_session.dart` (live problem detection state machine)

## Getting started

```
flutter pub get
flutter run
```
