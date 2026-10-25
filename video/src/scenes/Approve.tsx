import React from 'react';
import {useCurrentFrame} from 'remotion';
import {Badge, Card} from '../components/Card';
import {CheckIcon, Cursor, EyeIcon} from '../components/Icons';
import {lerp, settle, travel} from '../components/motion';
import {C} from '../theme';

const Button: React.FC<{children: React.ReactNode; bg: string; color?: string; style?: React.CSSProperties}> = ({children, bg, color = C.text, style}) => (
	<div style={{display: 'flex', alignItems: 'center', gap: 10, padding: '14px 30px', borderRadius: 14, background: bg, color, fontSize: 28, fontWeight: 600, ...style}}>
		{children}
	</div>
);

// "After you approve suggestions," — the first-use approval panel, and a click on Allow.
export const Approve: React.FC = () => {
	const f = useCurrentFrame();
	const card = settle(f, 0, 14);
	const move = travel(f, 6, 26);
	const press = f >= 28 && f < 33;
	const allowed = f >= 31;
	const pop = settle(f, 31, 10);
	return (
		<div style={{position: 'relative', transform: `scale(${0.96 + card * 0.04})`, opacity: card}}>
			<Card padding={44} style={{width: 900}}>
				<div style={{display: 'flex', gap: 26, alignItems: 'flex-start'}}>
					<Badge color={C.orange} size={76}>
						<EyeIcon size={42} color={C.orange} />
					</Badge>
					<div style={{flex: 1}}>
						<div style={{fontSize: 40, fontWeight: 700, letterSpacing: -0.4}}>Allow eyeOS to use blink blur?</div>
						<div style={{fontSize: 29, color: C.secondary, marginTop: 12, lineHeight: 1.35}}>
							The screen slowly softens when you stare without blinking. One blink clears it.
						</div>
						<div style={{fontSize: 24, color: C.tertiary, marginTop: 14, lineHeight: 1.35}}>
							Your blink rate has been 6.8/min for 5 minutes, about half your normal 14.
						</div>
					</div>
				</div>
				<div style={{display: 'flex', alignItems: 'center', gap: 16, marginTop: 34}}>
					<Button bg="rgba(255,255,255,0.08)" color={C.secondary}>Never</Button>
					<div style={{flex: 1}} />
					<Button bg="rgba(255,255,255,0.1)">Not now</Button>
					<Button
						bg={allowed ? C.green : C.blue}
						style={{width: 190, justifyContent: 'center', transform: `scale(${press ? 0.94 : 1 + (allowed ? (1 - pop) * 0.06 : 0)})`}}
					>
						{allowed && <CheckIcon size={28} color="#fff" />}
						{allowed ? 'Allowed' : 'Allow'}
					</Button>
				</div>
			</Card>
			<div
				style={{
					position: 'absolute',
					right: 18,
					bottom: 4,
					transform: `translate(${lerp(420, 0, move)}px, ${lerp(240, 0, move)}px) scale(${press ? 0.88 : 1})`,
					opacity: f < 4 ? 0 : 1,
				}}
			>
				<Cursor size={52} />
			</div>
		</div>
	);
};
