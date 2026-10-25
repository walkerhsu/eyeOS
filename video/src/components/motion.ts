import type {CSSProperties} from 'react';
import {Easing, interpolate, spring} from 'remotion';
import {FPS} from '../timing';

// Ease-out ramp from 0 to 1 between two frames.
export const ramp = (frame: number, start: number, end: number) =>
	interpolate(frame, [start, end], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic)});

// Ease-in-out ramp, for things that travel (cursor, reordering rows).
export const travel = (frame: number, start: number, end: number) =>
	interpolate(frame, [start, end], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.inOut(Easing.cubic)});

// A calm spring (no overshoot) that starts at `delay`.
export const settle = (frame: number, delay = 0, durationInFrames = 18) =>
	spring({frame: frame - delay, fps: FPS, durationInFrames, config: {damping: 200}});

// A fade-and-rise entrance.
export const rise = (p: number, dy = 28): CSSProperties => ({
	opacity: p,
	transform: `translateY(${(1 - p) * dy}px)`,
});

export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
