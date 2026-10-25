import React from 'react';
import {C} from '../theme';

// The dashboard card look: soft fill, hairline border, optional accent border.
export const Card: React.FC<{children: React.ReactNode; accent?: string; padding?: number; style?: React.CSSProperties}> = ({
	children,
	accent,
	padding = 36,
	style,
}) => (
	<div
		style={{
			background: C.card,
			border: `1.5px solid ${accent ? accent + '80' : C.cardBorder}`,
			borderRadius: 28,
			padding,
			boxShadow: '0 30px 80px rgba(0,0,0,0.35)',
			...style,
		}}
	>
		{children}
	</div>
);

// Tinted icon badge, like the Log page's card icons.
export const Badge: React.FC<{color: string; size?: number; children: React.ReactNode}> = ({color, size = 64, children}) => (
	<div
		style={{
			width: size,
			height: size,
			borderRadius: size * 0.3,
			background: color + '29',
			display: 'flex',
			alignItems: 'center',
			justifyContent: 'center',
			flexShrink: 0,
		}}
	>
		{children}
	</div>
);

export const Pill: React.FC<{color: string; children: React.ReactNode; style?: React.CSSProperties}> = ({color, children, style}) => (
	<div
		style={{
			display: 'inline-flex',
			alignItems: 'center',
			gap: 10,
			padding: '10px 22px',
			borderRadius: 999,
			background: color + '29',
			color,
			fontSize: 26,
			fontWeight: 600,
			...style,
		}}
	>
		{children}
	</div>
);
