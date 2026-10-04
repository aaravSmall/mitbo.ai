# Future Plans

Version roadmap for mitbo.ai, roughly in order of increasing difficulty. Each version depends on the previous being solid — don't skip ahead on the hard pieces (route detection, live conversation) before pose tracking + beta generation are working well.

## v1 — Auto color-based holds, static beta (MVP)

- Holds are detected automatically by color: when the climber settles on the start holds, mitbo samples their color from a clean wall reference frame and treats every same-color hold in frame as the problem. No manual hold marking, no per-climb setup.
- ✅ **Done (2026-10-03):** Pose tracking (ML Kit pose detection, BlazePose-based) follows the climber live via the phone's back camera (phone propped up hands-free, pointed at the wall), producing smoothed hand/foot/hip keypoints for the beta engine. Real-device/gym validation still pending.
- System generates a beta sequence from hold geometry + climber height/reach, and narrates it via TTS **before** the climb starts.
- No live adjustment — the beta is generated once, spoken once.

## v2 — Live cue triggering

- Instead of narrating the full beta up front, fire each cue live: TTS speaks the next move when pose tracking detects the previous move has been completed (e.g. hand/foot has reached the expected hold).
- Requires reliably detecting "move completed" from pose + hold positions, including tolerance for near-misses and adjustments.
- Crux identification: flag the hardest move(s) in the sequence (approach not decided yet).

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
