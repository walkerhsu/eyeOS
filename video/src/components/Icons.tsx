import React from 'react';

type P = {size?: number; color: string; stroke?: number};

export const EyeIcon: React.FC<P> = ({size = 24, color, stroke = 2.2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
		<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z" />
		<circle cx="12" cy="12" r="3" fill={color} />
	</svg>
);

export const CheckIcon: React.FC<P> = ({size = 24, color, stroke = 2.6}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
		<path d="M5 12.5l4.5 4.5L19 7.5" />
	</svg>
);

export const XIcon: React.FC<P> = ({size = 24, color, stroke = 2.6}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round">
		<path d="M7 7l10 10M17 7L7 17" />
	</svg>
);

export const BulbIcon: React.FC<P> = ({size = 24, color, stroke = 2.2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
		<path d="M9 18h6M10 21h4M12 3a6 6 0 0 0-3.6 10.8c.6.5 1 1.2 1 2V16h5.2v-.2c0-.8.4-1.5 1-2A6 6 0 0 0 12 3z" />
	</svg>
);

export const BrainIcon: React.FC<P> = ({size = 24, color, stroke = 2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
		<path d="M9.5 4A2.5 2.5 0 0 0 7 6.5 3 3 0 0 0 4.5 11a3 3 0 0 0 1 5A3 3 0 0 0 9.5 20 2.5 2.5 0 0 0 12 17.5v-11A2.5 2.5 0 0 0 9.5 4z" />
		<path d="M14.5 4A2.5 2.5 0 0 1 17 6.5a3 3 0 0 1 2.5 4.5 3 3 0 0 1-1 5 3 3 0 0 1-4 4 2.5 2.5 0 0 1-2.5-2.5" />
	</svg>
);

export const SparklesIcon: React.FC<P> = ({size = 24, color}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill={color}>
		<path d="M10 3l1.6 4.6L16 9.2l-4.4 1.6L10 15.4 8.4 10.8 4 9.2l4.4-1.6zM18 13l.9 2.3 2.1.8-2.1.8L18 19.2l-.9-2.3-2.1-.8 2.1-.8z" />
	</svg>
);

export const ClockIcon: React.FC<P> = ({size = 24, color, stroke = 2.2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round">
		<circle cx="12" cy="12" r="9" />
		<path d="M12 7v5l3 2" />
	</svg>
);

export const ChartIcon: React.FC<P> = ({size = 24, color, stroke = 2.2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
		<path d="M4 19h16M6 15l4-4 3 3 5-6" />
	</svg>
);

export const Cursor: React.FC<{size?: number}> = ({size = 44}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" style={{filter: 'drop-shadow(0 3px 6px rgba(0,0,0,0.5))'}}>
		<path d="M5 3l14 8.2-6.2 1.3L16 19.5l-2.6 1.2-3.2-6.9L5 18z" fill="#fff" stroke="#000" strokeWidth={1.2} strokeLinejoin="round" />
	</svg>
);

export const BoltIcon: React.FC<P> = ({size = 24, color}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill={color}>
		<path d="M13 2L4 14h7l-1 8 9-12h-7z" />
	</svg>
);

export const WrenchIcon: React.FC<P> = ({size = 24, color, stroke = 2.2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
		<path d="M14.7 6.3a4 4 0 0 0 5 5L21 13l-8 8-3-3 6.7-6.7M14.7 6.3L13 4.6a4 4 0 0 0-5 5L3 14.6 6 17.6l5-5" />
	</svg>
);

export const HandIcon: React.FC<P> = ({size = 24, color, stroke = 2.1}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
		<path d="M8 13V5.5a1.5 1.5 0 0 1 3 0V12M11 11V4a1.5 1.5 0 0 1 3 0v7M14 11V5.5a1.5 1.5 0 0 1 3 0V14c0 4-2.5 7-6.5 7-3 0-4.5-1.5-6-4.5L3 13.5a1.5 1.5 0 0 1 2.5-1.6L8 15" />
	</svg>
);

export const SealIcon: React.FC<P> = ({size = 24, color, stroke = 2.2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
		<circle cx="12" cy="12" r="9" />
		<path d="M8 12.3l2.8 2.7L16 9.6" />
	</svg>
);

export const TextIcon: React.FC<P> = ({size = 24, color, stroke = 2.2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
		<path d="M3 19l5-13 5 13M4.8 14.5h6.4M14 19l3.5-8.5L21 19M15 16.5h5" />
	</svg>
);

export const TokensIcon: React.FC<P> = ({size = 24, color, stroke = 2.2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round">
		<path d="M4 7h16M4 12h10M4 17h13" />
	</svg>
);

export const DropIcon: React.FC<P> = ({size = 24, color, stroke = 2.2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinejoin="round">
		<circle cx="12" cy="12" r="9" />
		<path d="M12 7c2 2.6 3 4.3 3 5.6a3 3 0 0 1-6 0C9 11.3 10 9.6 12 7z" fill={color} />
	</svg>
);

export const MoonIcon: React.FC<P> = ({size = 24, color}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill={color}>
		<path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z" />
	</svg>
);

export const WalkIcon: React.FC<P> = ({size = 24, color, stroke = 2.2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
		<circle cx="13" cy="4" r="1.8" fill={color} />
		<path d="M10 21l2.5-6 2.5 2v4M12.5 15l-1-5 3 2 3 .5M11.5 10L8 12l-1 3" />
	</svg>
);

export const DisplayIcon: React.FC<P> = ({size = 24, color, stroke = 2.2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
		<rect x="3" y="4" width="18" height="12" rx="2" />
		<path d="M9 20h6M12 16v4" />
	</svg>
);

export const GaugeIcon: React.FC<P> = ({size = 24, color, stroke = 2.2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round">
		<path d="M4 17a8 8 0 1 1 16 0" />
		<path d="M12 17l4-5" />
	</svg>
);

export const ListIcon: React.FC<P> = ({size = 24, color, stroke = 2.2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round">
		<path d="M9 6h11M9 12h11M9 18h11" />
		<circle cx="4.5" cy="6" r="1" fill={color} />
		<circle cx="4.5" cy="12" r="1" fill={color} />
		<circle cx="4.5" cy="18" r="1" fill={color} />
	</svg>
);

export const GearIcon: React.FC<P> = ({size = 24, color, stroke = 2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
		<circle cx="12" cy="12" r="3" />
		<path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1" />
	</svg>
);

export const SearchIcon: React.FC<P> = ({size = 24, color, stroke = 2.2}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round">
		<circle cx="10.5" cy="10.5" r="6" />
		<path d="M15 15l5 5" />
	</svg>
);

export const PlayIcon: React.FC<P> = ({size = 24, color}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill={color}>
		<path d="M7 4.5v15l12.5-7.5z" />
	</svg>
);

export const ChevronIcon: React.FC<P & {rotate?: number}> = ({size = 24, color, stroke = 2.4, rotate = 0}) => (
	<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round" style={{transform: `rotate(${rotate}deg)`}}>
		<path d="M9 5l7 7-7 7" />
	</svg>
);
