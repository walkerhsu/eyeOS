import React from 'react';
import {useCurrentFrame} from 'remotion';
import {Badge, Card, Pill} from '../components/Card';
import {ChartIcon, ClockIcon, EyeIcon} from '../components/Icons';
import {lerp, ramp, settle, travel} from '../components/motion';
import {C} from '../theme';

const ROW = 104;
const FIXES = [
	{name: 'Bigger text', pct: 50, from: 0, to: 2},
	{name: 'Dark mode', pct: 0, from: 1, to: 3},
	{name: 'Look-away break', pct: 60, from: 2, to: 1},
	{name: 'Blink blur', pct: 80, from: 3, to: 0},
];
const TRACK = 700;
const MAX_MIN = 60;

const CardHeader: React.FC<{color: string; icon: React.ReactNode; title: string; sub: string}> = ({color, icon, title, sub}) => (
	<div style={{display: 'flex', alignItems: 'center', gap: 22, marginBottom: 26}}>
		<Badge color={color} size={64}>{icon}</Badge>
		<div>
			<div style={{fontSize: 34, fontWeight: 700, letterSpacing: -0.3}}>{title}</div>
			<div style={{fontSize: 24, color: C.secondary, marginTop: 4}}>{sub}</div>
		</div>
	</div>
);

// "so future reminders constantly improve, personalized to you." — fixes re-ranked, and a break timed before the pattern.
export const Improve: React.FC = () => {
	const f = useCurrentFrame();
	const bars = ramp(f, 4, 24);
	const sort = travel(f, 28, 52);
	const right = settle(f, 12, 16);
	const fill = travel(f, 34, 82);
	const minutes = fill * 40;
	const nudge = settle(f, 84, 14);
	return (
		<div style={{display: 'flex', gap: 40, alignItems: 'stretch'}}>
			<Card padding={40} style={{width: 790}}>
				<CardHeader color={C.green} icon={<ChartIcon size={36} color={C.green} />} title="Your fixes, ranked" sub="By how often they helped you" />
				<div style={{position: 'relative', height: ROW * FIXES.length}}>
					{FIXES.map((fx) => {
						const top = lerp(fx.from, fx.to, sort) * ROW;
						const dim = fx.pct === 0 ? sort : 0;
						const best = fx.to === 0 ? sort : 0;
						return (
							<div
								key={fx.name}
								style={{
									position: 'absolute',
									top,
									left: 0,
									right: 0,
									height: ROW - 14,
									display: 'flex',
									alignItems: 'center',
									gap: 20,
									padding: '0 22px',
									borderRadius: 18,
									background: `rgba(48,209,88,${best * 0.12})`,
									border: `1.5px solid rgba(48,209,88,${best * 0.5})`,
									opacity: 1 - dim * 0.55,
								}}
							>
								<div style={{flex: 1, fontSize: 30, fontWeight: 600}}>{fx.name}</div>
								{fx.pct === 0 && <span style={{fontSize: 22, color: C.pink, opacity: sort}}>used less</span>}
								<div style={{width: 230, height: 14, borderRadius: 7, background: 'rgba(255,255,255,0.08)'}}>
									<div style={{width: `${fx.pct * bars}%`, height: '100%', borderRadius: 7, background: fx.to === 0 ? C.green : C.teal}} />
								</div>
								<div style={{width: 80, textAlign: 'right', fontSize: 28, fontWeight: 600, fontVariantNumeric: 'tabular-nums', color: C.secondary}}>
									{Math.round(fx.pct * bars)}%
								</div>
							</div>
						);
					})}
				</div>
			</Card>

			<Card padding={40} style={{width: 860, opacity: right, transform: `translateY(${(1 - right) * 30}px)`}}>
				<CardHeader color={C.teal} icon={<ClockIcon size={36} color={C.teal} />} title="Next reminder" sub="Timed to your own patterns" />
				<div style={{display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', width: TRACK}}>
					<span style={{fontSize: 28, color: C.secondary}}>Time since last break</span>
					<span style={{fontSize: 46, fontWeight: 700, fontVariantNumeric: 'tabular-nums'}}>
						{Math.floor(minutes)} <span style={{fontSize: 28, color: C.secondary, fontWeight: 500}}>min</span>
					</span>
				</div>
				<div style={{position: 'relative', width: TRACK, height: 20, marginTop: 70, borderRadius: 10, background: 'rgba(255,255,255,0.08)'}}>
					<div style={{width: `${(minutes / MAX_MIN) * 100}%`, height: '100%', borderRadius: 10, background: C.teal}} />
					<div style={{position: 'absolute', left: (45 / MAX_MIN) * TRACK, top: -48, height: 82, borderLeft: `3px dashed ${C.orange}`}} />
					<div style={{position: 'absolute', left: (45 / MAX_MIN) * TRACK + 12, top: -54, fontSize: 22, color: C.orange, fontWeight: 600, whiteSpace: 'nowrap'}}>
						Your rubs usually start
					</div>
					{[0, 15, 30, 45, 60].map((m) => (
						<div key={m} style={{position: 'absolute', left: (m / MAX_MIN) * TRACK, top: 34, transform: 'translateX(-50%)', fontSize: 20, color: C.tertiary}}>
							{m}
						</div>
					))}
				</div>

				<div
					style={{
						marginTop: 76,
						padding: 28,
						borderRadius: 22,
						background: 'rgba(255,255,255,0.06)',
						border: `1.5px solid ${C.teal}66`,
						display: 'flex',
						gap: 22,
						alignItems: 'flex-start',
						opacity: nudge,
						transform: `translateY(${(1 - nudge) * 24}px) scale(${0.97 + nudge * 0.03})`,
					}}
				>
					<Badge color={C.teal} size={60}>
						<EyeIcon size={34} color={C.teal} />
					</Badge>
					<div style={{flex: 1}}>
						<div style={{fontSize: 30, fontWeight: 700}}>Quick break before the itch?</div>
						<div style={{fontSize: 24, color: C.secondary, marginTop: 8, lineHeight: 1.35}}>
							Look 20 feet away for 20 seconds. Your eye rubs usually start around 45 min.
						</div>
					</div>
					<Pill color={C.teal}>Start</Pill>
				</div>
			</Card>
		</div>
	);
};
