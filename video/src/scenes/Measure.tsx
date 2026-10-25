import React from 'react';
import {interpolate, useCurrentFrame} from 'remotion';
import {Badge, Card, Pill} from '../components/Card';
import {areaPath, smoothPath} from '../components/chart';
import {BrainIcon, CheckIcon} from '../components/Icons';
import {lerp, ramp, settle} from '../components/motion';
import {C} from '../theme';

const W = 1112;
const H = 290;
const T0 = -120; // 2 min before
const T1 = 180; // 3 min after
const YMAX = 16;

// Blink rate around the action: low before, rising to ~12.4/min after (deterministic wobble).
const DATA = Array.from({length: 61}, (_, i) => {
	const t = T0 + i * 5;
	const wobble = Math.sin(i * 1.7) * 0.6 + Math.sin(i * 0.6) * 0.4;
	const lift = t <= 10 ? 0 : 5.6 * (1 - Math.exp(-(t - 10) / 35));
	return {t, v: 6.8 + lift + wobble};
});
const x = (t: number) => ((t - T0) / (T1 - T0)) * W;
const y = (v: number) => H - (v / YMAX) * H;
const PTS = DATA.map((d) => ({x: x(d.t), y: y(d.v)}));

// "the agent continues to observe their effectiveness," — before/after blink rate and the verdict.
export const Measure: React.FC = () => {
	const f = useCurrentFrame();
	const draw = ramp(f, 2, 50);
	const value = lerp(6.8, 12.4, interpolate(draw, [0.42, 1], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}));
	const verdict = settle(f, 52, 12);
	const measuring = 1 - ramp(f, 48, 53);
	const head = PTS[Math.min(PTS.length - 1, Math.round(draw * (PTS.length - 1)))];
	return (
		<Card padding={44} style={{width: 1200}}>
			<div style={{display: 'flex', alignItems: 'center', gap: 24}}>
				<Badge color={C.purple} size={68}>
					<BrainIcon size={38} color={C.purple} />
				</Badge>
				<div style={{flex: 1}}>
					<div style={{fontSize: 38, fontWeight: 700, letterSpacing: -0.4}}>Blink blur turned on</div>
					<div style={{fontSize: 26, color: C.secondary, marginTop: 4}}>Checking what your eyes did next</div>
				</div>
				<div style={{position: 'relative', width: 230, height: 56}}>
					<Pill color={C.teal} style={{position: 'absolute', right: 0, opacity: measuring}}>Measuring…</Pill>
					<Pill color={C.green} style={{position: 'absolute', right: 0, opacity: verdict, transform: `scale(${0.7 + verdict * 0.3})`}}>
						<CheckIcon size={26} color={C.green} />
						Helped
					</Pill>
				</div>
			</div>

			<svg width={W} height={H + 56} style={{marginTop: 34, overflow: 'visible'}}>
				<defs>
					<clipPath id="draw">
						<rect x={0} y={-20} width={W * draw} height={H + 40} />
					</clipPath>
					<linearGradient id="fill" x1="0" y1="0" x2="0" y2="1">
						<stop offset="0%" stopColor={C.teal} stopOpacity={0.28} />
						<stop offset="100%" stopColor={C.teal} stopOpacity={0} />
					</linearGradient>
				</defs>
				<rect x={0} y={0} width={x(0)} height={H} rx={14} fill="rgba(255,255,255,0.03)" />
				<rect x={x(0)} y={0} width={W - x(0)} height={H} rx={14} fill={C.teal} fillOpacity={0.05} />
				{[4, 8, 12].map((v) => (
					<g key={v}>
						<line x1={0} x2={W} y1={y(v)} y2={y(v)} stroke="rgba(255,255,255,0.06)" strokeWidth={1.5} />
						<text x={-14} y={y(v) + 8} fill={C.tertiary} fontSize={22} textAnchor="end">{v}</text>
					</g>
				))}
				<g clipPath="url(#draw)">
					<path d={areaPath(PTS, H)} fill="url(#fill)" />
					<path d={smoothPath(PTS)} fill="none" stroke={C.teal} strokeWidth={5} strokeLinecap="round" />
				</g>
				<circle cx={head.x} cy={head.y} r={9} fill={C.teal} stroke={C.bg} strokeWidth={3} />
				<line x1={x(0)} x2={x(0)} y1={-6} y2={H} stroke={C.purple} strokeWidth={3} strokeDasharray="8 8" />
				<text x={x(0) + 14} y={30} fill={C.purple} fontSize={24} fontWeight={600}>Blink blur on</text>
				<text x={x(T0) + 4} y={H + 44} fill={C.tertiary} fontSize={24}>2 min before</text>
				<text x={W - 4} y={H + 44} fill={C.tertiary} fontSize={24} textAnchor="end">3 min after</text>
			</svg>

			<div style={{display: 'flex', alignItems: 'baseline', gap: 18, marginTop: 18}}>
				<span style={{fontSize: 30, color: C.secondary}}>Blink rate</span>
				<span style={{fontSize: 60, fontWeight: 700, fontVariantNumeric: 'tabular-nums', letterSpacing: -1}}>
					6.8 <span style={{color: C.tertiary}}>→</span> {value.toFixed(1)}
				</span>
				<span style={{fontSize: 30, color: C.secondary}}>/min</span>
				<span style={{fontSize: 34, fontWeight: 700, color: C.green, opacity: verdict, marginLeft: 8}}>+82%</span>
			</div>
		</Card>
	);
};
