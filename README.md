# mitbo.ai

An AI bouldering coach. Point a laptop camera at a climbing wall, and mitbo watches you climb — tracking your body in real time and speaking beta (move-by-move instructions) as you go.

## The idea

Bouldering problems are hard to read cold, and most climbers either guess the sequence on the wall or watch someone else's beta video. mitbo tries to generate and narrate beta live, tailored to the climber in front of the camera:

1. **See the problem.** The camera watches the wall and the climber's first moves (which holds the hands touch first) to identify the problem being attempted.
2. **Track the climber.** Pose tracking follows hands, feet, hips, and other key points in real time.
3. **Generate beta.** Given the hold layout and the climber's body proportions, mitbo works out a plausible sequence of moves — including likely cruxes — and adapts it to the climber's height/reach.
4. **Speak it.** Cues ("bring your left hand up to the hold above it") are narrated via text-to-speech as the climber climbs.

Long-term, the goal is a conversational coach: the climber can ask for adjustments or give feedback mid-climb, and the beta updates live.

## Why this is hard

This isn't a single-model problem — it's three different problems stacked on top of each other:

- **Hold/route identification** — figuring out which holds belong to "this" problem, from a single wall of mixed/unmarked holds, based on where the climber's hands actually go. This is the least solved piece.
- **Pose tracking** — tracking hands, feet, and hips in real time from a webcam. This part is largely solved off-the-shelf (e.g. MediaPipe/BlazePose).
- **Beta generation** — this is a spatial reasoning and physical-constraint problem, not something an LLM is good at on its own. It needs a body/reach model plus hold geometry to reason about sequence and crux, with an LLM used only to turn that reasoning into natural spoken language — not to do the reasoning itself.

## Status

Early planning / v1 build. See [CONTEXT.md](CONTEXT.md) for the current architecture and approach, and [FUTURE_PLANS.md](FUTURE_PLANS.md) for the version roadmap.
