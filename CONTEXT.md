# Context

Living document for the current plan, architecture, and reasoning behind mitbo.ai. Update this as decisions change — this is the source of truth for "why are we building it this way," not the README.

## What the app does

Point a laptop camera at a bouldering wall. mitbo identifies the problem from where the climber's hands first touch, tracks the climber's body live, generates a beta (move sequence) tailored to their height/reach, and speaks cues via TTS as they climb (e.g. "bring your left hand up to the hold above it").

## Core technical pieces

**A. Human/pose tracking**
Track hands, feet, hips, and other joints in real time from webcam video. Considered solved / off-the-shelf — plan to use MediaPipe Pose (BlazePose) rather than building this from scratch.

**B. Problem/hold identification**
The hard part. Need to (1) detect holds on the wall via a vision model, and (2) figure out which holds belong to "this" problem — either via hold color, or by watching which holds the climber actually touches. Gyms don't reliably color-tag holds in a way that's easy to parse from a single frame, so auto-detection is deferred (see v1 scope below).

**C. Beta generation**
Not an LLM-native task. Treated as geometry/physical-constraint reasoning: a simplified body model (limb reach as a function of height/wingspan) plus hold geometry (position, type, angle) generates a plausible move sequence and flags likely cruxes. An LLM is used only downstream, to turn that structured sequence into natural spoken language — the LLM narrates, it does not decide the sequence.

**D. Text-to-speech delivery**
Spoken cues delivered during the climb. v1 is pre-generated/static narration before the climb starts; live-triggered cues come later (see FUTURE_PLANS.md).

## Design principle

Geometry/physics engine does the reasoning; the LLM does the narration. Don't ask an LLM to invent climbing beta directly — it doesn't have the spatial grounding for that. Feed it a structured move sequence and have it phrase the cues naturally.

## v1 scope (current target)

- User manually outlines/taps the holds for their problem on a captured frame (no auto route detection yet).
- Pose tracking follows the climber live via webcam.
- System generates a static beta and narrates it via TTS *before* the climb starts (no live-adjustment yet).

## Open questions / decisions to revisit

- Camera calibration: how do we map 2D wall-hold positions + a single camera angle into real-world reach distances? Likely needs a reference scale (e.g. known hold spacing, or a calibration step where the climber stands at a known distance).
- Body proportions input: ask the climber for height/wingspan directly, or estimate from pose landmarks + camera distance?
- What counts as a "crux" in the geometry model — largest reach-to-limb-length ratio? Worst hold quality combined with reach?

## Testing / data

Plan is to test on the builder's own home wall or local gym — this gives a natural, repeatable dataset (consistent hold set, consistent camera position) to iterate against before generalizing to arbitrary walls.

## Log

- 2026-09-11: Repo created, initial plan captured (v1–v3 roadmap, geometry-does-reasoning / LLM-does-narration design principle established).
