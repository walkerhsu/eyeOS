// Scene start times in seconds, matched to the pauses in public/voiceover.m4a
// (ffmpeg silencedetect). Edit these and re-render to retime.
export const FPS = 30;
export const DURATION_S = 17.19;

export const SCENES = {
	approve: 0, // "After you approve suggestions,"
	measure: 1.55, // "the agent continues to observe their effectiveness,"
	memory: 4.45, // "maintaining a persistent memory of what's worked and what hasn't,"
	improve: 8.3, // "so future reminders constantly improve, personalized to you."
	report: 12.75, // "Daily reports will also let you see your progression over time."
} as const;

// Frames each scene overlaps the next, for the cross-fade.
export const OVERLAP = 8;

// In-app tab clips, each timed to its own voiceover (public/agent-tab.m4a, public/log-tab.m4a).
export const AGENT_TAB = {
	duration: 7.08,
	// "The Agent tab shows every decision Claude made," 0.87–2.99 s
	cards: 0.9,
	// "with its reasoning…" from 3.39 s
	reasoning: 3.3,
	// "…and how often each fix actually helped." ~4.6–6.6 s
	helped: 4.7,
} as const;

export const LOG_TAB = {
	duration: 5.21,
	// "And the Log lets you rewind your whole day…" from 0.77 s
	drag: 0.9,
	// the feed jumps to the selected hour, as "…to see what happened, when…" starts
	feed: 1.75,
	// "…and why." ~3.9–4.6 s
	expand: 3.3,
} as const;

// Silent onboarding montage: when each sheet page starts (seconds).
export const ONBOARDING = {
	duration: 5.2,
	welcome: 0,
	distance: 0.95,
	gaze: 1.9,
	blink: 3.25,
	done: 4.15,
} as const;
