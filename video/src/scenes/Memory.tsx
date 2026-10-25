import React from 'react';
import {useCurrentFrame} from 'remotion';
import {Badge, Card, Pill} from '../components/Card';
import {BrainIcon, BulbIcon, CheckIcon, XIcon} from '../components/Icons';
import {settle} from '../components/motion';
import {C} from '../theme';

const RULES = [
	{at: 8, color: C.green, Icon: CheckIcon, title: 'Blink blur works for you', detail: '+5.6 blinks/min on average · helped 4 of 5 times'},
	{at: 32, color: C.pink, Icon: XIcon, title: "Dark mode didn't help", detail: 'No change in squinting after 3 tries · use it less'},
	{at: 58, color: C.orange, Icon: BulbIcon, title: 'Most of your eye rubs (7 of 9) come after 45+ min without a break', detail: 'Pattern learned this week'},
];

// "maintaining a persistent memory of what's worked and what hasn't," — rules written to memory.
export const Memory: React.FC = () => {
	const f = useCurrentFrame();
	const count = RULES.filter((r) => f >= r.at).length;
	return (
		<Card padding={44} style={{width: 1200}}>
			<div style={{display: 'flex', alignItems: 'center', gap: 24, marginBottom: 18}}>
				<Badge color={C.purple} size={68}>
					<BrainIcon size={38} color={C.purple} />
				</Badge>
				<div style={{flex: 1}}>
					<div style={{fontSize: 38, fontWeight: 700, letterSpacing: -0.4}}>Memory</div>
					<div style={{fontSize: 26, color: C.secondary, marginTop: 4}}>What eyeOS has learned about you</div>
				</div>
				<Pill color={C.purple} style={{fontVariantNumeric: 'tabular-nums', opacity: count > 0 ? 1 : 0}}>{count} new rule{count === 1 ? '' : 's'}</Pill>
			</div>
			{RULES.map((r, i) => {
				const p = settle(f, r.at, 16);
				return (
					<div
						key={r.title}
						style={{
							display: 'flex',
							alignItems: 'center',
							gap: 26,
							padding: '26px 0',
							borderTop: '1.5px solid rgba(255,255,255,0.07)',
							opacity: p,
							transform: `translateX(${(1 - p) * -40}px)`,
						}}
					>
						<Badge color={r.color} size={64}>
							<r.Icon size={36} color={r.color} />
						</Badge>
						<div>
							<div style={{fontSize: 33, fontWeight: 600, lineHeight: 1.25}}>{r.title}</div>
							<div style={{fontSize: 25, color: C.secondary, marginTop: 6}}>{r.detail}</div>
						</div>
					</div>
				);
			})}
		</Card>
	);
};
