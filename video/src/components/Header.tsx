import React from 'react';
import {interpolate, useCurrentFrame} from 'remotion';
import {C} from '../theme';
import {DURATION_S, FPS, SCENES} from '../timing';
import {CheckIcon, EyeIcon} from './Icons';
import {ramp} from './motion';

const STEPS = [
	{key: 'approve', label: 'Approve', color: C.orange},
	{key: 'measure', label: 'Measure', color: C.teal},
	{key: 'memory', label: 'Remember', color: C.purple},
	{key: 'improve', label: 'Improve', color: C.green},
	{key: 'report', label: 'Report', color: C.teal},
] as const;

// The eyeOS wordmark and a step tracker that follows the narration.
export const Header: React.FC = () => {
	const f = useCurrentFrame();
	const appear = ramp(f, 0, 10);
	return (
		<div style={{position: 'absolute', top: 52, left: 72, right: 72, display: 'flex', alignItems: 'center', justifyContent: 'space-between', opacity: appear}}>
			<div style={{display: 'flex', alignItems: 'center', gap: 14}}>
				<EyeIcon size={40} color={C.teal} />
				<span style={{fontSize: 34, fontWeight: 700, letterSpacing: -0.5}}>eyeOS</span>
			</div>
			<div style={{display: 'flex', alignItems: 'center', gap: 10}}>
				{STEPS.map((s, i) => {
					const start = SCENES[s.key] * FPS;
					const end = i < STEPS.length - 1 ? SCENES[STEPS[i + 1].key] * FPS : DURATION_S * FPS + 60;
					// 1 while this step is current, easing in and out around its boundaries
					const on = Math.min(
						interpolate(f, [start - 4, start + 4], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}),
						interpolate(f, [end - 4, end + 4], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}),
					);
					const done = f >= end;
					return (
						<React.Fragment key={s.key}>
							{i > 0 && <div style={{width: 28, height: 2, borderRadius: 1, background: f >= start ? C.secondary : 'rgba(255,255,255,0.12)'}} />}
							<div
								style={{
									display: 'flex',
									alignItems: 'center',
									gap: 10,
									padding: '10px 20px',
									borderRadius: 999,
									background: `rgba(255,255,255,${0.04 + on * 0.08})`,
									border: `1.5px solid ${on > 0.5 ? s.color + 'aa' : 'rgba(255,255,255,0.08)'}`,
									color: on > 0.5 ? C.text : done ? C.secondary : C.tertiary,
									fontSize: 24,
									fontWeight: 600,
								}}
							>
								{done ? (
									<CheckIcon size={20} color={C.secondary} />
								) : (
									<div style={{width: 12, height: 12, borderRadius: 6, background: on > 0.5 ? s.color : 'rgba(255,255,255,0.2)', transform: `scale(${1 + on * 0.15})`}} />
								)}
								{s.label}
							</div>
						</React.Fragment>
					);
				})}
			</div>
		</div>
	);
};
