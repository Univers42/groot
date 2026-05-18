/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   storage.ts                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { routes } from '../core/routes.js';
import type { HttpClient } from '../core/http.js';
import type { PresignInput } from '../types.js';

export class StorageClient {
  constructor(private readonly http: HttpClient) {}

  presign<TResult = unknown>(input: PresignInput): Promise<TResult> {
    return this.http.request<TResult>(routes.storage.sign(input.bucket, input.key), {
      method: 'POST',
      body: {
        method: input.method ?? 'PUT',
        contentType: input.contentType,
      },
    });
  }
}
