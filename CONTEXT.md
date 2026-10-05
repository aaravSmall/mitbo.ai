# Context

Living document for the current plan, architecture, and reasoning behind mitbo.ai. Update this as decisions change — this is the source of truth for "why are we building it this way," not the README.

## What the app does

A phone app (iOS + Android): prop the phone up hands-free with the back camera pointed at a bouldering wall. mitbo identifies the problem from where the climber's hands first touch, tracks the climber's body live, generates a beta (move sequence) tailored to their height/reach, and speaks cues via TTS as they climb (e.g. "bring your left hand up to the hold above it").

## Core technical pieces

**A. Human/pose tracking**
Track hands, feet, hips, and other joints in real time from the phone's back-camera video. Considered solved / off-the-shelf. Implemented with Google ML Kit pose detection (BlazePose-based, 33 landmarks) via `google_mlkit_pose_detection`, rather than building this from scratch. Raw landmarks are reduced to the points the beta engine needs — left/right hand, left/right foot, hip center — normalized to 0–1 and smoothed per point (`ClimberKeypoints` / `KeypointSmoother`).

**B. Problem/hold identification**
Automatic by default in v1 — no per-climb setup screen (point the camera and go). The user confirms the detected holds with one tap; marking holds by hand is only the fallback, for when detection is wrong or fails. Gym problems are color-coded, so the problem is identified by color: when the climber's hands first settle on the start holds, mitbo samples the hold color under them, and every hold of that color in frame is treated as part of the problem.

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
Narration is a separate layer (`beta_narration.dart`) that only phrases the planned moves. It uses plain templates (offline, predictable); an LLM can replace that layer later without touching the planner.

*Crux (v2, `lib/beta/crux.dart`):* every hand move gets a geometry-only difficulty score: hand span past 60% of max span, reach above the higher foot past 75% of max reach, height gained past 1.1× the ideal gain (half weight), crossing the other hand (+0.3), big move (+1). The hardest move scoring ≥ 0.6 is the crux (`BetaPlan.cruxMove`); below that, no move stands out and none is flagged. Narration names it ("The crux is move 4.", "Crux. Right hand…") and the overlay colors its number amber. Hold quality isn't part of it yet (holds are just blobs, so there's no jug-vs-crimp information until v3).

**D. Text-to-speech delivery**
Spoken cues via the phone's built-in, on-device TTS (`flutter_tts`). Two modes, toggled from the app bar (`ClimbCoach.mode`):
- *Live cues* (v2, default): when the problem locks, mitbo says the intro and the first move; after that, each cue is spoken the moment the previous move is done. The speaker button repeats the current cue.
- *Full beta* (v1): the whole beta is read once when the problem locks, with replay/stop.

**E. Live move tracking (v2)**
`BetaTracker` (`lib/beta/beta_tracker.dart`, pure logic with injected time) follows the climber through the plan from the smoothed pose stream; `ClimbCoach` (`lib/state/climb_coach.dart`) wires it to the session, the narrator and the UI.
- *Steps:* the plan is grouped into one step per hand move, with any foot moves folded into the hand move they set up ("Left foot up onto the next foothold. Then right hand up to the next hold."). Feet track poorly on a wall (small, hidden, smearing), so they never block progress — only hand landings do.
- *Move done:* the step's hand stays on its target hold (hold box + 0.03 margin) for 300 ms. Landings are checked against the current step and the next one, so one missed detection doesn't stall the cues (the skipped step is assumed done).
- *Off-beta:* a hand staying 800 ms on a problem hold the beta didn't plan for (not lower than where it should be, so dropping a hand to chalk past a low hold doesn't count) → replan from the holds the climber is on, keeping the original wall scale, and say "New beta from here."
- *Off the wall:* both hands out of sight 2.5 s, or both below the start holds for 1 s → "Off the wall…". Both hands back on the start holds for 1 s → "From the start." and the original beta restarts.
- *Waiting for the start:* when the beta comes from a tap on the phone (**Looks right**, or finishing a **Fix**), the climber is at the phone, not on the wall. The coach says the intro and "Get on the start holds when you're ready.", ignores off-wall checks, and gives the first move once both hands sit on the start holds for 1 s. When the beta is planned from the climber settling on the start (holds marked before the start was known), coaching starts right away. (`ProblemSession.lockedByTap`, `ClimbState.waitingForStart`.)
- *Send:* the final match lands → "Nice send!". The status pill shows progress ("move 3 of 6", "sent!"), and the overlay rings the next hold in green.

## Design principle

Geometry/physics engine does the reasoning; the LLM does the narration. Don't ask an LLM to invent climbing beta directly — it doesn't have the spatial grounding for that. Feed it a structured move sequence and have it phrase the cues naturally.

## v1 scope (current target)

- Automatic, color-based hold detection: the problem is identified from the color of the start holds the climber's hands settle on (see B above). The user confirms the detected holds before the beta is planned; if they're wrong, or detection fails, the holds can be marked by hand on a frozen frame instead. **Done in code** (auto: 2026-10-04; confirm + manual fallback: 2026-10-05); not yet run on a device or at the gym.
- Pose tracking follows the climber live via the phone's back camera. **Done in code** (2026-10-03); real-device and gym testing pending.
- System generates a static beta and narrates it via TTS *before* the climb starts (no live-adjustment yet). **Done in code** (2026-10-04).

**v1 is feature-complete in code.** Remaining before calling it shipped: compile/test on a real machine (`flutter analyze`, `flutter test`), then the gym test checklist below.

## Open questions / decisions to revisit

- ~~Camera calibration~~ — v1 answer: the climber's torso length in frame sets the scale (see C). Assumes the wall is roughly flat and facing the camera; steep angles or overhangs will distort distances.
- ~~Body proportions input~~ — v1 answer: ask once in onboarding (height/wingspan), editable later.
- ~~What counts as a "crux"~~ — v2 answer: the hardest move by a geometry-only difficulty score (span, reach above feet, gain, crossing, big move), if it clears a threshold (see C). Hold quality joins the score once v3 can tell hold types apart.
- Live tracking thresholds (300 ms settle, 800 ms off-beta, 2.5 s lost hands) are first guesses — tune at the gym.
- Telling holds apart from wall paint, volumes, and other features of a similar color — size/shape filtering is the v1 answer; a learned hold detector is the v3 answer.

## Hold detection defaults

Starting values, all tunable from the debug sheet or in code (`SegmentationParams`, `ColorTolerance`, `StartDetector`, `WallReferenceTracker`):

- Wall snapshot: 320 px wide (upright), taken after 1 s with nobody detected, refreshed every 5 s while clear.
- Start: both hands visible, above the hip center (if visible), within 0.025 (normalized) of where they settled for 1.2 s; jumps > 0.15 between frames restart the timer; hands within 0.04 = matched start.
- Color sample: center-weighted disc of radius 3% of frame width; 36-bin hue histogram, best 3-bin window must hold ≥ 12% of the weight; mostly-unsaturated discs read as achromatic by brightness.
- Matching: hue within 18°, saturation ≥ 0.25, value ≥ 0.15; achromatic: saturation < 0.25 and brightness within 0.2.
- Blobs: 3x3 open + close; keep 0.02%–5% of the frame, fill ratio ≥ 0.2, aspect ≤ 8:1.
- Start holds: hold box (+0.02 margin) under each hand, else nearest within 0.06.

## v2 scope

- Live cue triggering: each cue fires when pose tracking sees the previous move done. **Done in code** (2026-10-05, `v2-live-cues` branch).
- Crux identification. **Done in code** (2026-10-05).
- Beyond the roadmap: off-beta replanning, off-the-wall/restart handling, and a live/full-beta toggle. **Done in code** (2026-10-05).

Not compiled in the authoring workspace (no Flutter SDK there) — run `flutter pub get && flutter analyze && flutter test` before merging.

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
- [ ] Live cues (v2): does each cue fire within ~0.5 s of landing the previous hold, and *not* when a hand brushes past one? Does TTS latency feel OK mid-move?
- [ ] Off-beta: grab a different hold on purpose — does it replan within ~1 s? Any false replans from chalking up, shaking out, or L/R hand swaps in ML Kit?
- [ ] Off the wall: drop off mid-problem and after the send — is it noticed, and does getting back on the start restart cleanly?
- [ ] Crux: does the flagged move match where you actually struggle? Note problems where it's wrong.

## Testing / data

Plan is to test on the builder's own home wall or local gym — this gives a natural, repeatable dataset (consistent hold set, consistent camera position) to iterate against before generalizing to arbitrary walls.

## Log

- 2026-09-11: Repo created, initial plan captured (v1–v3 roadmap, geometry-does-reasoning / LLM-does-narration design principle established).
- 2026-10-03: Platform decided: v1 is a phone app (iOS + Android) using the back camera, propped up hands-free and pointed at the wall — not a laptop webcam app. Docs updated to match. Next step: pose tracking on top of the existing camera preview.
- 2026-10-03: Pose tracking milestone done in code. ML Kit pose detection (stream mode) runs on the back-camera stream with a skeleton overlay; `ClimberKeypoints` turns each pose into smoothed, normalized hands/feet/hip-center points with confidences for the beta engine. Debug-only tools (debug builds only, compiled out of release): FPS/landmark chip, smoothed-keypoint view, base/accurate model switch, live alpha and hand-nudge sliders. iOS camera permission fixed (Podfile `PERMISSION_CAMERA=1`). Verified on one Android phone (33 landmarks detected); overlay alignment, the keypoints/debug tools, iOS on a real device, and testing at the gym/home wall are still pending. Next: manual hold marking on a captured frame.
- 2026-10-03: Manual hold marking done in code (local branch, before the automatic pipeline landed): tap-to-add, select, resize and delete holds on a frozen frame, "Pick problem color", immutable `Hold`/`Problem` models with JSON in `lib/holds/`, and a `HoldDetector` seam. Merged on 2026-10-05 as the fallback/correction path for automatic detection (see that entry); its own frame capture/conversion was dropped in favor of `FrameGrabber`/`WallFrame`.
- 2026-10-04: Hold identification decided: v1 is fully automatic and color-based (no manual tapping). Color is sampled from a clean wall reference frame at the start holds; all same-color holds in frame form the problem. Crux identification moved to v2. Docs updated to match.
- 2026-10-04: Hold detection milestone done in code (on the `hold-detection` branch; not compiled in the workspace that wrote it, so `flutter analyze` / `flutter test` must be run before merging). Pipeline: `FrameGrabber` hands out upright 320 px `WallFrame` snapshots on demand (no per-frame cost otherwise); `WallReferenceTracker` keeps a clean wall snapshot while nobody is in frame; `StartDetector` fires when both hands settle above the hips for 1.2 s; `detectProblem` samples the start-hold color from the snapshot and segments every same-color hold (HSV mask, open/close, connected components, size/shape filters), running in an isolate. `ProblemSession` drives it live; `HoldOverlay` outlines the holds (S = start, T = top) and a status pill shows progress with Reset. Debug: wall reference thumbnail, sampled HSV readout, hue-tolerance/min-saturation sliders. Next: run the gym test checklist above, then the beta engine.
- 2026-10-04: Beta engine and TTS done in code — v1 feature-complete. `planBeta` sequences moves from hold geometry + a height/wingspan reach model, scaled by torso length in frame; `betaCues` phrases them ("Left hand up to the hold above your right hand."); `BetaNarrator` reads them with on-device TTS as soon as the problem locks, with replay/stop on the status pill, and the overlay numbers each hand move on its hold. Not compiled in the authoring workspace — run `flutter pub get && flutter analyze && flutter test` before merging.
- 2026-10-05: v2 done in code on the `v2-live-cues` branch. Crux identification (geometry-only difficulty score per move, hardest above threshold flagged, announced and colored on the overlay). Live cue triggering via `BetaTracker` + `ClimbCoach`: one cue per hand move (foot moves folded in), spoken when the previous hand lands on its target; lookahead for missed detections; off-beta replanning from the climber's current holds; off-the-wall detection and restart from the start holds; "Nice send!". App bar toggle between live cues and the v1 full readout. Not compiled in the authoring workspace — run analyze/test before merging, then the v2 items on the gym checklist.
- 2026-10-05: Merged the local manual-marking work with `main` (hold detection, beta engine, v2) and fixed the conflicts; `flutter analyze` and `flutter test` are clean (234 tests). Decision: automatic detection stays the default, but the user now **confirms** the detected holds before anything is planned or spoken — new `ProblemPhase.confirming`, "Looks right" / "Fix" on the status pill. "Fix" opens the hold marking screen pre-filled with the detected holds; when detection fails (or the wall scan stalls) the pill offers "Mark holds" instead. Hand-marked holds replace detection (`ProblemSession.applyManualProblem`): with a known start they lock and plan immediately, otherwise the session waits for the climber to settle on the start holds and plans from there without running detection; segmentation tuning never re-detects over them. Marking reuses `FrameGrabber`/`WallFrame` (a second, 720 px grabber for a sharp frozen frame, falling back to the wall reference), pauses pose detection instead of restarting the camera (a restart would clear the problem), and "Pick problem color" now runs the real color segmenter (`SegmentingHoldDetector`). Holds with no known color use `HoldColor.unknown` ("Your problem", spoken as "Got it"). Also fixed a compile error on `main` (`hold_segmenter_test.dart` used an undefined `_Wall` type), so `main`'s test suite had not actually been passing. Merged branches `hold-detection` and `v2-live-cues` deleted. Still nothing run on a real device: the confirm/fix flow and manual marking need the gym checklist too.
- 2026-10-05: Coaching waits for the climber after a tap: confirming the detected holds or finishing a fix happens at the phone, so the coach now says "Get on the start holds when you're ready" and cues the first move once the climber is back on the start (instead of cueing straight away and then calling them off the wall). Not compiled in the authoring workspace — run analyze/test.
