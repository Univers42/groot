function stripAddress(value) {
	const raw = String(value ?? '').trim();
	return /<([^>]+)>/.exec(raw)?.[1]?.trim() ?? raw;
}

export function testEmailDomain(fallback = 'mini-baas.local') {
	const explicit = process.env.AUTH_TEST_EMAIL_DOMAIN || process.env.TEST_EMAIL_DOMAIN;
	if (explicit) return explicit.trim().toLowerCase();

	const candidates = [
		process.env.SMTP_FROM_ADDRESS,
		process.env.EMAIL_FROM,
		process.env.SMTP_USERNAME,
		process.env.SMTP_USER,
	];
	for (const candidate of candidates) {
		const address = stripAddress(candidate);
		const domain = address.includes('@') ? address.split('@').pop()?.trim().toLowerCase() : '';
		if (domain) return domain;
	}
	return fallback;
}

export function uniqueTestEmail(label, envName) {
	const configured = envName ? process.env[envName] : '';
	if (configured) return configured.trim().toLowerCase();

	const timestamp = `${Date.now()}${Math.floor(Math.random() * 1000)}`;
	const safeLabel = String(label || 'test').toLowerCase().replaceAll(/[^a-z0-9_-]/g, '-');
	return `devfast+${safeLabel}-${timestamp}@${testEmailDomain()}`;
}
