# Context

Living document for the current plan, architecture, and reasoning behind mitbo.ai. Update this as decisions change — this is the source of truth for "why are we building it this way," not the README.

## What the app does

A phone app (iOS + Android): prop the phone up hands-free with the back camera pointed at a bouldering wall. mitbo identifies the problem from where the climber's hands first touch, tracks the climber's body live, generates a beta (move sequence) tailored to their height/reach, and speaks cues via TTS as they climb (e.g. "bring your left hand up to the hold above it").

## Core technical pieces

**A. Human/pose tracking**
Track hands, feet, hips, and other joints in real time from the phone's back-camera video. Considered solved / off-the-shelf. Implemented with Google ML Kit pose detection (BlazePose-based, 33 landmarks) via `google_mlkit_pose_detection`, rather than building this from scratch. Raw landmarks are reduced to the points the beta engine needs — left/right hand, left/right foot, hip center — normalized to 0–1 and smoothed per point (`ClimberKeypoints` / `KeypointSmoother`).

**B. Problem/hold identification**
Fully automatic in v1 — no manual tapping or outlining, and no per-climb setup screen (point the camera and go). Gym problems are color-coded, so the problem is identified by color: when the climber's hands first settle on the start holds, mitbo samples the hold color under them, and every hold of that color in frame is treated as part of the problem.

The color is sampled from a clean **wall reference frame** captured while nobody is in frame — not from the live frame, because at the moment of touching, the climber's hand is covering the hold.

*Hold detection pipeline:*
1. **Wall reference** — while no person is detected for ~1 s, grab a downsampled upright RGB snapshot of the wall; refresh it every few seconds while the wall stays clear.
2. **Start detection** — both hands visible and still for ~1.2 s = the climber is on the start holds.
3. **Color sample** — read the dominant hold color around each start hand in the reference frame (HSV; low-saturation holds are handled as "achromatic" by brightness).
4. **Color mask** — mark every reference pixel matching that color, then clean up speckle with a morphological open/close.
5. **Connected components** — group matching pixels into blobs; drop blobs too large (wall panels, volumes) or too thin (tape, edges) to be holds.
6. **Lock** — the surviving blobs are the problem, with start holds (nearest the hands) and the top hold marked.

*Known v1 limits:* white/black/gray holds (low saturation) are harder to separate from the wall; holds hidden by the climber are missed unless they were visible in the reference frame; volumes and wall paint close to the hold color can cause false positives.

**C. Beta generation**
Not an LLM-native task. Treated as geometry/physical-constraint reasoning: a simplified body model (limb reach as a function of height/wingspan) plus hold geometry generates a plausible move sequence. Implemented in `lib/beta/beta_planner.dart`:
- *Scale:* the climber's torso (shoulder center → hip center ≈ 29% of height) at the start position converts image distances to centimeters. Falls back to assuming 3.5 m of visible wall when the torso isn't measurable.
- *Reach model:* max hand span 0.9 × wingspan; max reach above the higher foot = shoulder height (0.87 × height incl. toes) + arm (wingspan/2 − 0.1 × height); ideal gain per move 0.35 × wingspan; feet stay ≥ 0.45 × height below the lower hand; high steps ≤ 0.6 × height.
- *Sequencing:* the lower hand moves to the reachable hold above it closest to the ideal gain over the other hand, penalizing crosses, stacking and near-max stretches; a foot steps up (onto a hold, or a smear) when hands run out of reach; if nothing is comfortably reachable the nearest hold above is a "big move"; finish matched on the top hold.
Narration is a separate layer (`beta_narration.dart`) that only phrases the planned moves. v1 uses plain templates (offline, predictable); an LLM can replace that layer later without touching the planner.

**D. Text-to-speech delivery**
Spoken cues via the phone's built-in, on-device TTS (`flutter_tts`). v1 reads the whole beta once, as soon as the problem locks (the climber is on the start holds), with a replay/stop button; live-triggered cues come later (see FUTURE_PLANS.md).

## Design principle

Geometry/physics engine does the reasoning; the LLM does the narration. Don't ask an LLM to invent climbing beta directly — it doesn't have the spatial grounding for that. Feed it a structured move sequence and have it phrase the cues naturally.

## v1 scope (current target)

- Automatic, color-based hold detection: the problem is identified from the color of the start holds the climber's hands settle on (see B above). No manual hold marking, no per-climb setup. **Done in code** (2026-10-04, `hold-detection` branch); not yet run on a device or at the gym.
- Pose tracking follows the climber live via the phone's back camera. **Done in code** (2026-10-03); real-device and gym testing pending.
- System generates a static beta and narrates it via TTS *before* the climb starts (no live-adjustment yet). **Done in code** (2026-10-04).

**v1 is feature-complete in code.** Remaining before calling it shipped: compile/test on a real machine (`flutter analyze`, `flutter test`), then the gym test checklist below.

## Open questions / decisions to revisit

- ~~Camera calibration~~ — v1 answer: the climber's torso length in frame sets the scale (see C). Assumes the wall is roughly flat and facing the camera; steep angles or overhangs will distort distances.
- ~~Body proportions input~~ — v1 answer: ask once in onboarding (height/wingspan), editable later.
- What counts as a "crux" in the geometry model — largest reach-to-limb-length ratio? Worst hold quality combined with reach? (Deferred to v2.)
- Telling holds apart from wall paint, volumes, and other features of a similar color — size/shape filtering is the v1 answer; a learned hold detector is the v3 answer.

## Hold detection defaults

Starting values, all tunable from the debug sheet or in code (`SegmentationParams`, `ColorTolerance`, `StartDetector`, `WallReferenceTracker`):

- Wall snapshot: 320 px wide (upright), taken after 1 s with nobody detected, refreshed every 5 s while clear.
- Start: both hands visible, above the hip center (if visible), within 0.025 (normalized) of where they settled for 1.2 s; jumps > 0.15 between frames restart the timer; hands within 0.04 = matched start.
- Color sample: center-weighted disc of radius 3% of frame width; 36-bin hue histogram, best 3-bin window must hold ≥ 12% of the weight; mostly-unsaturated discs read as achromatic by brightness.
- Matching: hue within 18°, saturation ≥ 0.25, value ≥ 0.15; achromatic: saturation < 0.25 and brightness within 0.2.
- Blobs: 3x3 open + close; keep 0.02%–5% of the frame, fill ratio ≥ 0.2, aspect ≤ 8:1.
- Start holds: hold box (+0.02 margin) under each hand, else nearest within 0.06.

## Gym test checklist

For the first session at the wall with a real phone (debug build, bug icon on, "Show wall reference" on):

- [ ] Phone placement: height and distance where the whole problem plus the climber fit; note what works.
- [ ] Wall scan: does the pill go from "Step out of frame…" to "Ready" within ~1–2 s of stepping out? Does the thumbnail look right (upright, not mirrored, whole frame)?
- [ ] Start detection: does it fire within ~1–2 s of settling on the start, and *not* while standing around or chalking up?
- [ ] Color sampling per hold color: red, orange, yellow, green, blue, purple, pink — and separately white, black, gray. Note which fail and the HSV the debug panel shows.
- [ ] False positives: volumes, wall paint, tape, other problems' holds of a similar color. Note what the hue-tolerance / min-saturation sliders fix.
- [ ] Missed holds: small feet/crimps, holds the climber blocked during the scan.
- [ ] Overlay alignment: do the outlines sit on the holds, on Android and iOS, portrait and landscape?
- [ ] Performance: pose FPS (debug chip) before vs. during scan/detection.

## Testing / data

Plan is to test on the builder's own home wall or local gym — this gives a natural, repeatable dataset (consistent hold set, consistent camera position) to iterate against before generalizing to arbitrary walls.

## Log

- 2026-09-11: Repo created, initial plan captured (v1–v3 roadmap, geometry-does-reasoning / LLM-does-narration design principle established).
- 2026-10-03: Platform decided: v1 is a phone app (iOS + Android) using the back camera, propped up hands-free and pointed at the wall — not a laptop webcam app. Docs updated to match. Next step: pose tracking on top of the existing camera preview.
- 2026-10-03: Pose tracking milestone done in code. ML Kit pose detection (stream mode) runs on the back-camera stream with a skeleton overlay; `ClimberKeypoints` turns each pose into smoothed, normalized hands/feet/hip-center points with confidences for the beta engine. Debug-only tools (debug builds only, compiled out of release): FPS/landmark chip, smoothed-keypoint view, base/accurate model switch, live alpha and hand-nudge sliders. iOS camera permission fixed (Podfile `PERMISSION_CAMERA=1`). Verified on one Android phone (33 landmarks detected); overlay alignment, the keypoints/debug tools, iOS on a real device, and testing at the gym/home wall are still pending. Next: manual hold marking on a captured frame.
- 2026-10-04: Hold identification decided: v1 is fully automatic and color-based (no manual tapping). Color is sampled from a clean wall reference frame at the start holds; all same-color holds in frame form the problem. Crux identification moved to v2. Docs updated to match.
- 2026-10-04: Hold detection milestone done in code (on the `hold-detection` branch; not compiled in the workspace that wrote it, so `flutter analyze` / `flutter test` must be run before merging). Pipeline: `FrameGrabber` hands out upright 320 px `WallFrame` snapshots on demand (no per-frame cost otherwise); `WallReferenceTracker` keeps a clean wall snapshot while nobody is in frame; `StartDetector` fires when both hands settle above the hips for 1.2 s; `detectProblem` samples the start-hold color from the snapshot and segments every same-color hold (HSV mask, open/close, connected components, size/shape filters), running in an isolate. `ProblemSession` drives it live; `HoldOverlay` outlines the holds (S = start, T = top) and a status pill shows progress with Reset. Debug: wall reference thumbnail, sampled HSV readout, hue-tolerance/min-saturation sliders. Next: run the gym test checklist above, then the beta engine.
- 2026-10-04: Beta engine and TTS done in code — v1 feature-complete. `planBeta` sequences moves from hold geometry + a height/wingspan reach model, scaled by torso length in frame; `betaCues` phrases them ("Left hand up to the hold above your right hand."); `BetaNarrator` reads them with on-device TTS as soon as the problem locks, with replay/stop on the status pill, and the overlay numbers each hand move on its hold. Not compiled in the authoring workspace — run `flutter pub get && flutter analyze && flutter test` before merging.
