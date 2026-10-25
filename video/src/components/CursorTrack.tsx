import React from 'react';
import {Easing, interpolate, useCurrentFrame} from 'remotion';
import {Cursor} from './Icons';

export type Waypoint = {f: number; x: number; y: number};

// A cursor that glides between waypoints (frame + tip position) and dips on each click frame.
export const CursorTrack: React.FC<{path: Waypoint[]; clicks?: number[]; showFrom?: number}> = ({path, clicks = [], showFrom = 0}) => {
	const f = useCurrentFrame();
	const frames = path.map((p) => p.f);
	const opts = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.inOut(Easing.cubic)} as const;
	// interpolate segment by segment so each move eases on its own
	let x = path[0].x;
	let y = path[0].y;
	for (let i = 0; i < path.length - 1; i++) {
		if (f >= frames[i]) {
			x = interpolate(f, [frames[i], frames[i + 1]], [path[i].x, path[i + 1].x], opts);
			y = interpolate(f, [frames[i], frames[i + 1]], [path[i].y, path[i + 1].y], opts);
		}
	}
	const pressed = clicks.some((c) => f >= c && f < c + 4);
	const appear = interpolate(f, [showFrom, showFrom + 6], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
	return (
		<div style={{position: 'absolute', left: x - 11, top: y - 6, opacity: appear, transform: `scale(${pressed ? 0.86 : 1})`, transformOrigin: '11px 6px'}}>
			<Cursor size={52} />
		</div>
	);
};
