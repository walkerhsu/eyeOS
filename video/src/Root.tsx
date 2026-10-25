import React from 'react';
import {Composition, Still} from 'remotion';
import {AgentShot, Hero, LogShot, Loop, Nudges, Privacy, ReportShot} from './gallery/Gallery';
import {GH, GW} from './gallery/Slide';
import {MemorySegment} from './MemorySegment';
import {AgentTab} from './scenes/AgentTab';
import {LogTab} from './scenes/LogTab';
import {Onboarding} from './scenes/Onboarding';
import {AbsoluteFill} from 'remotion';
import {C, FONT} from './theme';
import {TabClip} from './TabClip';
import {AGENT_TAB, DURATION_S, FPS, LOG_TAB, ONBOARDING} from './timing';

const AgentTabClip: React.FC = () => (
	<TabClip audio="agent-tab.m4a">
		<AgentTab />
	</TabClip>
);

const LogTabClip: React.FC = () => (
	<TabClip audio="log-tab.m4a">
		<LogTab />
	</TabClip>
);

// Silent: no voiceover for the onboarding montage.
const OnboardingClip: React.FC = () => (
	<AbsoluteFill style={{background: `radial-gradient(ellipse 80% 70% at 50% 45%, ${C.bgGlow} 0%, ${C.bg} 70%)`, fontFamily: FONT, color: C.text}}>
		<Onboarding />
	</AbsoluteFill>
);

export const Root: React.FC = () => (
	<>
		<Composition id="MemorySegment" component={MemorySegment} durationInFrames={Math.round(DURATION_S * FPS)} fps={FPS} width={1920} height={1080} />
		<Composition id="AgentTab" component={AgentTabClip} durationInFrames={Math.round(AGENT_TAB.duration * FPS)} fps={FPS} width={1920} height={1080} />
		<Composition id="Onboarding" component={OnboardingClip} durationInFrames={Math.round(ONBOARDING.duration * FPS)} fps={FPS} width={1920} height={1080} />
		{/* Devpost gallery images, 3:2 */}
		<Still id="g01-hero" component={Hero} width={GW} height={GH} />
		<Still id="g02-nudges" component={Nudges} width={GW} height={GH} />
		<Still id="g03-learning" component={Loop} width={GW} height={GH} />
		<Still id="g04-agent" component={AgentShot} width={GW} height={GH} />
		<Still id="g05-log" component={LogShot} width={GW} height={GH} />
		<Still id="g06-privacy" component={Privacy} width={GW} height={GH} />
		<Still id="g07-report" component={ReportShot} width={GW} height={GH} />
		<Composition id="LogTab" component={LogTabClip} durationInFrames={Math.round(LOG_TAB.duration * FPS)} fps={FPS} width={1920} height={1080} />
	</>
);
