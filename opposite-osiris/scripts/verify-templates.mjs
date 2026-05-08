/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   verify-templates.mjs                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/04 18:29:46 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/08 01:04:18 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const templateDir = resolve(process.cwd(), 'src/email-templates');
const templates = [
	{
		file: 'password-reset.html',
		required: ['{{.Token}}', '{{.SiteURL}}', '{{.Email}}', '{{ResetURL}}', 'Reset my password →', '1 hour'],
	},
	{
		file: 'account-created.html',
		required: ['{{.SiteURL}}', '{{.Email}}', 'Your account is ready', 'Open Prismatica →'],
	},
	{
		file: 'email-verification.html',
		required: ['{{.Token}}', '{{.SiteURL}}', '{{.Email}}', 'Confirm my email →', '24 hours'],
	},
	{
		file: 'newsletter-confirm.html',
		required: ['{{.Token}}', '{{.SiteURL}}', '{{.Email}}', 'Yes, subscribe me →', 'double opt-in'],
	},
	{
		file: 'newsletter-welcome.html',
		required: ['{{.Token}}', '{{.SiteURL}}', '{{.Email}}', 'One-click unsubscribe', 'You can unsubscribe at any time'],
	},
	{
		file: 'newsletter-unsubscribe.html',
		required: ['{{.SiteURL}}', '{{.Email}}', 'You are unsubscribed'],
	},
	{
		file: 'login-alert.html',
		required: ['{{email}}', '{{ipAddress}}', '{{location}}', '{{occurredAt}}', '{{userAgent}}', '{{outcome}}', 'Security alert', 'New sign-in to Prismatica'],
	},
];

function assertSelfContained(file, html) {
	assert.ok(/<!doctype html>/i.test(html), `${file} must be a complete HTML document.`);
	assert.ok(/<body\b/i.test(html), `${file} must include a body.`);
	assert.ok(/style="[^"]+"/i.test(html), `${file} must use inline styles for email-client compatibility.`);
	assert.ok(!/<link\b[^>]*stylesheet/i.test(html), `${file} must not reference external stylesheets.`);
	assert.ok(!/@import\s+url/i.test(html), `${file} must not import external CSS.`);
	assert.ok(!/<script\b/i.test(html), `${file} must not include scripts.`);
	assert.ok(!/<img\b[^>]*src=["']https?:\/\//i.test(html), `${file} must not reference external image URLs.`);
	assert.ok(!/url\(["']?https?:\/\//i.test(html), `${file} must not reference external CSS URLs.`);
}

for (const template of templates) {
	const path = resolve(templateDir, template.file);
	const html = await readFile(path, 'utf8');
	for (const needle of template.required) {
		assert.ok(html.includes(needle), `${template.file} is missing required content: ${needle}`);
	}
	assertSelfContained(template.file, html);
	console.log(`PASS ${template.file}`);
}

console.log('PASS all email templates are self-contained and include expected GoTrue variables.');
