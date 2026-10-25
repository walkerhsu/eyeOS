import React from 'react';
import {AbsoluteFill, Html5Audio, Sequence, staticFile, useCurrentFrame} from 'remotion';
import {ramp} from './components/motion';
import {Header} from './components/Header';
import {C, FONT} from './theme';
import {DURATION_S, FPS, OVERLAP, SCENES} from './timing';
import {Approve} from './scenes/Approve';
import {Measure} from './scenes/Measure';
import {Memory} from './scenes/Memory';
import {Improve} from './scenes/Improve';
import {DailyReport} from './scenes/DailyReport';

const ORDER = [
	{key: 'approve', Scene: Approve},
	{key: 'measure', Scene: Measure},
	{key: 'memory', Scene: Memory},
	{key: 'improve', Scene: Improve},
	{key: 'report', Scene: DailyReport},
] as const;

// Fades and lifts a scene in, and out again while the next one fades in.
const SceneShell: React.FC<{duration: number; exits: boolean; children: React.ReactNode}> = ({duration, exits, children}) => {
	const f = useCurrentFrame();
	// the old scene is mostly gone before the new one comes up, so the two don't ghost over each other
	const enter = ramp(f, 3, OVERLAP + 6);
	const leave = exits ? ramp(f, duration - OVERLAP, duration - 2) : 0;
	return (
		<AbsoluteFill
			style={{
				alignItems: 'center',
				justifyContent: 'center',
				paddingTop: 70,
				opacity: Math.min(enter, 1 - leave),
				transform: `translateY(${(1 - enter) * 36 - leave * 24}px) scale(${1 - leave * 0.02})`,
			}}
		>
			{children}
		</AbsoluteFill>
	);
};

export const MemorySegment: React.FC = () => {
	const total = Math.round(DURATION_S * FPS);
	return (
		<AbsoluteFill style={{background: `radial-gradient(ellipse 80% 70% at 50% 45%, ${C.bgGlow} 0%, ${C.bg} 70%)`, fontFamily: FONT, color: C.text}}>
			<Html5Audio src={staticFile('voiceover.m4a')} />
			{ORDER.map(({key, Scene}, i) => {
				const from = Math.round(SCENES[key] * FPS);
				const next = i < ORDER.length - 1 ? Math.round(SCENES[ORDER[i + 1].key] * FPS) : total;
				const exits = i < ORDER.length - 1;
				const duration = next - from + (exits ? OVERLAP : 0);
				return (
					<Sequence key={key} from={from} durationInFrames={duration} name={key}>
						<SceneShell duration={duration} exits={exits}>
							<Scene />
						</SceneShell>
					</Sequence>
				);
			})}
			<Header />
		</AbsoluteFill>
	);
};
