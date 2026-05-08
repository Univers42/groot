const SAFE_PUBLIC_ASSET_PATTERN = /^[-A-Za-z0-9._%() ]+\.(?:avif|gif|jpe?g|png|svg|webp)$/u;
const BLOCKED_PATH_PATTERN = /(?:^|[\\/])\.\.(?:[\\/]|$)|[\\/]|\0|^[a-z][a-z0-9+.-]*:/iu;

/**
 * Builds a same-origin `/assets/...` URL for checked-in public media only.
 *
 * User-controlled upload paths must never be passed here. The allowlist blocks
 * traversal, protocols (`javascript:`, `data:`, `https:`), NUL bytes and nested
 * paths so future media additions cannot accidentally create URL injection.
 *
 * @param {string} fileName
 * @param {string} [baseUrl]
 * @returns {string}
 */
export function safePublicAssetPath(fileName, baseUrl = '/') {
	const decodedFileName = decodeURIComponent(fileName);
	if (BLOCKED_PATH_PATTERN.test(fileName) || BLOCKED_PATH_PATTERN.test(decodedFileName) || !SAFE_PUBLIC_ASSET_PATTERN.test(decodedFileName)) {
		throw new Error(`Unsafe public asset path rejected: ${fileName}`);
	}

	const encodedSegments = decodedFileName
		.split(' ')
		.map((segment) => encodeURIComponent(segment))
		.join('%20');
	return `${baseUrl.replace(/\/$/, '')}/assets/${encodedSegments}`;
}

// ---------- SVG upload hardening ----------
//
// Use this BEFORE accepting any user-supplied SVG (avatar, logo, etc.). It
// rejects payloads that carry executable markup (script, foreignObject, event
// handlers, javascript:/data: URLs). Combine with one or more of:
//   - serve uploads from a sandboxed origin (Content-Disposition: attachment)
//   - re-encode via librsvg/ImageMagick to a raster format when possible
//   - keep `script-src 'self'` (no `'unsafe-inline'`) on the serving origin
//
// This is intentionally conservative — when in doubt, reject.

const SVG_MAX_BYTES = 256 * 1024;
const SVG_FORBIDDEN_TAGS = /<\s*(script|foreignobject|iframe|embed|object|use)\b/iu;
const SVG_FORBIDDEN_EVENT_HANDLER = /\son[a-z]+\s*=/iu;
const SVG_DANGEROUS_HREF = /\s(?:href|xlink:href)\s*=\s*["']?\s*(?:javascript:|vbscript:|data:text)/iu;
const SVG_FORBIDDEN_URLS = /(?:javascript:|vbscript:|file:|jar:)/iu;
const SVG_OPENING_TAG = /<\s*svg\b[^>]*>/iu;

/**
 * Throws if the supplied UTF-8 SVG markup looks unsafe for inline rendering.
 *
 * @param {string} svgText
 * @returns {string} the validated markup, untouched
 */
export function assertSafeSvg(svgText) {
	if (typeof svgText !== 'string' || svgText.length === 0) {
		throw new Error('SVG payload is empty.');
	}
	if (svgText.length > SVG_MAX_BYTES) {
		throw new Error('SVG payload exceeds 256 KiB.');
	}
	if (!SVG_OPENING_TAG.test(svgText)) {
		throw new Error('Payload is not an SVG document.');
	}
	if (SVG_FORBIDDEN_TAGS.test(svgText)) {
		throw new Error('SVG contains a forbidden element.');
	}
	if (SVG_FORBIDDEN_EVENT_HANDLER.test(svgText)) {
		throw new Error('SVG contains a forbidden event-handler attribute.');
	}
	if (SVG_DANGEROUS_HREF.test(svgText)) {
		throw new Error('SVG contains a forbidden href URL scheme.');
	}
	if (SVG_FORBIDDEN_URLS.test(svgText)) {
		throw new Error('SVG references a forbidden URL scheme.');
	}
	return svgText;
}

/**
 * Returns true when the supplied SVG markup is safe to inline; false otherwise.
 * Prefer `assertSafeSvg` for server endpoints so the rejection reason can be
 * surfaced.
 *
 * @param {string} svgText
 * @returns {boolean}
 */
export function isSafeSvg(svgText) {
	try {
		assertSafeSvg(svgText);
		return true;
	} catch {
		return false;
	}
}
