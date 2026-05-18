/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   session.ts                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
export function normalizeSession(session) {
    if (typeof session === 'string')
        return { accessToken: session };
    if (isClientSession(session)) {
        return {
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: session.expiresAt,
        };
    }
    return {
        accessToken: session.access_token,
        refreshToken: session.refresh_token,
        expiresAt: session.expires_at ?? computeExpiresAt(session.expires_in),
    };
}
function computeExpiresAt(expiresIn) {
    if (!expiresIn)
        return undefined;
    return Math.floor(Date.now() / 1000) + expiresIn;
}
function isClientSession(session) {
    return typeof session.accessToken === 'string';
}
