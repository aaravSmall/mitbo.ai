# mitbo

mitbo is a bouldering beta assistant: point your phone's camera at a climbing wall and it pose-tracks the climber in real time, then speaks move-by-move cues (beta) as you climb, so you get live coaching without a human spotter reading the route for you.

## Status

Flutter app targeting iOS and Android. It currently has one-time height/wingspan onboarding (saved on the device), go_router navigation, a live back-camera preview with full permission handling, and live pose tracking (ML Kit) with a skeleton overlay and smoothed hand/foot/hip keypoints for the beta engine. It detects the problem automatically: once you step out of frame it snapshots the wall, and when you settle on the start holds it reads their color and outlines every hold of that color (start holds marked S, the top hold T), with a status pill at the bottom. You confirm the holds ("Looks right"), or tap "Fix" to correct them by hand on a frozen frame; if detection fails, "Mark holds" lets you mark them yourself. Once the problem locks it plans a beta for your height and wingspan, numbers each hand move on its hold, and coaches you through it with the phone's text-to-speech: live cues move by move (with crux call-outs and off-beta replanning), or the full beta read out up front. Debug builds add a pose/holds debug chip, readout and tuning sheet via the bug icon. See the root [../CONTEXT.md](../CONTEXT.md) and [../FUTURE_PLANS.md](../FUTURE_PLANS.md) for the product plan and roadmap.

## Project layout

- `lib/screens/` — top-level app screens: onboarding, edit profile, `camera_screen.dart` (camera preview, lifecycle, problem/coach wiring, the hold-marking flow, and the debug UI), and `hold_marking_screen.dart` (fixing or marking holds by hand on a frozen frame)
- `lib/widgets/` — reusable UI components: `profile_form.dart`, `pose_overlay.dart` (skeleton and smoothed-keypoint painter), `pose_mapping.dart` (pure image/normalized-to-preview coordinate mapping, both directions), `hold_overlay.dart` (problem hold outlines and beta numbers), `problem_status_pill.dart` (detection/climb status with confirm, fix, mark, reset and replay actions), and the debug-only `pose_debug_chip.dart`, `pose_debug_sheet.dart` and `problem_debug_panel.dart`
- `lib/services/` — device/platform integrations: `profile_service.dart` (saves the climber profile on the device), `pose_service.dart` (ML Kit pose detection on camera frames, model switching, keypoint smoothing, pausing), `frame_grabber.dart` (on-demand wall snapshots from the camera stream) and `beta_narrator.dart` (on-device text-to-speech for the beta)
- `lib/models/` — data models: `climber_profile.dart` and `climber_keypoints.dart` (hands/feet/hip/shoulder-center keypoints plus `KeypointSmoother`)
- `lib/holds/` — hand-marked holds: `hold.dart` and `problem.dart` (immutable models with JSON), `hold_detector.dart` (the `HoldDetector` interface, with `SegmentingHoldDetector` for "Pick problem color"), `hold_conversion.dart` (to/from the detection pipeline's boxes and HSV colors) and `hold_geometry.dart` (pure hit-testing and color sampling)
- `lib/beta/` — pure-Dart beta engine: `beta_planner.dart` (reach model, wall scale, move sequencing), `crux.dart` (per-move difficulty and the crux), `beta_tracker.dart` (following the climber through the beta from live poses) and `beta_narration.dart` (moves → spoken cues)
- `lib/vision/` — pure-Dart hold detection: `wall_frame.dart` (upright RGB snapshots from NV21/BGRA), `hold_color.dart` (HSV color sampling and matching), `hold_segmenter.dart` (color mask → hold blobs), `wall_reference.dart` (clean wall snapshot timing), `start_detector.dart` (start-position detection) and `problem_detector.dart` (start color → problem holds)
- `lib/state/` — app state management: `profile_controller.dart`, `problem_session.dart` (live problem detection state machine: scan, detect, confirm, manual override) and `climb_coach.dart` (live cues, replanning and narration)

## Getting started

```
flutter pub get
flutter run
```

Checks:

```
dart format .
flutter analyze
flutter test
```
