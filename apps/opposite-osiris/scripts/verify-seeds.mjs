#!/usr/bin/env node
/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   verify-seeds.mjs                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { createBaasClient, fail, pass } from './baas-env.mjs';

const expectedEmails = new Set([
	'john.doe@example.com',
	'jane.doe@example.com',
	'alice@example.com',
	'bob@example.com',
	'charlie@example.com',
	'diana@example.com',
	'evan@example.com',
	'fiona@example.com',
	'george@example.com',
	'hannah@example.com',
]);

try {
	const rows = await createBaasClient().from('users').select({ columns: 'email', limit: 10 });
	const actualEmails = new Set(Array.isArray(rows) ? rows.map((row) => row.email) : []);
	const missing = [...expectedEmails].filter((email) => !actualEmails.has(email));

	if (missing.length > 0) {
		throw new Error(`Missing seeded emails: ${missing.join(', ')}`);
	}

	pass('All 10 seeded users are present through PostgREST.');
} catch (error) {
	fail('BaaS seed verification failed.', error);
}
