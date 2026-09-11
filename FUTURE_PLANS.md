# Future Plans

Version roadmap for mitbo.ai, roughly in order of increasing difficulty. Each version depends on the previous being solid — don't skip ahead on the hard pieces (route detection, live conversation) before pose tracking + beta generation are working well.

## v1 — Manual holds, static beta (MVP)

- User captures a photo of the wall and manually taps/outlines the holds that make up their problem (no auto route detection).
- Pose tracking (MediaPipe/BlazePose) follows the climber live via webcam.
- System generates a beta sequence from hold geometry + climber height/reach, and narrates it via TTS **before** the climb starts.
- No live adjustment — the beta is generated once, spoken once.

## v2 — Live cue triggering

- Instead of narrating the full beta up front, fire each cue live: TTS speaks the next move when pose tracking detects the previous move has been completed (e.g. hand/foot has reached the expected hold).
- Requires reliably detecting "move completed" from pose + hold positions, including tolerance for near-misses and adjustments.

## v3 — Auto hold detection

- Replace manual hold-tapping with a vision model that detects all holds on the wall automatically.
- Infer which holds belong to "this" problem from the climber's actual path (which holds get touched first/in sequence), rather than relying on gym color-coding.

## v4 — Live conversational feedback

- Make the system conversational: the climber can give feedback mid-climb ("that felt too far," "I want to skip this hold") and the beta updates live in response.
- The coolest feature, but explicitly deferred — it depends on v1–v3 (hold detection, pose tracking, and beta generation) being solid first.

## Other ideas (unscheduled)

- Support multiple camera angles / camera repositioning mid-session.
- Save/replay sessions to compare attempts on the same problem over time.
- Difficulty/grade estimation from the generated beta.
- Support other climbers' body types/heights on the same wall dataset (personalization beyond a single user's home wall).
