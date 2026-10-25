## Inspiration
Growing up, Jason has suffered from severe meibomian gland dysfunction (dry eye) and myopia, worsening over several years directly due to excessive screen time and bad habits in front of screens. Due to this, his eyes have become highly sensitive; he must wear blue light glasses when sitting in front of a screen to prevent eye strain or twitching. His optometrist has asked him multiple times to change his screen habits, but his ambition and workload demands too much;  he just can't afford to catch a break.

As computer science students, engineers, & desk job workers constantly on computers, **we _all_ share a part of this problem**. A deadline means we're not off our screens until work is done. A hackathon is exactly that for 36 hours straight on a laptop, with 5 hours total of rest and no natural place to stop.  For students, the future looks similar, 8+ hours a day, 50 weeks a year. **This is not healthy for our eyes**, and often we're forced to ignore it.

We tried apps that already exist. They tell you to set a 20-20-20 timer and take an eye break when it rings. When work is real, everyone dismisses the reminder, and they're essentially useless.

Our app centers around one question:

**Can you work on your computer rigorously, as usual, while taking care of your eyes simultaneously?**

## What it does
eyeOS is for computer science students in deadline week, and for hackathon teams in the 36-hour version of that week: one long session at a MacBook, with a clock on the other end.

Our answer to that question is yes. eyeOS never asks you to stop working. It changes your screen habits one small step at a time while you work, remembers what actually works for you, and builds on it every session. Small fixes that stick add up to better habits for the long run, and you stay locked in the whole time.

The name is literal. An operating system schedules work and manages resources. eyeOS schedules rest, and manages the machine your eyes are using.

**It notices the habits you don't.** eyeOS lives in the menu bar. The built-in camera and MediaPipe turn every frame into signals, measured against your own calibrated baseline: blink rate, half blinks, long stares, how close you sit, posture, squinting, yawns, a bright screen in a dark room, and hands reaching for your eyes. They roll up into an eye score you can watch live.

**Small steps, right where you work.** Each fix is small enough that you keep working through it:
- Stare without blinking and the screen slowly softens. A full blink clears it at once. A half blink only clears half, so over time you learn to blink fully.
- Lean in for too long and the screen edges dim until you sit back.
- Squint at small text and one tap makes it bigger. Say yes twice in an app and it does it on its own.
- Reach to rub your eyes and a soft tone sounds within a fraction of a second, followed by an offer to swap the rub for 20 seconds of palming: the same relief, without the pressure.

When something bigger is needed, Claude Sonnet 5.5 picks the smallest action that should work: dim the display a step, switch to dark mode, enlarge the text, cue a blink, or suggest a real break.

**A memory that compounds.** Every action is scored by the camera. eyeOS compares your blink rate, distance or squinting before and after the action to see whether it helped. Actions that help become rules, like "Enlarging text tends to help this user: a good first choice." Actions that don't help stop being chosen. When you decline something, eyeOS remembers and stops offering it. Every eye rub saves what led up to it, and once a pattern is clear it becomes a rule, like "Most of this user's eye rubs come after 45+ min without a real break." The next session offers that break before the urge arrives. When the display turns off, a reflection pass reviews the stretch by hour and by activity, writes new rules for next time, and suggests one small thing for you to try. Rules update as the evidence changes, and you can read or delete any of them. The Today panel shows your eye rubs against your 7-day average, and the daily summary tells you what helped most.

**It locks in when you do.** Every 30 seconds, a local vision model (Gemma 4 on Ollama) looks at a screenshot and works out what you are doing and whether you can be interrupted. In deep work it enters Zen: measuring continues, the habit coach keeps counting, and every nudge waits. When Zen ends, a recap shows what your eyes did while eyeOS stayed silent: blink rate, rubs, time too close, posture drift, and the alerts it held back.

**Rest you can do with your eyes closed.** When rest is the right call, eyeOS talks you through it, because your eyes are covered or looking away and a card on the screen is the wrong interface. Cartesia Sonic guides palming, deliberate blinks, focus shifts, and a follow-the-dot drill, while the camera checks each one. It counts your full blinks out loud, calls out half ones, and notices if you peek. The same voice can read a page aloud, or a summary written on your Mac, so you can rest your eyes and still finish reading.

**Private and careful by design.** Camera frames never leave the Mac. Screenshots are held in memory, shown only to the local model, and wiped after each check. Claude receives numbers, the app name, a short note from the local model, and your rules. It never gets a camera frame, a screenshot, or the page you're reading. Every action Claude takes passes an approval check written in code: you approve each kind of change before it first runs, you can block any tool, and no action runs more than three times an hour. eyeOS never diagnoses. Only when a strain pattern shows up on 3 of the last 7 days does it suggest mentioning it to an optometrist.

## How we built it
The app is SwiftUI: Live, Log, Settings, and a menu bar extra. On launch it starts a Python sidecar and talks to it over a token-authenticated WebSocket bound to localhost.

The sidecar is the on-device half. OpenCV takes the camera. MediaPipe Face, Hand, and Pose landmarks feed a metrics engine. Triggers are ordinary code, so a model is only woken when something changed. Gemma 4 is the conductor. Every 30 seconds it reads the screenshot and the metrics and returns the activity, the focus, and whether a nudge may fire. Zen is that decision, with timing checks as guard rails so a meeting or a real break ends the silence.

The cloud half is the Claude Agent SDK, on Claude Sonnet 5.5. It sees the numbers and the rules, then calls tools. Brightness and dark mode go through macOS. Contrast and related display toggles go through Shortcuts, because direct defaults writes are blocked on current macOS. Overlays and the exercise screen are Swift. Cartesia Sonic 3 speaks the exercise and the read-aloud. Speech is cached as WAV and played locally, and if you stop the exercise early the voice stops with it. Codex can drive the same tools through the same approval gate. This demo uses Claude.

A phone reminder and a Chrome extension were the wrong shape. The work is on the MacBook, and the useful actions are operating-system actions. We also left multi-device health sync out of this build. The iPhone Health app cannot see these eye signals yet.

Source: https://github.com/walkerhsu/eyeOS

## Challenges we ran into
The longest stretch was deciding what to build. A timer is a weekend project. A coach that can tell a meeting from a coding block is an architecture.

We split the agents by what they are allowed to see. Detection and the conductor stay on the machine, because they see the camera and the screen. Claude stays in the cloud and only receives what a language model needs to choose an action. Designing that handoff, including a screen recording path for the local model and a hard stop before any image reaches Claude, was the core technical problem.

Zen was the product argument in code. If eyeOS talks over a deadline, it is the timer we were trying to replace. The conductor has to be willing to do nothing, and then explain, in the recap, what it held back.

The app had to be something we would leave running: a live eye score, a log of every agent decision, and settings that make the camera, the screen recording, and the keys understandable. That interface took as long as the models.

## Accomplishments that we're proud of
The orchestration. eyeOS measures, waits for a moment when you can be interrupted, and then either changes the Mac or talks you through a rest. The help is an action, tied to the index that fired it.

The memory. Preferences come from what you allow, what you decline, and what actually helps. The next session already knows the difference.

The system actions. Blink rate, distance, posture, a rub, a yawn, a bright screen in a dark room: each one can become a concrete change on the computer, and the outcome is checked so a useless action is not repeated out of habit.

## What we learned
A private model and a public model can share one product, if each one only sees what it needs. Gemma 4 sees the screen. Claude never does.

Solve a problem people already have. We did not need to invent eye strain. We needed a coach for the hour when a timer is going to be dismissed.

## What's next for eyeOS
The Mac is the first screen, not the only one. A lot of this work also happens on a phone. Next is more than one device recording the same session, and a phone version for the hours the laptop is closed, so these signals are not trapped inside one app.

The other path runs through people who do this clinically. Reading the eye score, the blink rate, and the session history with an eye doctor or a specialist is the step that takes eyeOS from a coach for deadline week to something a clinician could stand behind.