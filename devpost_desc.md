## Inspiration
Growing up, Jason has suffered from severe meibomian gland dysfunction (dry eye) and myopia, worsening over several years directly due to excessive screen time and bad habits in front of screens. Due to this, his eyes have become highly sensitive; he must wear blue light glasses when sitting in front of a screen to prevent eye strain or twitching. His optometrist has asked him multiple times to change his screen habits, but his ambition and workload demands too much;  he just can't afford to catch a break.

As computer science students, engineers, workers constantly on computers, we all share a part of this problem. A deadline means we're not off our screens until work is done. A hackathon is exactly that for 36 hours straight on a laptop, with 5 hours total of rest and no natural place to stop.  For students, the future looks similar, 8+ hours a day, 50 weeks a year.

We tried apps that already exist. They tell you to set a 20-20-20 timer and take an eye break when it rings. When work is real, everyone dismisses the reminder, and they're essentially useless.

Our app centers around one question:

**Can you work on your computer rigorously, as usual, while taking care of your eyes simultaneously?**

## What it does
eyeOS is for computer science students in deadline week, and for hackathon teams in the 24-hour version of that week. The community is people who do their real work in one long session at a MacBook, with a clock on the other end.

The name is literal. An operating system schedules work and manages resources. eyeOS schedules rests and breaks, and it manages the machine those eyes are using: brightness, dark mode, contrast.

It lives in the menu bar. The built-in camera and MediaPipe turn each frame into signals: blink rate, incomplete blinks, distance from the screen, posture across the shoulders, eye rubs, yawns, sitting too close, and a dark room against a bright display. Those signals roll up into an eye score you can watch live.

A local vision model, Gemma 4 on Ollama, checks one screenshot every 30 seconds. It works out what you are doing and whether you can be interrupted. In deep work it enters Zen. Measuring continues. Nudges wait. When Zen ends, a recap card shows what your eyes did while eyeOS stayed silent: blink rate, rubs, time spent too close, posture, and the alerts it held.

When a nudge is worth it, Claude Sonnet 5.5 picks the smallest useful action. It can change the Mac, or it can ask you to rest. Rest is spoken. Palming, a focus shift, and deliberate blinks are guided by Cartesia Sonic, because your eyes are covered or turned away and a card on the screen is the wrong interface. The same voice can read the page aloud, so you can look up and still finish the paragraph.

Every Claude action passes a code-enforced approval check. The first time a tool wants to change a setting, you allow it. After that, feedback becomes memory. A longer rest after a long session. Brightness, if that helps you more than another 20-20-20. Declines are saved too. When the display turns off, a reflection pass reviews the stretch and writes a few rules for the next one. The Log page keeps the runs, the actions, and a daily summary. Later runs can see whether an action actually moved blink rate or the eye score.

Camera frames never leave the Mac. Screenshots are captured into memory, shown only to the local model, and wiped after each check. Claude receives numbers, the app name, a short note from the conductor, and your saved rules. No images, no window titles, no page text.

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