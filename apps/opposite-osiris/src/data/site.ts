import type { AssetIcon, CharacterGuide, NavItem, PowerCard } from '../types/content';

export const navItems: NavItem[] = [
	{ label: 'Powers', href: '#powers' },
	{ label: 'Visuals', href: '#media-assets' },
	{ label: 'Grid', href: '#grid' },
	{ label: 'Guides', href: '#characters' },
];

export const powerCards: PowerCard[] = [
	{
		title: 'Living Markdown',
		description: 'Notes render live, then transform into tables, checklists and structured work without leaving the page.',
		illustration: 'markdown',
		rotation: 'rot-a',
	},
	{
		title: 'Integrated Drawing',
		description: 'Sketch inside your documents with construction lines, freehand marks and real context around the work.',
		illustration: 'drawing',
		rotation: 'rot-b',
	},
	{
		title: 'Dashboard Grid',
		description: 'Drag, resize and nest reliable dashboard cells — every cell can become any kind of block.',
		illustration: 'dashboard',
		rotation: 'rot-c',
	},
	{
		title: 'Relational Data',
		description: 'Tables, kanban, galleries, timelines and graphs are just views over the same connected data.',
		illustration: 'data',
		rotation: 'rot-b',
	},
	{
		title: 'Connected Apps',
		description: 'Calendars, forms, charts, timers and custom calculators plug into the same living workspace.',
		illustration: 'apps',
		rotation: 'rot-a',
	},
	{
		title: 'Collaboration',
		description: 'Share, comment and version everything with teams across countries and business units.',
		illustration: 'collaboration',
		rotation: 'rot-c',
	},
];

export const assetIcons: AssetIcon[] = [
	{ label: 'Product', alt: 'Product team icon.' },
	{ label: 'Marketing', alt: 'Marketing team icon.' },
	{ label: 'Operations', alt: 'Operations team icon.' },
	{ label: 'People', alt: 'Human resources team icon.' },
	{ label: 'Design', alt: 'Design team icon.' },
	{ label: 'Block A', alt: 'Workspace block icon representing one active product area.' },
	{ label: 'Block B', alt: 'Workspace block icon representing a second active product area.' },
];

export const characterGuides: CharacterGuide[] = [
	{
		kind: 'reader',
		title: 'Reader',
		description: 'Reads with the visitor and keeps the page grounded in human notes.',
		paperClass: 'paper-reader',
	},
	{
		kind: 'student',
		title: 'Student',
		description: 'Points out what matters in complex data and dashboard decisions.',
		paperClass: 'paper-student',
	},
	{
		kind: 'chatter',
		title: 'Chatter',
		description: 'Turns collaboration into a clear, visual conversation.',
		paperClass: 'paper-chatter',
	},
];
