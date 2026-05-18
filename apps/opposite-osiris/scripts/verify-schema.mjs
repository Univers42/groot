#!/usr/bin/env node
/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   verify-schema.mjs                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { MiniBaasError } from '@mini-baas/js';
import { createBaasClient, fail, pass } from './baas-env.mjs';

const expectedColumns = ['id', 'username', 'email'];

try {
	const client = createBaasClient();
	await client.from('users').select({ columns: expectedColumns.join(','), limit: 0, headers: { Prefer: 'count=exact' } });

	try {
		const sensitiveRows = await client.from('users').select({ columns: 'password_hash', limit: 1 });
		if (Array.isArray(sensitiveRows) && sensitiveRows.length > 0) throw new Error('password_hash is exposed to the anonymous role.');
	} catch (error) {
		if (!(error instanceof MiniBaasError)) throw error;
	}

	pass(`users table is reachable and exposes expected columns: ${expectedColumns.join(', ')}.`);
} catch (error) {
	fail('BaaS schema verification failed.', error);
}
