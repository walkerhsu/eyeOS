import React from 'react';
import {C} from '../theme';
import {BrainIcon, GaugeIcon, GearIcon, ListIcon} from './Icons';

// Window geometry in the 1920×1080 frame, so scenes can aim the cursor at things inside it.
export const WIN = {x: 60, y: 46, w: 1800, h: 988, titlebar: 52, sidebar: 260, pad: 36};
export const CONTENT = {x: WIN.x + WIN.sidebar + WIN.pad, y: WIN.y + WIN.titlebar + 30, right: WIN.x + WIN.w - WIN.pad};
export const SIDEBAR_ITEM = (i: number) => ({x: WIN.x + 130, y: WIN.y + WIN.titlebar + 20 + i * 56 + 26});

const PAGES = [
	{name: 'Live', Icon: GaugeIcon},
	{name: 'Log', Icon: ListIcon},
	{name: 'Agent', Icon: BrainIcon},
	{name: 'Settings', Icon: GearIcon},
];

// The eyeOS main window: dark title bar, sidebar (Live, Log, Agent, Settings), and the page.
export const AppWindow: React.FC<{page: 'Live' | 'Log' | 'Agent'; children: React.ReactNode}> = ({page, children}) => (
	<div
		style={{
			position: 'absolute',
			left: WIN.x,
			top: WIN.y,
			width: WIN.w,
			height: WIN.h,
			borderRadius: 22,
			overflow: 'hidden',
			background: '#16181D',
			border: '1.5px solid rgba(255,255,255,0.12)',
			boxShadow: '0 40px 120px rgba(0,0,0,0.6)',
		}}
	>
		<div style={{position: 'absolute', left: 0, top: 0, right: 0, height: WIN.titlebar, display: 'flex', alignItems: 'center', gap: 12, paddingLeft: 24}}>
			{['#FF5F57', '#FEBC2E', '#28C840'].map((c) => (
				<div key={c} style={{width: 16, height: 16, borderRadius: 8, background: c}} />
			))}
		</div>
		<div
			style={{
				position: 'absolute',
				left: 0,
				top: 0,
				bottom: 0,
				width: WIN.sidebar,
				paddingTop: WIN.titlebar + 20,
				background: 'rgba(255,255,255,0.035)',
				borderRight: '1.5px solid rgba(255,255,255,0.07)',
			}}
		>
			{PAGES.map(({name, Icon}) => {
				const on = name === page;
				return (
					<div
						key={name}
						style={{
							margin: '0 14px 4px',
							height: 52,
							borderRadius: 12,
							display: 'flex',
							alignItems: 'center',
							gap: 14,
							paddingLeft: 16,
							fontSize: 25,
							fontWeight: on ? 600 : 500,
							color: on ? C.text : C.secondary,
							background: on ? 'rgba(255,255,255,0.11)' : 'transparent',
						}}
					>
						<Icon size={26} color={on ? C.blue : C.secondary} />
						{name}
					</div>
				);
			})}
			<div style={{position: 'absolute', bottom: 22, left: 26, display: 'flex', alignItems: 'center', gap: 10, fontSize: 17, color: C.secondary}}>
				<div style={{width: 10, height: 10, borderRadius: 5, background: C.green}} />
				sidecar connected
			</div>
		</div>
		<div style={{position: 'absolute', left: WIN.sidebar, top: WIN.titlebar, right: 0, bottom: 0, padding: `30px ${WIN.pad}px 0`, overflow: 'hidden'}}>{children}</div>
	</div>
);

// Page title bar: big title, subtitle, controls on the right.
export const AppBar: React.FC<{title: string; children?: React.ReactNode}> = ({title, children}) => (
	<div style={{display: 'flex', alignItems: 'center', height: 72, marginBottom: 20}}>
		<div>
			<div style={{fontSize: 44, fontWeight: 700, letterSpacing: -0.5, lineHeight: 1.05}}>{title}</div>
			<div style={{fontSize: 21, color: C.secondary, marginTop: 4}}>Today</div>
		</div>
		<div style={{flex: 1}} />
		<div style={{display: 'flex', gap: 14, alignItems: 'center'}}>
			<div style={{padding: '10px 18px', borderRadius: 10, background: 'rgba(255,255,255,0.08)', fontSize: 21, color: C.secondary}}>10/24/2026</div>
			{children}
		</div>
	</div>
);

// A macOS-style push button.
export const MacButton: React.FC<{children: React.ReactNode}> = ({children}) => (
	<div
		style={{
			display: 'flex',
			alignItems: 'center',
			gap: 10,
			padding: '11px 22px',
			borderRadius: 10,
			background: 'rgba(255,255,255,0.12)',
			fontSize: 21,
			fontWeight: 500,
		}}
	>
		{children}
	</div>
);

// The app's small inline card: soft fill, hairline border.
export const Panel: React.FC<{children: React.ReactNode; accent?: string; style?: React.CSSProperties}> = ({children, accent, style}) => (
	<div
		style={{
			background: 'rgba(255,255,255,0.045)',
			border: `1.5px solid ${accent ?? 'rgba(255,255,255,0.08)'}`,
			borderRadius: 18,
			...style,
		}}
	>
		{children}
	</div>
);
