#!/usr/bin/env node
/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   verify-connection.mjs                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { createBaasClient, fail, pass } from './baas-env.mjs';

try {
	await createBaasClient().rest.root();

	pass('BaaS PostgREST gateway responded with HTTP 200.');
} catch (error) {
	fail('BaaS connection verification failed.', error);
}
