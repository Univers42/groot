import sanitizeHtml from 'sanitize-html';

const SAFE_SVG_TAGS = [
	'svg',
	'g',
	'path',
	'circle',
	'ellipse',
	'line',
	'polyline',
	'polygon',
	'rect',
	'text',
	'tspan',
	'title',
	'desc',
	'defs',
	'linearGradient',
	'radialGradient',
	'stop',
	'clipPath',
	'mask',
	'use',
];

const SAFE_SVG_ATTRIBUTES = [
	'aria-hidden',
	'aria-label',
	'aria-labelledby',
	'class',
	'clip-path',
	'clip-rule',
	'cx',
	'cy',
	'd',
	'dominant-baseline',
	'fill',
	'fill-opacity',
	'fill-rule',
	'focusable',
	'font-family',
	'font-size',
	'font-weight',
	'height',
	'id',
	'mask',
	'opacity',
	'points',
	'preserveAspectRatio',
	'r',
	'role',
	'rx',
	'ry',
	'stroke',
	'stroke-dasharray',
	'stroke-dashoffset',
	'stroke-linecap',
	'stroke-linejoin',
	'stroke-miterlimit',
	'stroke-opacity',
	'stroke-width',
	'text-anchor',
	'transform',
	'viewBox',
	'width',
	'x',
	'x1',
	'x2',
	'xmlns',
	'y',
	'y1',
	'y2',
];

const SVG_URL_ATTRIBUTE_PATTERN = /\s(?:href|xlink:href|src)\s*=\s*(['"]?)\s*(?:javascript:|data:|vbscript:)/iu;
const SVG_EVENT_ATTRIBUTE_PATTERN = /\son[a-z]+\s*=/iu;
const SVG_BLOCKED_MARKUP_PATTERN = /<\s*\/?\s*(?:script|foreignObject|iframe|object|embed|audio|video|canvas|image|link|meta|style)\b/iu;

/**
 * Sanitizes inline SVG before it reaches Astro's `set:html` sink.
 *
 * The project uses a few trusted checked-in SVG illustrations, but SVG is an
 * active document format. This sanitizer intentionally keeps a narrow drawing
 * subset and rejects scripts, event handlers, external links, embedded media,
 * `foreignObject`, and CSS blocks.
 *
 * @param {string} markup
 * @returns {string}
 */
export function sanitizeSvgMarkup(markup) {
	if (SVG_EVENT_ATTRIBUTE_PATTERN.test(markup) || SVG_URL_ATTRIBUTE_PATTERN.test(markup) || SVG_BLOCKED_MARKUP_PATTERN.test(markup)) {
		throw new Error('Unsafe SVG markup was rejected before rendering.');
	}

	const sanitized = sanitizeHtml(markup, {
		allowedTags: [...SAFE_SVG_TAGS],
		allowedAttributes: {
			'*': [...SAFE_SVG_ATTRIBUTES],
			use: ['class', 'href', 'id', 'transform', 'x', 'y'],
		},
		allowedSchemes: [],
		allowedSchemesByTag: {},
		allowProtocolRelative: false,
		disallowedTagsMode: 'discard',
		nonTextTags: ['script', 'style', 'textarea', 'title'],
		parser: {
			lowerCaseAttributeNames: false,
			lowerCaseTags: false,
		},
	});

	if (!/^\s*<svg[\s>]/iu.test(sanitized)) {
		throw new Error('Sanitized SVG no longer contains a root <svg> element.');
	}

	return sanitized;
}
