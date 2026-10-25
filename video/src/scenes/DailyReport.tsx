import React from 'react';
import {useCurrentFrame} from 'remotion';
import {Badge, Card, Pill} from '../components/Card';
import {areaPath, smoothPath} from '../components/chart';
import {ChartIcon, SparklesIcon} from '../components/Icons';
import {ramp, settle} from '../components/motion';
import {C} from '../theme';

const SENTENCES = [
	'You averaged 13 blinks/min today, up from 8 last week.',
	'Blink blur helped most, and eye rubs dropped from 9 to 3.',
	'Your longest stare was 24 s, during a code review.',
];
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const SCORES = [58, 61, 60, 66, 70, 74, 81];
const W = 1080;
const H = 220;
const x = (i: number) => 20 + (i / (DAYS.length - 1)) * (W - 40);
const y = (v: number) => H - ((v - 40) / 60) * H;
const PTS = SCORES.map((v, i) => ({x: x(i), y: y(v)}));

// "Daily reports will also let you see your progression over time." — the Log page's daily summary and a week of eye scores.
export const DailyReport: React.FC = () => {
	const f = useCurrentFrame();
	const draw = ramp(f, 26, 84);
	const last = settle(f, 84, 12);
	const chart = settle(f, 14, 16);
	return (
		<div style={{width: 1200, display: 'flex', flexDirection: 'column', gap: 30}}>
			<Card padding={40} accent={C.teal}>
				<div style={{display: 'flex', alignItems: 'center', gap: 18, marginBottom: 20}}>
					<Badge color={C.teal} size={56}>
						<SparklesIcon size={30} color={C.teal} />
					</Badge>
					<span style={{fontSize: 30, fontWeight: 700, color: C.teal}}>Daily summary</span>
					<div style={{flex: 1}} />
					<span style={{fontSize: 24, color: C.tertiary}}>Saturday, Oct 24</span>
				</div>
				{SENTENCES.map((s, i) => {
					const p = ramp(f, 4 + i * 9, 18 + i * 9);
					return (
						<div key={s} style={{fontSize: 33, lineHeight: 1.45, opacity: p, transform: `translateY(${(1 - p) * 14}px)`}}>
							{s}
						</div>
					);
				})}
			</Card>

			<Card padding={40} style={{opacity: chart, transform: `translateY(${(1 - chart) * 30}px)`}}>
				<div style={{display: 'flex', alignItems: 'center', gap: 18, marginBottom: 22}}>
					<Badge color={C.green} size={56}>
						<ChartIcon size={32} color={C.green} />
					</Badge>
					<span style={{fontSize: 30, fontWeight: 700}}>Eye score · last 7 days</span>
					<div style={{flex: 1}} />
					<Pill color={C.green} style={{opacity: last}}>+23 this week</Pill>
				</div>
				<svg width={W} height={H + 50} style={{overflow: 'visible'}}>
					<defs>
						<clipPath id="week">
							<rect x={0} y={-30} width={W * draw} height={H + 60} />
						</clipPath>
						<linearGradient id="weekFill" x1="0" y1="0" x2="0" y2="1">
							<stop offset="0%" stopColor={C.green} stopOpacity={0.3} />
							<stop offset="100%" stopColor={C.green} stopOpacity={0} />
						</linearGradient>
					</defs>
					{[50, 70, 90].map((v) => (
						<line key={v} x1={0} x2={W} y1={y(v)} y2={y(v)} stroke="rgba(255,255,255,0.06)" strokeWidth={1.5} />
					))}
					<g clipPath="url(#week)">
						<path d={areaPath(PTS, H)} fill="url(#weekFill)" />
						<path d={smoothPath(PTS)} fill="none" stroke={C.green} strokeWidth={5} strokeLinecap="round" />
						{PTS.slice(0, -1).map((p, i) => (
							<circle key={i} cx={p.x} cy={p.y} r={7} fill={C.green} stroke={C.bg} strokeWidth={3} />
						))}
					</g>
					<circle cx={PTS[6].x} cy={PTS[6].y} r={7 + last * 6} fill={C.green} stroke={C.bg} strokeWidth={3} opacity={last} />
					<text x={PTS[6].x} y={PTS[6].y - 26} fill={C.text} fontSize={34} fontWeight={700} textAnchor="middle" opacity={last}>
						{SCORES[6]}
					</text>
					{DAYS.map((d, i) => (
						<text key={d} x={x(i)} y={H + 44} fill={i === 6 ? C.text : C.tertiary} fontSize={24} fontWeight={i === 6 ? 700 : 400} textAnchor="middle">
							{d}
						</text>
					))}
				</svg>
			</Card>
		</div>
	);
};
