# Future Plans

Version roadmap for mitbo.ai, roughly in order of increasing difficulty. Each version depends on the previous being solid — don't skip ahead on the hard pieces (route detection, live conversation) before pose tracking + beta generation are working well.

## v1 — Auto color-based holds, static beta (MVP) — ✅ feature-complete in code (2026-10-04)

- ✅ **Done in code (2026-10-04):** Holds are detected automatically by color: when the climber settles on the start holds, mitbo samples their color from a clean wall reference frame and treats every same-color hold in frame as the problem. No manual hold marking, no per-climb setup. Real-device/gym validation still pending.
- ✅ **Done (2026-10-03):** Pose tracking (ML Kit pose detection, BlazePose-based) follows the climber live via the phone's back camera (phone propped up hands-free, pointed at the wall), producing smoothed hand/foot/hip keypoints for the beta engine. Real-device/gym validation still pending.
- ✅ **Done in code (2026-10-04):** System generates a beta sequence from hold geometry + climber height/reach (scaled by torso length in frame), and narrates it via on-device TTS **before** the climb starts, with replay/stop. Holds are numbered in beta order on the overlay.
- No live adjustment — the beta is generated once, spoken once.

## v2 — Live cue triggering — ✅ done in code (2026-10-05)

- ✅ Instead of narrating the full beta up front, each cue fires live: TTS speaks the next move when pose tracking sees the previous hand move land on its hold (held 300 ms). Foot moves ride along with the hand move they set up, so flaky foot tracking can't stall the cues; a two-step lookahead covers missed detections.
- ✅ Crux identification: a geometry-only difficulty score per move (span, reach above the feet, height gained, crossing, big move); the hardest move above a threshold is announced and marked amber on the overlay.
- ✅ Extra: off-beta replanning (grab a different hold → new beta from where you are), off-the-wall detection with restart from the start holds, a send call, and a live / full-beta toggle (v1 behavior kept as an option).
- Pending: `flutter analyze` / `flutter test` on a real machine, then gym testing and threshold tuning.

## v3 — Learned hold detection

- Add a learned hold detector (ML model) alongside v1's color segmentation, so holds are found reliably even when wall paint, volumes, or lighting confuse color matching.
- Path-based problem inference for gyms without clean color coding: infer which holds belong to "this" problem from the climber's actual path (which holds get touched first/in sequence).

## v4 — Live conversational feedback

- Make the system conversational: the climber can give feedback mid-climb ("that felt too far," "I want to skip this hold") and the beta updates live in response.
- The coolest feature, but explicitly deferred — it depends on v1–v3 (hold detection, pose tracking, and beta generation) being solid first.

## Other ideas (unscheduled)

- Support multiple camera angles / camera repositioning mid-session.
- Save/replay sessions to compare attempts on the same problem over time.
- Difficulty/grade estimation from the generated beta.
- Support other climbers' body types/heights on the same wall dataset (personalization beyond a single user's home wall).
