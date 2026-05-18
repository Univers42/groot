/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   errors.ts                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
export class MiniBaasError extends Error {
    status;
    body;
    constructor(message, status, body) {
        super(message);
        this.status = status;
        this.body = body;
        this.name = 'MiniBaasError';
    }
}
export class MiniBaasTimeoutError extends Error {
    timeoutMs;
    constructor(timeoutMs) {
        super(`MiniBaas request timed out after ${timeoutMs}ms`);
        this.timeoutMs = timeoutMs;
        this.name = 'MiniBaasTimeoutError';
    }
}
