import React from 'react';
import {AbsoluteFill, Img, staticFile} from 'remotion';
import {C, FONT} from '../theme';

export const GW = 1800;
export const GH = 1200;

// A 3:2 gallery image: dark backdrop, a headline and one line under it, then the content.
export const Slide: React.FC<{title: React.ReactNode; sub?: string; children: React.ReactNode}> = ({title, sub, children}) => (
	<AbsoluteFill style={{background: `radial-gradient(ellipse 85% 75% at 50% 55%, ${C.bgGlow} 0%, ${C.bg} 72%)`, fontFamily: FONT, color: C.text}}>
		<div style={{position: 'absolute', top: 70, left: 0, right: 0, textAlign: 'center'}}>
			<div style={{fontSize: 68, fontWeight: 700, letterSpacing: -1.2}}>{title}</div>
			{sub && <div style={{fontSize: 32, color: C.secondary, marginTop: 14}}>{sub}</div>}
		</div>
		<div style={{position: 'absolute', top: sub ? 270 : 210, left: 0, right: 0, bottom: 0, display: 'flex', justifyContent: 'center'}}>{children}</div>
	</AbsoluteFill>
);

// A 16:9 frame from one of the clips, cropped and framed.
export const Shot: React.FC<{src: string; width: number; crop?: {x: number; y: number; w: number; h: number}}> = ({src, width, crop = {x: 0, y: 0, w: 1920, h: 1080}}) => {
	const scale = width / crop.w;
	return (
		<div style={{width, height: crop.h * scale, overflow: 'hidden', borderRadius: 24, boxShadow: '0 40px 100px rgba(0,0,0,0.55)', position: 'relative'}}>
			<Img src={staticFile(src)} style={{position: 'absolute', left: -crop.x * scale, top: -crop.y * scale, width: 1920 * scale, height: 1080 * scale}} />
		</div>
	);
};
