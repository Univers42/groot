/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   user-context.interface.ts                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

/**
 * User context extracted from Kong trusted headers.
 * Populated by AuthGuard and injected via @CurrentUser() decorator.
 */
export interface UserContext {
  /** UUID from X-User-Id header */
  id: string;
  /** Email from X-User-Email header */
  email: string;
  /** Role from X-User-Role header: 'authenticated' | 'service_role' | 'anon' */
  role: string;
}

/**
 * Augment Express Request with user context.
 */
declare global {
  namespace Express {
    interface Request {
      user?: UserContext;
      requestId?: string;
    }
  }
}
