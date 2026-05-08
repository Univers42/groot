#!/usr/bin/env node

const target = process.argv.find((arg) => arg.startsWith('http')) ?? process.env.CSP_VERIFY_URL ?? 'https://localhost:4322/';
const allowLocalTls = target.startsWith('https://localhost') || target.startsWith('https://127.0.0.1');

if (allowLocalTls) {
	process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
}

function metaTags(html) {
	const tags = [];
	let searchFrom = 0;
	for (;;) {
		const start = html.toLowerCase().indexOf('<meta', searchFrom);
		if (start < 0) return tags;
		const end = html.indexOf('>', start + 5);
		if (end < 0) return tags;
		tags.push(html.slice(start, end + 1));
		searchFrom = end + 1;
	}
}

function isAttributeNameCharacter(character) {
	return (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') || character === '-';
}

function isWhitespace(character) {
	return character === '\t' || character === '\n' || character === '\f' || character === '\r' || character === ' ';
}

function skipWhitespace(text, index) {
	let nextIndex = index;
	while (nextIndex < text.length && isWhitespace(text[nextIndex])) {
		nextIndex += 1;
	}
	return nextIndex;
}

function readAttributeName(tag, index) {
	let nextIndex = index;
	while (nextIndex < tag.length && isAttributeNameCharacter(tag[nextIndex])) {
		nextIndex += 1;
	}
	if (nextIndex === index) {
		return null;
	}
	return { name: tag.slice(index, nextIndex).toLowerCase(), nextIndex };
}

function readQuotedAttributeValue(tag, index) {
	const quote = tag[index];
	if (quote !== '"' && quote !== "'") {
		return null;
	}

	const valueStart = index + 1;
	const valueEnd = tag.indexOf(quote, valueStart);
	if (valueEnd < 0) {
		return undefined;
	}

	return { value: tag.slice(valueStart, valueEnd), nextIndex: valueEnd + 1 };
}

function metaAttributes(tag) {
	const attributes = new Map();
	let index = 0;
	while (index < tag.length) {
		index = skipWhitespace(tag, index);
		const attributeName = readAttributeName(tag, index);
		if (attributeName === null) {
			index += 1;
			continue;
		}

		index = skipWhitespace(tag, attributeName.nextIndex);
		if (tag[index] !== '=') {
			continue;
		}

		index = skipWhitespace(tag, index + 1);
		const attributeValue = readQuotedAttributeValue(tag, index);
		if (attributeValue === undefined) {
			break;
		}
		if (attributeValue === null) {
			index += 1;
			continue;
		}

		attributes.set(attributeName.name, attributeValue.value);
		index = attributeValue.nextIndex;
	}
	return attributes;
}

function decodeHtmlAttribute(value) {
	return value.replaceAll('&quot;', '"').replaceAll('&#39;', "'");
}

function extractMetaContent(html, expectedAttribute, expectedValue) {
	for (const tag of metaTags(html)) {
		const attributes = metaAttributes(tag);
		if (attributes.get(expectedAttribute) === expectedValue) {
			return decodeHtmlAttribute(attributes.get('content') ?? '');
		}
	}
	return '';
}

function extractMetaCsp(html) {
	return extractMetaContent(html, 'http-equiv', 'Content-Security-Policy');
}

function extractMetaMode(html) {
	return extractMetaContent(html, 'name', 'prismatica-csp-mode');
}

function fail(message) {
	console.error(`FAIL ${message}`);
	process.exitCode = 1;
}

const response = await fetch(target, { redirect: 'manual' });
const html = await response.text();
const headerCsp = response.headers.get('content-security-policy') ?? '';
const metaCsp = extractMetaCsp(html);
const csp = headerCsp || metaCsp;
const mode = response.headers.get('x-prismatica-csp-mode') ?? extractMetaMode(html) ?? (headerCsp ? 'unknown' : 'production-meta');

if (csp) {
	console.log(`PASS CSP found via ${headerCsp ? 'header' : 'meta'} (${mode}).`);
} else {
	fail('Content-Security-Policy was not found in a response header or meta tag.');
}

if (metaCsp.split(';').some((part) => part.trim().startsWith('frame-ancestors'))) {
	fail('frame-ancestors must be delivered by an HTTP header, not a meta CSP tag.');
} else {
	console.log('PASS meta CSP does not contain frame-ancestors.');
}

if (headerCsp?.split(';').some((part) => part.trim().startsWith('frame-ancestors'))) {
	console.log('PASS frame-ancestors is present in the HTTP CSP header.');
}

for (const directive of ['default-src', 'script-src', 'connect-src', 'object-src', 'base-uri']) {
	const directives = csp.split(';').map((part) => part.trim().split(/\s+/, 1)[0]);
	if (!directives.includes(directive)) {
		fail(`Missing ${directive} directive.`);
	}
}


const scriptDirective = csp.split(';').find((part) => part.trim().startsWith('script-src')) ?? '';
if (scriptDirective.includes("'unsafe-eval'")) {
	if (mode === 'development') {
		console.log('PASS unsafe-eval is limited to the development Vite/HMR CSP header.');
	} else {
		fail('Production CSP must not include unsafe-eval.');
	}
} else {
	console.log('PASS CSP does not allow unsafe-eval.');
}

if (html.includes('eval(') || html.includes('new Function(') || html.includes('setTimeout("') || html.includes("setTimeout('") || html.includes('setInterval("') || html.includes("setInterval('")) {
	fail('Served HTML contains eval-like script text.');
} else {
	console.log('PASS served HTML has no eval-like script text.');
}
