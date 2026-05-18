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
export class StorageClient {
    http;
    constructor(http) {
        this.http = http;
    }
    presign(input) {
        return this.http.request(routes.storage.sign(input.bucket, input.key), {
            method: 'POST',
            body: {
                method: input.method ?? 'PUT',
                contentType: input.contentType,
            },
        });
    }
}
