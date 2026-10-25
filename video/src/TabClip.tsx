import React from 'react';
import {AbsoluteFill, Html5Audio, staticFile} from 'remotion';
import {C, FONT} from './theme';

// Background + voiceover around one in-app scene.
export const TabClip: React.FC<{audio: string; children: React.ReactNode}> = ({audio, children}) => (
	<AbsoluteFill style={{background: `radial-gradient(ellipse 80% 70% at 50% 45%, ${C.bgGlow} 0%, ${C.bg} 70%)`, fontFamily: FONT, color: C.text}}>
		<Html5Audio src={staticFile(audio)} />
		{children}
	</AbsoluteFill>
);
