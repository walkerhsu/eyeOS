## Inspiration
Growing up, Jason has suffered from severe meibomian gland dysfunction (dry eye) and myopia, worsening over several years directly due to excessive screen time and bad habits in front of screens. Due to this, his eyes have become highly sensitive; he must wear blue light glasses when sitting in front of a screen to prevent eye strain or twitching. His optometrist has asked him multiple times to change his screen habits, but his ambition and workload demands too much;  he just can't afford to catch a break.

As computer science students, engineers, & desk job workers constantly on computers, **we _all_ share a part of this problem**. A deadline means we're not off our screens until work is done. A hackathon is exactly that for 36 hours straight on a laptop, with 5 hours total of rest and no natural place to stop.  For students, the future looks similar, 8+ hours a day, 50 weeks a year. **This is not healthy for our eyes**, and often we're forced to ignore it.

We tried apps that already exist. They tell you to set a 20-20-20 timer and take an eye break when it rings. When work is real, everyone dismisses the reminder, and they're essentially useless.

Our app centers around one question:

**Can you work on your computer rigorously, as usual, while taking care of your eyes simultaneously?**

## What it does
eyeOS is an AI eye-habit coach that lives in your Mac's menu bar and improves how you use your eyes without ever asking you to stop working. Using the built-in camera, it catches the habits that strain your eyes, such as staring without blinking, squinting, leaning in, and rubbing your eyes, and corrects each one in the moment with a nudge small enough to work through. A persistent memory tracks which fixes actually help you and what triggers your habits, so eyeOS gets better every session and small changes compound into lasting habits.

It's for people who are on screens not by choice, but because their work demands it: students pulling all-nighters before a deadline, engineers, IT, accountants, and anyone at a desk all day. That's why our answer to the question is yes: you keep working, and your eyes still get looked after.

It starts by noticing what you don't. Through the built-in camera, eyeOS picks up habits most people never catch in themselves: blinking too little or only halfway, staring, leaning in, squinting, rubbing your eyes. Together they make up an eye score you can watch live.

When one of those habits shows up, eyeOS nudges you out of it, quietly enough that you keep working. Stare too long and the screen softens until you blink. Lean in and the edges dim until you sit back. Squint and eyeOS offers bigger text, then does it automatically once you've said yes a couple of times. Reach to rub your eyes and it offers palming instead. When more is needed, Claude picks the smallest change that should work.

Then it checks whether the nudge actually helped. eyeOS reaches for what works first, and drops what doesn't help or what you've declined. It also learns what leads up to your habits, like "most of your eye rubs come after 45 minutes without a break," so next time it can step in before they start. You can watch your progress too, like today's eye rubs against your weekly average. Every session builds on the last.

None of this should cost you focus. A model running on your Mac reads the screen to tell deep work from a good moment to pause. During deep work eyeOS goes silent but keeps measuring, then shows you a recap when you come out of it.

When it is time to rest, your eyes are closed, so Cartesia's voice talks you through the exercises. The camera follows along, so the voice responds to what you're actually doing: counting your blinks, or noticing when you peek. The same voice can read a page aloud.

Through all of it, your data stays yours. Camera frames never leave your Mac, and Claude never sees an image of you or your screen. Claude can't change anything on your Mac until you've approved it, and eyeOS never diagnoses.

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
