/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   index.ts                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Mascot feature module — architectural placeholder.
// The current mascot orchestration lives inline in `src/scripts/main.ts`
// (binocle DOM, mood engine, pointer tracking, particle effects). When that
// file is decomposed in Phase 2 of the redesign-plan, the implementation
// moves here behind `initMascot()`.
//
// Today we expose a no-op so consumers can wire the feature module without
// breaking the running build.

export interface MascotInit {
	root?: ParentNode;
}

export function initMascot(_options: MascotInit = {}): void {
	// Intentionally empty: main.ts owns mascot setup until decomposition lands.
}
