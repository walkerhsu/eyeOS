import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {AppBar, AppWindow, CONTENT, MacButton, Panel} from '../components/AppWindow';
import {smoothPath} from '../components/chart';
import {CursorTrack} from '../components/CursorTrack';
import {BoltIcon, BrainIcon, ChartIcon, CheckIcon, ChevronIcon, DisplayIcon, DropIcon, HandIcon, MoonIcon, SearchIcon, SparklesIcon, WalkIcon} from '../components/Icons';
import {ramp, settle} from '../components/motion';
import {C} from '../theme';
import {FPS, LOG_TAB} from '../timing';

const T = {drag: LOG_TAB.drag * FPS, feed: LOG_TAB.feed * FPS, expand: LOG_TAB.expand * FPS};

// Fixed layout, so the cursor can aim: AppBar 72 + 20, then the "Day at a glance" card.
const CARD_Y = CONTENT.y + 92;
const PLOT = {x: CONTENT.x + 22, y: CARD_Y + 22 + 36 + 12, w: CONTENT.right - CONTENT.x - 44, h: 196};
const H0 = 8;
const H1 = 18;
const tx = (h: number) => PLOT.x + ((h - H0) / (H1 - H0)) * PLOT.w;
const SEL = {from: 14, to: 15};
const FEED_Y = CARD_Y + 322 + 18 + 52 + 14;
const ROW = 74;
const GAP = 10;

// A day of metrics (deterministic), local to the plot box.
const series = (fn: (h: number) => number) =>
	Array.from({length: 121}, (_, i) => {
		const h = H0 + (i / 120) * (H1 - H0);
		return {x: tx(h) - PLOT.x, y: PLOT.h - fn(h) * PLOT.h};
	});
const BLINK = series((h) => 0.55 + Math.sin(h * 2.3) * 0.08 + Math.sin(h * 5.1) * 0.05 - (h > 14.1 && h < 14.7 ? 0.28 * Math.sin(((h - 14.1) / 0.6) * Math.PI) : 0));
const PERCLOS = series((h) => 0.16 + Math.sin(h * 1.7 + 1) * 0.04 + (h > 16 ? (h - 16) * 0.05 : 0));
const DIST = series((h) => 0.36 + Math.sin(h * 3.1 + 2) * 0.06 - (h > 14 && h < 14.6 ? 0.1 : 0));
const ZEN = [
	{from: 10.2, to: 11.1},
	{from: 17.07, to: 17.87},
];
const RUNS = [9.4, 10.0, 11.8, 13.1, 14.6, 15.5, 16.7];
const ACTIONS = [
	{h: 13.1, color: C.green},
	{h: 14.6, color: C.green},
	{h: 9.4, color: C.green},
];

type Row = {time: string; title: string; sub: string; color: string; Icon: React.FC<{size?: number; color: string}>; value?: string; run?: boolean};
const BEFORE: Row[] = [
	{time: '17:52', title: 'Zen ended', sub: '48m of quiet focus · 3 alerts held', color: C.indigo, Icon: MoonIcon},
	{time: '17:04', title: 'Zen started', sub: 'Deep focus detected', color: C.indigo, Icon: MoonIcon},
	{time: '16:40', title: 'Agent · Routine check-in', sub: 'Decided to wait', color: C.purple, Icon: BrainIcon, run: true},
	{time: '16:12', title: 'Real break', sub: 'Looked away for 2m 10s', color: C.green, Icon: WalkIcon},
	{time: '15:31', title: 'Now: Meeting', sub: 'Zoom · camera on', color: '#66D4CF', Icon: DisplayIcon},
];
const AFTER: Row[] = [
	{time: '14:52', title: 'Real break', sub: 'Looked away for 1m 10s', color: C.green, Icon: WalkIcon},
	{time: '14:36', title: 'Agent · Low blink rate & long stare', sub: 'Blink blur · helped ✓', color: C.purple, Icon: BrainIcon, run: true},
	{time: '14:35', title: 'Low blink rate', sub: 'Signal crossed its threshold', color: C.yellow, Icon: BoltIcon, value: '6.8 /min'},
	{time: '14:21', title: 'Eye rub', sub: 'Fingertips stayed near your eyes', color: C.orange, Icon: HandIcon},
	{time: '14:05', title: 'Now: Coding', sub: 'VS Code · deep focus', color: '#66D4CF', Icon: DisplayIcon},
];

const FeedRow: React.FC<{row: Row; style?: React.CSSProperties; open?: number; expanded?: boolean}> = ({row, style, open = 0, expanded}) => (
	<Panel accent={expanded ? C.purple + '73' : undefined} style={{padding: '12px 20px', ...style}}>
		<div style={{display: 'flex', alignItems: 'center', gap: 16, height: ROW - 24}}>
			<div style={{width: 46, height: 46, borderRadius: 13, background: row.color + '29', display: 'flex', alignItems: 'center', justifyContent: 'center'}}>
				<row.Icon size={24} color={row.color} />
			</div>
			<div style={{flex: 1}}>
				<div style={{fontSize: 23, fontWeight: 600}}>{row.title}</div>
				<div style={{fontSize: 18, color: C.secondary, marginTop: 2}}>{row.sub}</div>
			</div>
			{row.value && <div style={{padding: '4px 12px', borderRadius: 999, background: row.color + '24', color: row.color, fontSize: 18, fontWeight: 600}}>{row.value}</div>}
			{row.run && row.sub.includes('helped') && (
				<div style={{width: 32, height: 32, borderRadius: 16, background: C.green + '24', display: 'flex', alignItems: 'center', justifyContent: 'center'}}>
					<DropIcon size={20} color={C.green} />
				</div>
			)}
			<span style={{fontSize: 19, color: C.secondary, fontVariantNumeric: 'tabular-nums', width: 60, textAlign: 'right'}}>{row.time}</span>
			{row.run && <ChevronIcon size={20} color={C.tertiary} rotate={open * 90} />}
		</div>
		{expanded !== undefined && (
			<div style={{maxHeight: open * 240, opacity: open, overflow: 'hidden', paddingLeft: 62}}>
				<div style={{fontSize: 22, fontWeight: 600, marginTop: 12, lineHeight: 1.35}}>
					Your blink rate has been about half your normal for 5 minutes, so I turned on blink blur.
				</div>
				<div style={{fontSize: 19, color: C.secondary, marginTop: 6, lineHeight: 1.4}}>
					Blink pulses only helped 2 of 5 times today; blink blur helped 4 of 5. You're coding, so I picked the cue that doesn't interrupt.
				</div>
				<div style={{display: 'flex', alignItems: 'center', gap: 14, marginTop: 12, padding: '10px 16px', borderRadius: 12, background: 'rgba(255,255,255,0.04)'}}>
					<DropIcon size={22} color={C.green} />
					<span style={{fontSize: 20, fontWeight: 600}}>Blink blur on</span>
					<span style={{fontSize: 18, color: C.secondary}}>Blink rate 6.8 → 12.4 /min</span>
					<div style={{flex: 1}} />
					<div style={{display: 'flex', alignItems: 'center', gap: 6, padding: '4px 12px', borderRadius: 999, background: C.green + '29', color: C.green, fontSize: 17, fontWeight: 600}}>
						<CheckIcon size={16} color={C.green} />
						Helped
					</div>
				</div>
			</div>
		)}
	</Panel>
);

const FILTERS = [
	{name: 'All', n: 48, color: C.text},
	{name: 'Events', n: 31, color: C.teal},
	{name: 'Agent', n: 14, color: C.purple},
	{name: 'Actions', n: 9, color: C.green},
	{name: 'Errors', n: 0, color: C.pink},
];

// "And the Log lets you rewind your whole day to see what happened, when, and why."
export const LogTab: React.FC = () => {
	const f = useCurrentFrame();
	const win = ramp(f, 0, 8);
	const pressed = f >= T.drag;
	const dragged = interpolate(f, [T.drag, T.drag + 22], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
	const released = f >= T.drag + 22;
	const swap = ramp(f, T.drag + 22, T.drag + 30);
	const open = settle(f, T.expand + 3, 16);
	const selX0 = tx(SEL.from);
	const selX1 = tx(SEL.from) + (tx(SEL.to) - tx(SEL.from)) * dragged;
	const rowY = (i: number) => FEED_Y + i * (ROW + GAP);

	return (
		<AbsoluteFill style={{transform: `scale(${1 + f * 0.00014})`}}>
			<div style={{opacity: win, transform: `translateY(${(1 - win) * 20}px)`}}>
				<AppWindow page="Log">
					<AppBar title="Log">
						<MacButton>
							<SparklesIcon size={20} color={C.text} />
							Daily summary
						</MacButton>
					</AppBar>

					<Panel style={{height: 322, padding: 22, marginBottom: 18}}>
						<div style={{display: 'flex', alignItems: 'center', height: 36, marginBottom: 12, gap: 10}}>
							<ChartIcon size={24} color={C.secondary} />
							<span style={{fontSize: 23, fontWeight: 600, color: C.secondary}}>Day at a glance</span>
							<div style={{flex: 1}} />
							{released ? (
								<span style={{fontSize: 19, color: C.teal, fontVariantNumeric: 'tabular-nums', opacity: swap}}>2:00 PM – 3:00 PM &nbsp;·&nbsp; Clear</span>
							) : (
								<span style={{fontSize: 18, color: C.tertiary}}>Drag across the chart (or click) to jump to that time</span>
							)}
						</div>
						<svg width={PLOT.w} height={PLOT.h + 34} style={{overflow: 'visible'}}>
							{ZEN.map((z) => (
								<rect key={z.from} x={tx(z.from) - PLOT.x} y={0} width={tx(z.to) - tx(z.from)} height={PLOT.h} fill={C.indigo} fillOpacity={0.14} rx={6} />
							))}
							{[0.25, 0.5, 0.75].map((g) => (
								<line key={g} x1={0} x2={PLOT.w} y1={PLOT.h * g} y2={PLOT.h * g} stroke="rgba(255,255,255,0.05)" strokeWidth={1.5} />
							))}
							<path d={smoothPath(PERCLOS)} fill="none" stroke={C.purple} strokeWidth={3} opacity={0.85} />
							<path d={smoothPath(DIST)} fill="none" stroke={C.orange} strokeWidth={3} opacity={0.85} />
							<path d={smoothPath(BLINK)} fill="none" stroke={C.teal} strokeWidth={4} />
							{RUNS.map((h) => (
								<circle key={h} cx={tx(h) - PLOT.x} cy={10} r={7} fill={C.purple} />
							))}
							{ACTIONS.map((a) => (
								<circle key={a.h} cx={tx(a.h) - PLOT.x} cy={30} r={6} fill={a.color} />
							))}
							{pressed && (
								<rect x={selX0 - PLOT.x} y={0} width={selX1 - selX0} height={PLOT.h} fill={C.teal} fillOpacity={0.16} stroke={C.teal} strokeOpacity={0.6} strokeWidth={2} rx={6} />
							)}
							{Array.from({length: 11}, (_, i) => H0 + i).map((h) => (
								<text key={h} x={tx(h) - PLOT.x} y={PLOT.h + 28} fill={C.tertiary} fontSize={17} textAnchor="middle">
									{h > 12 ? `${h - 12} PM` : h === 12 ? '12 PM' : `${h} AM`}
								</text>
							))}
						</svg>
					</Panel>

					<div style={{display: 'flex', alignItems: 'center', height: 52, marginBottom: 14}}>
						<div style={{display: 'flex', padding: 4, borderRadius: 12, background: 'rgba(255,255,255,0.06)', gap: 4}}>
							{FILTERS.map((x, i) => (
								<div key={x.name} style={{padding: '8px 18px', borderRadius: 9, fontSize: 19, fontWeight: 500, background: i === 0 ? 'rgba(255,255,255,0.14)' : 'transparent', color: i === 0 ? C.text : C.secondary, display: 'flex', gap: 8}}>
									{x.name}
									<span style={{color: x.color, opacity: 0.8, fontVariantNumeric: 'tabular-nums'}}>{x.n}</span>
								</div>
							))}
						</div>
						<div style={{flex: 1}} />
						<div style={{display: 'flex', alignItems: 'center', gap: 10, width: 300, padding: '10px 16px', borderRadius: 11, background: 'rgba(255,255,255,0.05)', border: '1.5px solid rgba(255,255,255,0.08)', fontSize: 19, color: C.tertiary}}>
							<SearchIcon size={20} color={C.secondary} />
							Search
						</div>
					</div>

					<div style={{position: 'relative'}}>
						{f < T.drag + 30 &&
							BEFORE.map((r, i) => (
								<FeedRow key={r.time} row={r} style={{position: 'absolute', left: 0, right: 0, top: i * (ROW + GAP), opacity: (1 - swap) * settle(f, 4 + i * 2, 12), transform: `translateY(${-swap * 30}px)`}} />
							))}
						{f >= T.drag + 24 && (
							<div style={{display: 'flex', flexDirection: 'column', gap: GAP}}>
								{AFTER.map((r, i) => {
									const p = settle(f, Math.max(T.drag + 26, T.feed) + i * 4, 14);
									return (
										<FeedRow
											key={r.time}
											row={r}
											open={i === 1 ? open : 0}
											expanded={i === 1 ? f >= T.expand + 3 : undefined}
											style={{opacity: p, transform: `translateY(${(1 - p) * 26}px)`}}
										/>
									);
								})}
							</div>
						)}
					</div>
				</AppWindow>
			</div>
			<CursorTrack
				showFrom={T.drag - 14}
				clicks={[T.expand]}
				path={[
					{f: T.drag - 14, x: selX0 - 120, y: PLOT.y + PLOT.h + 160},
					{f: T.drag - 1, x: selX0, y: PLOT.y + 110},
					{f: T.drag + 22, x: tx(SEL.to), y: PLOT.y + 120},
					{f: T.expand - 14, x: tx(SEL.to), y: PLOT.y + 120},
					{f: T.expand - 2, x: 1420, y: rowY(1) + ROW / 2 - 6},
					{f: T.expand + 60, x: 1450, y: rowY(1) + ROW / 2 - 10},
				]}
			/>
		</AbsoluteFill>
	);
};
