// SVG path helpers for the small line charts.
export type Pt = {x: number; y: number};

// A smooth line through the points (Catmull-Rom converted to cubic Béziers).
export const smoothPath = (pts: Pt[]) => {
	if (pts.length < 2) return '';
	let d = `M ${pts[0].x} ${pts[0].y}`;
	for (let i = 0; i < pts.length - 1; i++) {
		const p0 = pts[i - 1] ?? pts[i];
		const p1 = pts[i];
		const p2 = pts[i + 1];
		const p3 = pts[i + 2] ?? p2;
		const c1 = {x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6};
		const c2 = {x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6};
		d += ` C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${p2.x} ${p2.y}`;
	}
	return d;
};

// The same line closed down to the baseline, for an area fill.
export const areaPath = (pts: Pt[], baseY: number) =>
	`${smoothPath(pts)} L ${pts[pts.length - 1].x} ${baseY} L ${pts[0].x} ${baseY} Z`;
