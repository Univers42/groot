/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   analytics.ts                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
import { routes } from '../core/routes.js';
export class AnalyticsClient {
    http;
    constructor(http) {
        this.http = http;
    }
    async track(input, data = {}) {
        const event = typeof input === 'string' ? { eventType: input, data } : input;
        await this.http.request(routes.analytics.events, {
            method: 'POST',
            body: {
                eventType: event.eventType,
                data: event.data ?? {},
            },
        });
    }
}
