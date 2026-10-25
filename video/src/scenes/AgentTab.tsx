import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {AppBar, AppWindow, CONTENT, MacButton, Panel} from '../components/AppWindow';
import {CursorTrack} from '../components/CursorTrack';
import {BoltIcon, BrainIcon, CheckIcon, ClockIcon, DropIcon, HandIcon, MoonIcon, PlayIcon, SealIcon, TextIcon, TokensIcon, WalkIcon, WrenchIcon} from '../components/Icons';
import {ramp, settle} from '../components/motion';
import {C} from '../theme';
import {AGENT_TAB, FPS} from '../timing';

const T = {cards: AGENT_TAB.cards * FPS, reasoning: AGENT_TAB.reasoning * FPS, helped: AGENT_TAB.helped * FPS};

const STATS = [
	{title: 'Runs', value: 14, fmt: (v: number) => `${Math.round(v)}`, sub: 'no errors', Icon: BrainIcon, color: C.purple},
	{title: 'Tool calls', value: 17, fmt: (v: number) => `${Math.round(v)}`, sub: '16 executed', Icon: WrenchIcon, color: C.teal},
	{title: 'Approvals', value: 6, fmt: (v: number) => `${Math.round(v)}/7`, sub: 'allowed', Icon: HandIcon, color: C.orange},
	{title: 'Outcomes', value: 9, fmt: (v: number) => `${Math.round(v)}/15`, sub: 'helped', Icon: SealIcon, color: C.green},
	{title: 'Latency', value: 5.4, fmt: (v: number) => `${v.toFixed(1)} s`, sub: 'mean per run', Icon: ClockIcon, color: C.blue},
	{title: 'Tokens', value: 82, fmt: (v: number) => `${Math.round(v)}k`, sub: '5,140 out', Icon: TokensIcon, color: C.indigo},
];

const CHIPS = [
	{name: 'Blink blur', Icon: DropIcon, uses: 5, helped: '4/5'},
	{name: 'Dark mode', Icon: MoonIcon, uses: 3, helped: '0/3'},
	{name: 'Text size', Icon: TextIcon, uses: 3, helped: '2/3'},
	{name: 'Look away', Icon: WalkIcon, uses: 4, helped: '3/4'},
];

// Fixed layout, so the cursor can aim: AppBar 72 + 20, stats 124 + 18, chips 52 + 18.
const CHIPS_Y = CONTENT.y + 92 + 124 + 18;
const TOGGLE = {x: CONTENT.right - 32, y: CHIPS_Y + 26};
const BLUR_CHIP = {x: CONTENT.x + 135, y: CHIPS_Y + 26};

const Trigger: React.FC<{children: React.ReactNode; icon?: React.ReactNode}> = ({children, icon}) => (
	<div style={{display: 'flex', alignItems: 'center', gap: 7, padding: '5px 14px', borderRadius: 999, background: 'rgba(255,214,10,0.12)', color: 'rgba(255,214,10,0.92)', fontSize: 19, fontWeight: 500}}>
		{icon ?? <BoltIcon size={16} color="rgba(255,214,10,0.92)" />}
		{children}
	</div>
);

const Helped: React.FC = () => (
	<div style={{display: 'flex', alignItems: 'center', gap: 6, padding: '6px 14px', borderRadius: 999, background: C.green + '29', color: C.green, fontSize: 19, fontWeight: 600}}>
		<CheckIcon size={18} color={C.green} />
		Helped
	</div>
);

const RunHeader: React.FC<{time: string; triggers: React.ReactNode; stats: string}> = ({time, triggers, stats}) => (
	<div style={{display: 'flex', alignItems: 'center', gap: 12}}>
		<span style={{fontSize: 23, fontWeight: 600, fontVariantNumeric: 'tabular-nums'}}>{time}</span>
		{triggers}
		<div style={{flex: 1}} />
		<div style={{display: 'flex', alignItems: 'center', gap: 6, padding: '5px 14px', borderRadius: 999, background: 'rgba(255,255,255,0.1)', fontSize: 18, color: C.secondary}}>
			<CheckIcon size={16} color={C.secondary} />
			Finished
		</div>
		<span style={{fontSize: 17, color: C.tertiary, fontVariantNumeric: 'tabular-nums'}}>{stats}</span>
	</div>
);

const ActionRow: React.FC<{icon: React.ReactNode; title: string; change: string}> = ({icon, title, change}) => (
	<div style={{display: 'flex', alignItems: 'center', gap: 16, padding: '14px 18px', borderRadius: 14, background: 'rgba(255,255,255,0.04)', border: '1.5px solid rgba(255,255,255,0.07)'}}>
		<div style={{width: 40, height: 40, borderRadius: 20, background: C.green + '24', display: 'flex', alignItems: 'center', justifyContent: 'center'}}>{icon}</div>
		<div style={{flex: 1}}>
			<div style={{fontSize: 22, fontWeight: 600}}>{title}</div>
			<div style={{fontSize: 18, color: C.secondary, marginTop: 2, fontVariantNumeric: 'tabular-nums'}}>
				{change} <span style={{color: C.tertiary}}>· Approval: approved</span>
			</div>
		</div>
		<Helped />
	</div>
);

const ACTIONS_LABEL: React.CSSProperties = {fontSize: 16, fontWeight: 700, letterSpacing: 1.2, color: C.tertiary, margin: '18px 0 10px'};

// "The Agent tab shows every decision Claude made, with its reasoning and how often each fix actually helped."
export const AgentTab: React.FC = () => {
	const f = useCurrentFrame();
	const win = ramp(f, 0, 8);
	const toggled = f >= T.reasoning + 15;
	const reasoning = settle(f, T.reasoning + 15, 16);
	const selected = f >= T.helped + 14;
	const filter = settle(f, T.helped + 16, 14);
	const glow = ramp(f, T.helped + 10, T.helped + 22);
	const card = (i: number) => settle(f, T.cards + i * 7, 16);

	return (
		<AbsoluteFill style={{transform: `scale(${1 + f * 0.00012})`}}>
			<div style={{opacity: win, transform: `translateY(${(1 - win) * 20}px)`}}>
				<AppWindow page="Agent">
					<AppBar title="Agent">
						<MacButton>
							<PlayIcon size={18} color={C.text} />
							Run now
						</MacButton>
					</AppBar>

					<div style={{display: 'flex', gap: 14, height: 124, marginBottom: 18}}>
						{STATS.map((s, i) => {
							const p = settle(f, 2 + i * 2, 14);
							const v = s.value * ramp(f, 4 + i * 2, 26 + i * 2);
							const lit = s.title === 'Outcomes' ? glow : 0;
							return (
								<Panel
									key={s.title}
									accent={lit > 0 ? `rgba(48,209,88,${0.08 + lit * 0.5})` : undefined}
									style={{flex: 1, padding: '16px 20px', opacity: p, transform: `translateY(${(1 - p) * 16}px)`, background: lit ? `rgba(48,209,88,${lit * 0.08})` : undefined}}
								>
									<div style={{display: 'flex', alignItems: 'center', gap: 8, fontSize: 18, color: C.secondary}}>
										<s.Icon size={18} color={s.color} />
										{s.title}
									</div>
									<div style={{fontSize: 36, fontWeight: 700, fontVariantNumeric: 'tabular-nums', marginTop: 6}}>{s.fmt(v)}</div>
									<div style={{fontSize: 16, color: C.tertiary}}>{s.sub}</div>
								</Panel>
							);
						})}
					</div>

					<div style={{display: 'flex', alignItems: 'center', gap: 12, height: 52, marginBottom: 18, opacity: ramp(f, 10, 20)}}>
						{CHIPS.map((c) => {
							const on = selected && c.name === 'Blink blur';
							return (
								<div
									key={c.name}
									style={{
										height: 48,
										padding: '0 20px',
										whiteSpace: 'nowrap',
										display: 'flex',
										alignItems: 'center',
										justifyContent: 'center',
										gap: 9,
										borderRadius: 999,
										fontSize: 19,
										background: on ? 'rgba(64,200,224,0.25)' : 'rgba(255,255,255,0.05)',
										border: `1.5px solid ${on ? 'rgba(64,200,224,0.6)' : 'rgba(255,255,255,0.08)'}`,
									}}
								>
									<c.Icon size={20} color={C.teal} />
									{c.name}
									<b>×{c.uses}</b>
									<span style={{color: glow > 0.5 ? (c.helped.startsWith('0') ? C.pink : C.green) : C.secondary, fontSize: 17, fontWeight: glow > 0.5 ? 600 : 400}}>{c.helped} helped</span>
								</div>
							);
						})}
						<div style={{flex: 1}} />
						<span style={{fontSize: 19, color: C.secondary, whiteSpace: 'nowrap'}}>Expand reasoning</span>
						<div style={{width: 60, height: 34, borderRadius: 17, background: toggled ? C.green : 'rgba(255,255,255,0.16)', position: 'relative'}}>
							<div style={{position: 'absolute', top: 3, left: toggled ? 29 : 3, width: 28, height: 28, borderRadius: 14, background: '#fff'}} />
						</div>
					</div>

					<div style={{display: 'flex', flexDirection: 'column', gap: 14}}>
						<Panel style={{padding: 24, opacity: card(0), transform: `translateY(${(1 - card(0)) * 24}px)`}}>
							<RunHeader time="14:36" stats="5.8 s · 6,120/410 tok" triggers={<><Trigger>Low blink rate 6.8/min</Trigger><Trigger>Long stare 24 s</Trigger></>} />
							<div style={{fontSize: 25, fontWeight: 600, marginTop: 16, lineHeight: 1.35}}>
								Your blink rate has been about half your normal for 5 minutes, so I turned on blink blur.
							</div>
							<div style={{fontSize: 21, color: C.secondary, marginTop: 8, lineHeight: 1.4}}>
								Blink pulses only helped 2 of 5 times today, while blink blur helped 4 of 5. You're coding, so I picked the cue that doesn't interrupt.
							</div>
							<div style={ACTIONS_LABEL}>ACTIONS</div>
							<ActionRow icon={<DropIcon size={24} color={C.green} />} title="Blink blur on" change="Blink rate 6.8 → 12.4 /min" />
							<div style={{maxHeight: reasoning * 200, opacity: reasoning, overflow: 'hidden'}}>
								<div style={{marginTop: 14, padding: '16px 20px', borderRadius: 14, background: 'rgba(191,90,242,0.08)'}}>
									<div style={{display: 'flex', alignItems: 'center', gap: 8, fontSize: 19, fontWeight: 600, color: C.purple}}>
										<BrainIcon size={20} color={C.purple} />
										Reasoning summary
									</div>
									<div style={{fontSize: 19, color: C.secondary, marginTop: 8, lineHeight: 1.45}}>
										Blink rate 6.8/min vs. baseline 14 for 5 min; longest stare 24 s. Conductor: coding, interruptible. Memory: blink blur helped 4/5, blink pulse 2/5. Pick the least disruptive fix that works for this user → blink blur.
									</div>
								</div>
							</div>
						</Panel>

						<div style={{opacity: 1 - filter, maxHeight: (1 - filter) * 900, overflow: 'hidden', display: 'flex', flexDirection: 'column', gap: 14}}>
							<Panel style={{padding: 24, opacity: card(1), transform: `translateY(${(1 - card(1)) * 24}px)`}}>
								<RunHeader time="13:05" stats="4.1 s · 5,870/302 tok" triggers={<Trigger>Squinting 38 s</Trigger>} />
								<div style={{fontSize: 25, fontWeight: 600, marginTop: 16}}>You've been squinting at small text in VS Code, so I made it bigger.</div>
								<div style={ACTIONS_LABEL}>ACTIONS</div>
								<ActionRow icon={<TextIcon size={24} color={C.green} />} title="Text bigger" change="Squint 0.42 → 0.18" />
							</Panel>
							<Panel style={{padding: 24, opacity: card(2), transform: `translateY(${(1 - card(2)) * 24}px)`}}>
								<RunHeader time="11:47" stats="3.2 s · 5,410/188 tok" triggers={<Trigger icon={<ClockIcon size={16} color="rgba(255,214,10,0.92)" />}>Heartbeat</Trigger>} />
								<div style={{fontSize: 25, fontWeight: 600, marginTop: 16}}>You're in a meeting and your eyes look fine, so I'm waiting.</div>
							</Panel>
						</div>
					</div>
				</AppWindow>
			</div>
			<CursorTrack
				showFrom={T.reasoning - 12}
				clicks={[T.reasoning + 12, T.helped + 11]}
				path={[
					{f: T.reasoning - 12, x: 1500, y: 860},
					{f: T.reasoning + 10, x: TOGGLE.x, y: TOGGLE.y},
					{f: T.helped - 6, x: TOGGLE.x, y: TOGGLE.y},
					{f: T.helped + 9, x: BLUR_CHIP.x, y: BLUR_CHIP.y},
					{f: T.helped + 60, x: BLUR_CHIP.x + 20, y: BLUR_CHIP.y + 30},
				]}
			/>
		</AbsoluteFill>
	);
};
