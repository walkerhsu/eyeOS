import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {AppWindow} from '../components/AppWindow';
import {CursorTrack} from '../components/CursorTrack';
import {CheckIcon, ClockIcon, EyeIcon, MoonIcon} from '../components/Icons';
import {ramp, settle} from '../components/motion';
import {C} from '../theme';
import {FPS, ONBOARDING} from '../timing';

const P = {
	distance: ONBOARDING.distance * FPS,
	gaze: ONBOARDING.gaze * FPS,
	blink: ONBOARDING.blink * FPS,
	done: ONBOARDING.done * FPS,
};
const MINT = '#66D4CF';

// The sheet is the real 560×500 pt sheet at 1.6×, centered on the window.
const S = 1.6;
const SHEET = {w: 560 * S, h: 500 * S};
const SHEET_X = (1920 - SHEET.w) / 2;
const SHEET_Y = (1080 - SHEET.h) / 2 + 10;
const BUTTON = {x: 960, y: SHEET_Y + SHEET.h - 28 * S - 25};

const PersonIcon: React.FC<{size: number; color: string}> = ({size, color}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill={color}>
		<circle cx="12" cy="6.5" r="4" />
		<path d="M3.5 21c0-4.7 3.8-8 8.5-8s8.5 3.3 8.5 8z" />
	</svg>
);

const LaptopIcon: React.FC<{size: number; color: string}> = ({size, color}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={1.8} strokeLinejoin="round">
		<rect x="4.5" y="5" width="15" height="10.5" rx="1.5" />
		<path d="M2 18.5h20l-1.2 1.5H3.2z" fill={color} />
	</svg>
);

const ShieldIcon: React.FC<{size: number; color: string}> = ({size, color}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill={color}>
		<path d="M12 2.5l8 3v6c0 5-3.4 8.6-8 10-4.6-1.4-8-5-8-10v-6z" />
		<path d="M8.5 12l2.5 2.5 4.5-5" fill="none" stroke="#16181D" strokeWidth={2.2} strokeLinecap="round" strokeLinejoin="round" />
	</svg>
);

const Button: React.FC<{label: string; pressed?: boolean}> = ({label, pressed}) => (
	<div
		style={{
			width: 220 * S,
			height: 34 * S,
			borderRadius: 10 * S,
			background: C.blue,
			display: 'flex',
			alignItems: 'center',
			justifyContent: 'center',
			fontSize: 15 * S,
			fontWeight: 600,
			transform: `scale(${pressed ? 0.96 : 1})`,
			filter: pressed ? 'brightness(0.85)' : undefined,
		}}
	>
		{label}
	</div>
);

const ProgressRing: React.FC<{p: number}> = ({p}) => {
	const r = 34;
	const len = 2 * Math.PI * r;
	return (
		<svg width={77} height={77} viewBox="0 0 77 77">
			<circle cx={38.5} cy={38.5} r={r} fill="none" stroke="rgba(255,255,255,0.1)" strokeWidth={8} />
			<circle cx={38.5} cy={38.5} r={r} fill="none" stroke={C.teal} strokeWidth={8} strokeLinecap="round" strokeDasharray={`${len * p} ${len}`} transform="rotate(-90 38.5 38.5)" />
			<text x={38.5} y={44} fill={C.text} fontSize={17} textAnchor="middle" style={{fontVariantNumeric: 'tabular-nums'}}>
				{Math.round(p * 100)}%
			</text>
		</svg>
	);
};

// Start → progress ring → Done, like CalibrationStep.
const StepControl: React.FC<{f: number; start: number; run: [number, number]}> = ({f, start, run}) => {
	if (f < run[0]) return <Button label="Start" pressed={f >= start && f < start + 4} />;
	if (f < run[1]) return <ProgressRing p={interpolate(f, run, [0, 1])} />;
	return (
		<div style={{height: 77, display: 'flex', alignItems: 'center', gap: 10, color: MINT, fontSize: 17 * S, fontWeight: 600}}>
			<CheckIcon size={30} color={MINT} />
			Done
		</div>
	);
};

const CalibrationPage: React.FC<{f: number; title: string; subtitle: string; art: React.ReactNode; start: number; run: [number, number]}> = ({f, title, subtitle, art, start, run}) => (
	<div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', height: '100%'}}>
		<div style={{flex: 1}} />
		<div style={{height: 150 * S, display: 'flex', alignItems: 'center', justifyContent: 'center'}}>{art}</div>
		<div style={{fontSize: 24 * S, fontWeight: 700, marginTop: 18 * S}}>{title}</div>
		<div style={{fontSize: 14 * S, color: C.secondary, textAlign: 'center', maxWidth: 400 * S, marginTop: 6 * S, lineHeight: 1.35}}>{subtitle}</div>
		<div style={{display: 'flex', alignItems: 'center', gap: 8, marginTop: 18 * S, padding: '6px 16px', borderRadius: 999, background: MINT + '29', color: MINT, fontSize: 12 * S, fontWeight: 600}}>
			<CheckIcon size={20} color={MINT} />
			Face found
		</div>
		<div style={{flex: 1}} />
		<StepControl f={f} start={start} run={run} />
	</div>
);

const Feature: React.FC<{color: string; icon: React.ReactNode; text: string}> = ({color, icon, text}) => (
	<div style={{display: 'flex', alignItems: 'center', gap: 12 * S}}>
		<div style={{width: 32 * S, height: 32 * S, borderRadius: 9 * S, background: color + '26', display: 'flex', alignItems: 'center', justifyContent: 'center'}}>{icon}</div>
		<span style={{fontSize: 14 * S, fontWeight: 500}}>{text}</span>
	</div>
);

const GAZE_PTS = [
	{x: 960, y: 540},
	{x: 64, y: 64},
	{x: 1856, y: 64},
	{x: 1856, y: 1016},
	{x: 64, y: 1016},
];

// Silent onboarding montage: welcome → distance → gaze → blink check → you're set.
export const Onboarding: React.FC = () => {
	const f = useCurrentFrame();
	const sheet = settle(f, 0, 10);
	const page = f < P.distance ? 0 : f < P.gaze ? 1 : f < P.blink ? 2 : f < P.done ? 3 : 4;
	const pageStart = [0, P.distance, P.gaze, P.blink, P.done][page];
	const pageIn = page === 0 ? 1 : ramp(f, pageStart, pageStart + 5);

	// gaze dot: full-screen overlay after Start, center then the four corners
	const gazeRun: [number, number] = [P.gaze + 8, P.blink - 8];
	const overlay = Math.min(ramp(f, gazeRun[0] - 2, gazeRun[0] + 3), 1 - ramp(f, gazeRun[1] - 1, gazeRun[1] + 4));
	const seg = interpolate(f, gazeRun, [0, GAZE_PTS.length - 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
	const k = Math.min(GAZE_PTS.length - 2, Math.floor(seg));
	const t = seg - k;
	const ease = t < 0.55 ? 0 : (t - 0.55) / 0.45; // hold, then hop to the next point
	const dot = {x: GAZE_PTS[k].x + (GAZE_PTS[k + 1].x - GAZE_PTS[k].x) * ease, y: GAZE_PTS[k].y + (GAZE_PTS[k + 1].y - GAZE_PTS[k].y) * ease};

	const blinks = [P.blink + 12, P.blink + 17, P.blink + 22].filter((b) => f >= b).length;

	return (
		<AbsoluteFill>
			<div style={{opacity: ramp(f, 0, 6)}}>
				<AppWindow page="Live">
					<div style={{fontSize: 44, fontWeight: 700}}>Live</div>
				</AppWindow>
			</div>
			<AbsoluteFill style={{background: 'rgba(0,0,0,0.45)', opacity: sheet}} />

			<div
				style={{
					position: 'absolute',
					left: SHEET_X,
					top: SHEET_Y,
					width: SHEET.w,
					height: SHEET.h,
					borderRadius: 26,
					background: '#22252B',
					border: '1.5px solid rgba(255,255,255,0.12)',
					boxShadow: '0 40px 120px rgba(0,0,0,0.6)',
					opacity: sheet,
					transform: `translateY(${(1 - sheet) * -40}px)`,
					padding: `${16 * S}px ${36 * S}px ${28 * S}px`,
					display: 'flex',
					flexDirection: 'column',
				}}
			>
				<div style={{display: 'flex', alignItems: 'center', height: 20 * S}}>
					{page > 0 && (
						<div style={{display: 'flex', gap: 6 * S, marginLeft: -16 * S}}>
							{[1, 2, 3, 4].map((i) => (
								<div key={i} style={{width: (i === page ? 22 : 8) * S, height: 8 * S, borderRadius: 4 * S, background: i <= page ? C.teal : 'rgba(255,255,255,0.15)'}} />
							))}
						</div>
					)}
					<div style={{flex: 1}} />
					{page < 4 && <span style={{fontSize: 13 * S, color: C.secondary, marginRight: -16 * S}}>Skip</span>}
				</div>

				<div style={{flex: 1, opacity: pageIn, transform: `translateX(${(1 - pageIn) * 40}px)`}}>
					{page === 0 && (
						<div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', height: '100%', gap: 22 * S}}>
							<div style={{flex: 1}} />
							<div style={{width: 72 * S, height: 72 * S, borderRadius: 36 * S, background: `linear-gradient(135deg, ${C.teal}, ${C.indigo})`, display: 'flex', alignItems: 'center', justifyContent: 'center'}}>
								<EyeIcon size={46 * S} color="#16181D" stroke={2.4} />
							</div>
							<div style={{textAlign: 'center'}}>
								<div style={{fontSize: 28 * S, fontWeight: 700}}>Welcome to eyeOS</div>
								<div style={{fontSize: 17 * S, color: C.secondary, marginTop: 6 * S}}>Looks after your eyes while you work.</div>
							</div>
							<div style={{display: 'flex', flexDirection: 'column', gap: 14 * S}}>
								<Feature color={C.green} icon={<ShieldIcon size={24} color={C.green} />} text="Video stays on your Mac" />
								<Feature color={C.teal} icon={<ClockIcon size={24} color={C.teal} />} text="20-second calibration" />
								<Feature color={C.indigo} icon={<MoonIcon size={24} color={C.indigo} />} text="Silent while you're in deep focus" />
							</div>
							<div style={{flex: 1}} />
							<Button label="Get started" pressed={f >= 20 && f < 24} />
						</div>
					)}
					{page === 1 && (
						<CalibrationPage
							f={f}
							title="Sit back at arm's length"
							subtitle="About 60 cm from the screen. Look at the screen and hold still."
							start={P.distance + 3}
							run={[P.distance + 7, P.gaze - 6]}
							art={
								<div style={{display: 'flex', alignItems: 'center', gap: 18 * S, color: C.text}}>
									<PersonIcon size={86} color="rgba(242,244,247,0.85)" />
									<div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6}}>
										<span style={{color: C.teal, fontSize: 17 * S, fontWeight: 600}}>≈ 60 cm</span>
										<div style={{width: 110 * S, height: 3, background: C.teal, position: 'relative'}}>
											<div style={{position: 'absolute', left: -6, top: -6, borderRight: `10px solid ${C.teal}`, borderTop: '7px solid transparent', borderBottom: '7px solid transparent'}} />
											<div style={{position: 'absolute', right: -6, top: -6, borderLeft: `10px solid ${C.teal}`, borderTop: '7px solid transparent', borderBottom: '7px solid transparent'}} />
										</div>
									</div>
									<LaptopIcon size={96} color="rgba(242,244,247,0.85)" />
								</div>
							}
						/>
					)}
					{page === 2 && (
						<CalibrationPage
							f={f}
							title="Follow the dot"
							subtitle="A dot moves to the center, then the four corners. Follow it with your eyes."
							start={P.gaze + 4}
							run={gazeRun}
							art={
								<div style={{position: 'relative', width: 170 * S, height: 170 * S}}>
									<div style={{position: 'absolute', left: 0, top: 15 * S, width: 170 * S, height: 110 * S, borderRadius: 10 * S, border: '3px solid rgba(255,255,255,0.3)'}} />
									{[{x: 0, y: 0}, {x: -70, y: -40}, {x: 70, y: -40}, {x: 70, y: 40}, {x: -70, y: 40}].map((p, i) => (
										<div
											key={i}
											style={{
												position: 'absolute',
												left: (85 + p.x) * S - (i === 0 ? 11 : 7),
												top: (70 + p.y) * S - (i === 0 ? 11 : 7),
												width: i === 0 ? 22 : 14,
												height: i === 0 ? 22 : 14,
												borderRadius: 11,
												background: i === 0 ? C.teal : C.teal + '66',
											}}
										/>
									))}
									<div style={{position: 'absolute', left: 85 * S - 20, top: 140 * S}}>
										<EyeIcon size={40} color="rgba(242,244,247,0.85)" />
									</div>
								</div>
							}
						/>
					)}
					{page === 3 && (
						<CalibrationPage
							f={f}
							title="Blink 3 times"
							subtitle="Blink 3 times normally, about a second apart. Click Start when you're ready."
							start={P.blink + 3}
							run={[P.blink + 7, P.done - 4]}
							art={
								<div style={{display: 'flex', gap: 22 * S}}>
									{[0, 1, 2].map((i) => {
										const seen = i < blinks;
										return (
											<div key={i} style={{width: 64 * S, height: 64 * S, borderRadius: 32 * S, background: seen ? MINT + '1f' : 'rgba(255,255,255,0.12)', display: 'flex', alignItems: 'center', justifyContent: 'center'}}>
												{seen ? <CheckIcon size={40} color={MINT} /> : <EyeIcon size={40} color="rgba(242,244,247,0.85)" />}
											</div>
										);
									})}
								</div>
							}
						/>
					)}
					{page === 4 && (
						<div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', height: '100%', gap: 20 * S}}>
							<div style={{flex: 1}} />
							<div style={{width: 64 * S, height: 64 * S, borderRadius: 32 * S, background: MINT, display: 'flex', alignItems: 'center', justifyContent: 'center', transform: `scale(${0.7 + settle(f, P.done, 10) * 0.3})`}}>
								<CheckIcon size={44 * S} color="#16181D" stroke={3} />
							</div>
							<div style={{fontSize: 26 * S, fontWeight: 700}}>You're set</div>
							<div style={{display: 'flex', flexDirection: 'column', gap: 10 * S, maxWidth: 400 * S, fontSize: 14 * S, color: C.secondary}}>
								<div style={{display: 'flex', gap: 12, alignItems: 'flex-start'}}>
									<EyeIcon size={30} color={C.secondary} />
									For the next minute eyeOS learns your normal blink rate. Just keep working.
								</div>
								<div style={{display: 'flex', gap: 12, alignItems: 'center'}}>
									<MoonIcon size={28} color={C.secondary} />
									When you're in deep focus, eyeOS goes silent.
								</div>
							</div>
							<div style={{flex: 1}} />
							<Button label="Start using eyeOS" pressed={f >= P.done + 22 && f < P.done + 26} />
						</div>
					)}
				</div>
			</div>

			{overlay > 0 && (
				<AbsoluteFill style={{background: 'rgba(0,0,0,0.9)', opacity: overlay}}>
					<div style={{position: 'absolute', left: dot.x - 21, top: dot.y - 21, width: 42, height: 42, borderRadius: 21, background: C.teal}} />
				</AbsoluteFill>
			)}

			<div style={{opacity: 1 - overlay}}>
				<CursorTrack
					showFrom={2}
					clicks={[20, P.distance + 3, P.gaze + 4, P.blink + 3, P.done + 22]}
					path={[
						{f: 2, x: BUTTON.x + 260, y: BUTTON.y + 140},
						{f: 18, x: BUTTON.x + 140, y: BUTTON.y + 4},
						{f: P.done + 30, x: BUTTON.x + 140, y: BUTTON.y + 4},
					]}
				/>
			</div>
		</AbsoluteFill>
	);
};
