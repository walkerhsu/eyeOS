## Inspiration
Computer vision syndrome (CVS), or digital eye strain, is the dry, tired, blurry-eyed feeling after hours at a screen. It affects an estimated 50–90% of people who work at computers, and the standard advice is always the same: blink more, sit back, take breaks. That advice rarely survives a deadline.

Jason knows this firsthand. He has severe meibomian gland dysfunction (dry eye) and myopia, both worsened by years of heavy screen time and bad screen habits. His eyes are now so sensitive that he needs blue light glasses at a screen to avoid strain and twitching. His optometrist keeps telling him to change his habits, but his workload won't let him take a break.

We wanted to build something for people who are on screens not by choice, but because their work demands it: students pulling all-nighters, engineers, IT, accountants, and anyone at a desk all day. That even includes us: a hackathon is 36 hours on a laptop with about 5 hours of rest, and the careers ahead look similar, 8+ hours a day, 50 weeks a year. So every fix had to work along with your focus, not against it with unwanted interruptions.

We tried apps that already exist. They tell you to set a 20-20-20 timer and take an eye break when it rings. When work is real, everyone dismisses the reminder, and they're essentially useless.

Our app centers around one question:

**Can you work on your computer rigorously, as usual, while taking care of your eyes simultaneously?**

Our answer is yes!

## What it does

eyeOS is an AI eye-habit coach in your Mac's menu bar. Through your laptop camera it monitors physical habits that are clinically known to negatively affect eye health, including staring, squinting, bad posture, and eye rubbing, and fixes each one in the moment without breaking your focus: the screen softens until you blink, the edges dim until you sit back, text gets bigger when you squint, and palming replaces rubbing. It goes silent during deep work and saves breaks for natural pauses, when a Cartesia voice guides eye exercises the camera checks. Every nudge is measured, so eyeOS keeps what works, learns what triggers your habits, and steps in before they start. Camera frames never leave your Mac, Claude never sees an image of you or your screen, and nothing changes without your approval.

**Key features**

We followed three design principles: **unobtrusive**, **adaptive**, and **transparent**.

*Watches*
- **Habit detection:** catches common habits that affect eye health, including staring without blinking, squinting, bad posture, and eye rubbing through your laptop camera.
- **Live eye score:** blink rate, half blinks, staring, drowsiness, distance, squinting, and time since your last break, rolled into one 0–100 score.

*Nudges at the right moment*
- **In-the-moment nudges:** the screen softens until you blink, edges dim until you sit back, bigger text when you squint, and palming instead of rubbing. When more is needed, Claude can adjust brightness, dark mode, contrast, or Do Not Disturb.
- **Zen mode and smart timing:** reads how interruptible you are and saves breaks for natural pauses. During deep work it goes silent, keeps measuring, and shows a recap afterward.

*Helps you rest*
- **Guided eye exercises:** a Cartesia voice talks you through various exercises while watching you and making sure you're doing the exercises correctly.
- **Read aloud:** Cartesia reads the current page or your selection aloud so your eyes can rest.

*Learns what works*
- **Learning memory:** checks every nudge against what your eyes did next, favors what works, and learns your triggers to step in early. A reflection pass turns each stretch of use into new rules.
- **Progress tracking:** compare today's habits to your weekly average, or get a daily summary in plain words.

*Shows its work*
- **Menu bar and HUD:** a minimal menu bar popover shows how you're doing at a glance, with one-click breaks and exercises. A small floating HUD stays faint while you're fine, brightens when something drifts, and hides during Zen, meetings, and calls.
- **Full transparency:** the dashboard shows what the camera tracks (face mesh, gaze, head pose, posture), live graphs of every metric, and every agent decision with its reasoning, its actions, and whether they helped. Hover any number to see how it's calculated.

*Respects you*
- **You're in control:** eyeOS asks before using each new kind of action, and you can allow it, decline it, or block it for good. Pause anytime, and pick your model: Claude, Codex, or a local one.
- **Private by design:** camera frames never leave your Mac, and Claude never sees an image of you or your screen.

## How we built it
**Mac app**
- **SwiftUI:** Live, Log, and Settings views, a menu bar extra, overlays, and the exercise screen.
- **Python sidecar:** connected over a token-authenticated WebSocket bound to localhost.

**On-device**
- **OpenCV:** camera capture.
- **MediaPipe Face, Hand, and Pose:** landmarks that feed the metrics engine.
- **Gemma 4:** the conductor. Every 30 seconds it reads the screen and metrics to decide your activity, your focus, and whether a nudge may fire, which is how Zen works.

**Cloud**
- **Claude Agent SDK on Claude Sonnet 5.5:** sees only the metrics and rules, then calls tools through an approval gate. Codex can drive the same tools.
- **Cartesia Sonic 3:** voices the exercises and read-aloud, cached locally as WAV.

**System actions**
- **macOS:** brightness and dark mode.
- **Shortcuts:** contrast and display toggles, since direct `defaults` writes are blocked on current macOS.

Source: https://github.com/walkerhsu/eyeOS

## Challenges we ran into
- **Deciding what to build:** the longest stretch. A timer is a weekend project; a coach that can tell a meeting from a coding block is an architecture.
- **Splitting the agents by what they can see:** detection and the conductor stay on the Mac because they see the camera and the screen. Claude stays in the cloud and only gets what it needs to choose an action. Designing that handoff, including a screen recording path for the local model and a hard stop before any image reaches Claude, was the core technical problem.
- **Knowing when to stay quiet:** if eyeOS talks over a deadline, it's the timer we were trying to replace. The conductor has to be willing to do nothing, then explain in the Zen recap what it held back.
- **Building an app we'd leave running:** a live eye score, a log of every agent decision, and settings that make the camera, screen recording, and keys understandable. The interface took as long as the models.

## Accomplishments that we're proud of
- **The orchestration:** eyeOS measures, waits for a moment when you can be interrupted, then either changes the Mac or talks you through a rest. Every action is tied to the signal that triggered it.
- **The memory:** preferences come from what you allow, what you decline, and what actually helps. The next session already knows the difference.
- **The system actions:** blink rate, distance, posture, a rub, a yawn, a bright screen in a dark room: each can become a concrete change on the computer, and the outcome is checked so a useless action isn't repeated out of habit.

## What we learned
- **Private and cloud models can share one product** if each only sees what it needs. Gemma 4 sees the screen; Claude never does.
- **Solve a problem people already have.** We didn't need to invent eye strain. We needed a coach for the hour when a timer is going to be dismissed.

## What's next for eyeOS
- **More screens:** the Mac is the first screen, not the only one. Next is syncing a session across devices and a phone version for when the laptop is closed, so these signals aren't trapped in one app.
- **Clinical partners:** reviewing the eye score, blink rate, and session history with eye doctors and specialists, to take eyeOS from a coach for deadline week to something a clinician could stand behind.
