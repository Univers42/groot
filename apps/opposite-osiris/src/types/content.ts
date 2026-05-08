export type ThemeName = 'aurora' | 'solar' | 'ember' | 'forest';

export type NavItem = {
	label: string;
	href: string;
};

export type PowerCard = {
	title: string;
	description: string;
	illustration: 'markdown' | 'drawing' | 'dashboard' | 'data' | 'apps' | 'collaboration';
	rotation: 'rot-a' | 'rot-b' | 'rot-c';
};

export type MediaFeature = {
	title: string;
	description: string;
	alt: string;
	wide?: boolean;
};

export type AssetIcon = {
	label: string;
	alt: string;
};

export type CharacterGuide = {
	kind: 'reader' | 'student' | 'chatter';
	title: string;
	description: string;
	paperClass: 'paper-reader' | 'paper-student' | 'paper-chatter';
};
