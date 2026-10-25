import React from 'react';
import {AbsoluteFill, Img, staticFile} from 'remotion';
import {BrainIcon, CheckIcon, ChartIcon, ClockIcon, EyeIcon, HandIcon, SparklesIcon, TextIcon} from '../components/Icons';
import {C, FONT} from '../theme';
import {GH, GW, Shot, Slide} from './Slide';

const chip = (color: string): React.CSSProperties => ({
	display: 'inline-flex',
	alignItems: 'center',
	gap: 12,
	padding: '14px 30px',
	borderRadius: 999,
	background: color + '24',
	border: `2px solid ${color}55`,
	color,
	fontSize: 30,
	fontWeight: 600,
});

// 1. Title card: the logo, the tagline, and the three design principles.
export const Hero: React.FC = () => (
	<AbsoluteFill style={{background: '#0B0C0F', fontFamily: FONT, color: C.text, alignItems: 'center'}}>
		<Img
			src={staticFile('gallery-src/title.png')}
			style={{position: 'absolute', top: 10, left: (GW - 1440) / 2, width: 1440, height: 810, WebkitMaskImage: 'radial-gradient(ellipse 60% 60% at 50% 50%, #000 55%, transparent 100%)'}}
		/>
		<div style={{position: 'absolute', top: 790, left: 0, right: 0, textAlign: 'center'}}>
			<div style={{fontSize: 52, fontWeight: 600, letterSpacing: -0.6}}>An AI eye-habit coach in your Mac's menu bar</div>
			<div style={{fontSize: 34, color: C.secondary, marginTop: 16}}>Fixes the habits straining your eyes without breaking your focus.</div>
			<div style={{display: 'flex', gap: 22, justifyContent: 'center', marginTop: 56}}>
				<span style={chip(C.teal)}>Unobtrusive</span>
				<span style={chip(C.purple)}>Adaptive</span>
				<span style={chip(C.green)}>Transparent</span>
			</div>
		</div>
	</AbsoluteFill>
);

// A fake editor full of code, for the nudge tiles.
const CODE = [
	'const blinkRate = metrics.blinksPerMinute();',
	'if (blinkRate < baseline * 0.6) {',
	'  agent.wake({ trigger: "low_blink_rate" });',
	'}',
	'',
	'function scoreEyes(m: Metrics): number {',
	'  let score = 100;',
	'  score -= lowBlinkPenalty(m.blinkRate);',
	'  score -= stareSeconds(m) > 10 ? 8 : 0;',
	'  return Math.max(0, score);',
	'}',
];
const Editor: React.FC<{fontSize?: number; blur?: number}> = ({fontSize = 21, blur = 0}) => (
	<div style={{position: 'absolute', inset: 0, background: '#1B1D23', padding: '26px 30px', fontFamily: 'SF Mono, Menlo, monospace', fontSize, lineHeight: 1.6, color: '#C9D1D9', filter: blur ? `blur(${blur}px)` : undefined}}>
		{CODE.map((l, i) => (
			<div key={i} style={{whiteSpace: 'pre'}}>
				<span style={{color: '#5C6370', marginRight: 22}}>{String(i + 1).padStart(2, ' ')}</span>
				{l.replace(/(const|function|let|return|if)/g, '$1')}
			</div>
		))}
	</div>
);
const Hint: React.FC<{icon: React.ReactNode; text: string}> = ({icon, text}) => (
	<div style={{position: 'absolute', left: '50%', top: '50%', transform: 'translate(-50%, -50%)', display: 'flex', alignItems: 'center', gap: 12, padding: '14px 26px', borderRadius: 999, background: 'rgba(40,42,48,0.85)', border: '1.5px solid rgba(255,255,255,0.14)', fontSize: 25, fontWeight: 500, whiteSpace: 'nowrap', color: 'rgba(242,244,247,0.9)'}}>
		{icon}
		{text}
	</div>
);
const Tile: React.FC<{label: string; detail: string; children: React.ReactNode}> = ({label, detail, children}) => (
	<div style={{width: 780}}>
		<div style={{position: 'relative', height: 300, borderRadius: 22, overflow: 'hidden', border: '1.5px solid rgba(255,255,255,0.1)', boxShadow: '0 24px 60px rgba(0,0,0,0.45)'}}>{children}</div>
		<div style={{fontSize: 32, fontWeight: 700, marginTop: 16}}>{label}</div>
		<div style={{fontSize: 24, color: C.secondary, marginTop: 6}}>{detail}</div>
	</div>
);

// 2. The four nudges, as they look on screen.
export const Nudges: React.FC = () => (
	<Slide title="Nudges small enough to work through" sub="Each one clears the moment you fix the habit.">
		<div style={{display: 'grid', gridTemplateColumns: '780px 780px', gap: '36px 60px'}}>
			<Tile label="Stare → the screen softens" detail="A full blink clears it at once; a half blink only halfway.">
				<Editor blur={4} />
				<Hint icon={<EyeIcon size={28} color="rgba(242,244,247,0.9)" />} text="Blink to clear" />
			</Tile>
			<Tile label="Lean in → the edges dim" detail="Sitting back to arm's length clears them.">
				<Editor />
				<div style={{position: 'absolute', inset: 0, background: 'radial-gradient(ellipse at center, transparent 30%, rgba(0,0,0,0.92) 78%)'}} />
				<Hint icon={<span style={{fontSize: 24}}>↩</span>} text="You're leaning in. Sit back to clear" />
			</Tile>
			<Tile label="Squint → bigger text" detail="One tap presses ⌘+. After two yeses in an app, it just does it.">
				<Editor fontSize={21} />
				<div style={{position: 'absolute', zIndex: 2, right: 22, top: 22, width: 400, padding: 22, borderRadius: 18, background: '#2C2E34', border: '1.5px solid rgba(255,255,255,0.12)', boxShadow: '0 16px 40px rgba(0,0,0,0.5)'}}>
					<div style={{display: 'flex', gap: 12, alignItems: 'center', fontSize: 25, fontWeight: 700}}>
						<TextIcon size={28} color={C.teal} />
						Make it bigger?
					</div>
					<div style={{fontSize: 20, color: C.secondary, marginTop: 8}}>You've been squinting at VS Code for a bit.</div>
					<div style={{display: 'flex', gap: 10, justifyContent: 'flex-end', marginTop: 16}}>
						<span style={{padding: '8px 18px', borderRadius: 9, background: 'rgba(255,255,255,0.1)', fontSize: 19}}>Not now</span>
						<span style={{padding: '8px 18px', borderRadius: 9, background: C.blue, fontSize: 19, fontWeight: 600}}>Yes</span>
					</div>
				</div>
			</Tile>
			<Tile label="Rub your eyes → palming instead" detail="Cued about 0.2 s after your fingers arrive. Same relief, no pressure.">
				<Editor />
				<div style={{position: 'absolute', inset: 0, boxShadow: 'inset 0 0 70px 30px rgba(255,159,10,0.75)'}} />
				<Hint icon={<HandIcon size={26} color={C.orange} />} text="Hands at your eyes? Try palming instead" />
			</Tile>
		</div>
	</Slide>
);

// 3. The learning loop: approve → measure → remember → improve → report.
const STEPS = [
	{name: 'Approve', color: C.orange, Icon: CheckIcon, text: 'You allow each new kind of action once, or block it for good.'},
	{name: 'Measure', color: C.teal, Icon: ChartIcon, text: 'Eye metrics 2 min before vs. 3 min after every nudge.'},
	{name: 'Remember', color: C.purple, Icon: BrainIcon, text: 'What helped, what you declined, and what comes before your habits.'},
	{name: 'Improve', color: C.green, Icon: ClockIcon, text: 'The fixes that work for you come first, timed before the habit starts.'},
	{name: 'Report', color: C.teal, Icon: SparklesIcon, text: 'A daily summary and your eye score over the week.'},
];
export const Loop: React.FC = () => {
	const cx = GW / 2;
	const cy = 470;
	const r = 330;
	const pos = STEPS.map((_, i) => {
		const a = -Math.PI / 2 + (i / STEPS.length) * Math.PI * 2;
		return {x: cx + Math.cos(a) * r * 1.45, y: cy + Math.sin(a) * r};
	});
	return (
		<Slide title="It learns what works for you" sub="Every nudge is checked against what your eyes did next.">
			<div style={{position: 'absolute', inset: 0}}>
				<svg width={GW} height={GH - 270} style={{position: 'absolute', left: 0, top: 0}}>
					<defs>
						<marker id="arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto">
							<path d="M0 0L10 5L0 10z" fill="rgba(255,255,255,0.35)" />
						</marker>
					</defs>
					<ellipse cx={cx} cy={cy} rx={r * 1.45} ry={r} fill="none" stroke="rgba(255,255,255,0.12)" strokeWidth={3} strokeDasharray="10 14" />
					{STEPS.map((_, i) => {
						// midway between two steps on the ellipse, pointing along it (clockwise)
						const a = -Math.PI / 2 + ((i + 0.5) / STEPS.length) * Math.PI * 2;
						const x = cx + Math.cos(a) * r * 1.45;
						const y = cy + Math.sin(a) * r;
						const ang = (Math.atan2(Math.cos(a) * r, -Math.sin(a) * r * 1.45) * 180) / Math.PI;
						return <path key={i} d="M-9 -13 L7 0 L-9 13" transform={`translate(${x} ${y}) rotate(${ang})`} fill="none" stroke="rgba(255,255,255,0.55)" strokeWidth={5} strokeLinecap="round" strokeLinejoin="round" />;
					})}
				</svg>
				<div style={{position: 'absolute', left: cx - 170, top: cy - 80, width: 340, textAlign: 'center'}}>
					<EyeIcon size={64} color={C.teal} />
					<div style={{fontSize: 34, fontWeight: 700, marginTop: 8}}>Persistent memory</div>
					<div style={{fontSize: 22, color: C.secondary, marginTop: 6}}>Every session starts from what eyeOS already knows about you.</div>
				</div>
				{STEPS.map((s, i) => (
					<div key={s.name} style={{position: 'absolute', left: pos[i].x - 190, top: pos[i].y - 78, width: 380, padding: '22px 24px', borderRadius: 22, background: '#1A1D23', border: `2px solid ${s.color}66`, boxShadow: '0 20px 50px rgba(0,0,0,0.4)'}}>
						<div style={{display: 'flex', alignItems: 'center', gap: 14}}>
							<div style={{width: 46, height: 46, borderRadius: 14, background: s.color + '29', display: 'flex', alignItems: 'center', justifyContent: 'center'}}>
								<s.Icon size={26} color={s.color} />
							</div>
							<span style={{fontSize: 30, fontWeight: 700}}>{s.name}</span>
						</div>
						<div style={{fontSize: 21, color: C.secondary, marginTop: 10, lineHeight: 1.35}}>{s.text}</div>
					</div>
				))}
			</div>
		</Slide>
	);
};

// 4–5. The Agent and Log tabs.
export const AgentShot: React.FC = () => (
	<Slide title="Every decision, explained" sub="The Agent tab shows Claude's reasoning, its actions, and how often each fix helped.">
		<Shot src="gallery-src/agent.png" width={1580} crop={{x: 30, y: 30, w: 1860, h: 1040}} />
	</Slide>
);
export const LogShot: React.FC = () => (
	<Slide title="Rewind your whole day" sub="Drag across the timeline to see what happened, when, and why.">
		<Shot src="gallery-src/log.png" width={1580} crop={{x: 30, y: 30, w: 1860, h: 1040}} />
	</Slide>
);

// 6. What stays on the Mac and what reaches the cloud.
const Node: React.FC<{title: string; sub: string; color: string; icon?: React.ReactNode}> = ({title, sub, color, icon}) => (
	<div style={{padding: '20px 24px', borderRadius: 18, background: 'rgba(255,255,255,0.04)', border: `2px solid ${color}55`, display: 'flex', gap: 16, alignItems: 'center'}}>
		{icon && <div style={{width: 50, height: 50, borderRadius: 14, background: color + '26', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0}}>{icon}</div>}
		<div>
			<div style={{fontSize: 27, fontWeight: 700}}>{title}</div>
			<div style={{fontSize: 20, color: C.secondary, marginTop: 4, lineHeight: 1.3}}>{sub}</div>
		</div>
	</div>
);
export const Privacy: React.FC = () => (
	<Slide title="Private by design" sub="Each model sees only what it needs. Camera frames never leave your Mac.">
		<div style={{display: 'flex', alignItems: 'center', gap: 0, marginTop: 10}}>
			<div style={{width: 760, padding: 34, borderRadius: 28, background: 'rgba(48,209,88,0.05)', border: `2px solid ${C.green}55`}}>
				<div style={{fontSize: 32, fontWeight: 700, color: C.green, marginBottom: 22}}>On your Mac</div>
				<div style={{display: 'flex', flexDirection: 'column', gap: 16}}>
					<Node title="Detection · every frame" sub="OpenCV + MediaPipe face, hands, pose → blinks, distance, posture, rubs" color={C.teal} icon={<EyeIcon size={28} color={C.teal} />} />
					<Node title="Conductor · Gemma 4" sub="Reads a screenshot every 30 s, decides focus, Zen, and when a nudge may fire. Screenshots are wiped after." color={C.indigo} icon={<ClockIcon size={28} color={C.indigo} />} />
					<Node title="Actions + memory" sub="Overlays, macOS settings, voice playback, learned rules" color={C.green} icon={<BrainIcon size={28} color={C.green} />} />
				</div>
			</div>
			<div style={{width: 250, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14}}>
				<div style={{fontSize: 22, color: C.secondary, textAlign: 'center', lineHeight: 1.35}}>
					numbers, app name,<br />short text
				</div>
				<svg width={200} height={40}>
					<path d="M10 20 H180" stroke={C.secondary} strokeWidth={4} strokeLinecap="round" />
					<path d="M168 8 L186 20 L168 32" fill="none" stroke={C.secondary} strokeWidth={4} strokeLinecap="round" strokeLinejoin="round" />
				</svg>
				<div style={{fontSize: 22, color: C.pink, fontWeight: 600, textAlign: 'center'}}>no images</div>
			</div>
			<div style={{width: 600, padding: 34, borderRadius: 28, background: 'rgba(191,90,242,0.05)', border: `2px solid ${C.purple}55`}}>
				<div style={{fontSize: 32, fontWeight: 700, color: C.purple, marginBottom: 22}}>Cloud</div>
				<div style={{display: 'flex', flexDirection: 'column', gap: 16}}>
					<Node title="Claude Sonnet 5.5" sub="Picks the smallest fix that should work, through an approval gate" color={C.purple} icon={<BrainIcon size={28} color={C.purple} />} />
					<Node title="Cartesia Sonic 3" sub="Voices exercises and read-aloud, cached as audio on your Mac" color={C.teal} icon={<SparklesIcon size={28} color={C.teal} />} />
				</div>
			</div>
		</div>
	</Slide>
);

// 7. The daily report.
export const ReportShot: React.FC = () => (
	<Slide title="See your progress" sub="Daily summaries in plain words, and your eye score over the week.">
		<Shot src="gallery-src/report.png" width={1300} crop={{x: 330, y: 170, w: 1260, h: 820}} />
	</Slide>
);
