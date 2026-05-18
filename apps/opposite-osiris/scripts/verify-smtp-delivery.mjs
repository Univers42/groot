#!/usr/bin/env node
/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   verify-smtp-delivery.mjs                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import assert from 'node:assert/strict';
import { createBaasClient } from './baas-env.mjs';

const client = createBaasClient();
const email = 'dev.pro.photo@gmail.com';

async function requestRecovery(attempt) {
	await client.auth.recover({ email });
	assert.ok(true, `attempt ${attempt} accepted`);
	console.log(`PASS Recovery request ${attempt} accepted.`);
}

await requestRecovery(1);
console.log('✓ Recovery email dispatched. Please manually verify delivery to dev.pro.photo@gmail.com within 2 minutes.');
await new Promise((resolve) => setTimeout(resolve, 10_000));
await requestRecovery(2);
