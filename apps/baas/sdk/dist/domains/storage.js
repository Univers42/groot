/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   storage.ts                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
import { routes } from '../core/routes.js';
import { MiniBaasError } from '../core/errors.js';
/**
 * Per-bucket client, Supabase-shaped:
 *   client.storage.from('avatars').upload('me.png', file)
 * Upload/download proxy through storage-router (so they work with the internal
 * MinIO endpoint); list/remove are JSON; createSignedUrl returns a direct-S3
 * presigned URL (usable externally only when S3_PUBLIC_ENDPOINT is configured).
 * All keys are auto-prefixed with the caller's user id server-side.
 */
export class StorageBucketClient {
    http;
    bucket;
    constructor(http, bucket) {
        this.http = http;
        this.bucket = bucket;
    }
    async upload(path, body, opts = {}) {
        const res = await this.http.rawFetch(routes.storage.object(this.bucket, path), {
            method: 'PUT',
            body: body,
            headers: { 'Content-Type': opts.contentType ?? guessContentType(path) },
        });
        if (!res.ok)
            throw await toError(res);
        return (await res.json());
    }
    async download(path) {
        const res = await this.http.rawFetch(routes.storage.object(this.bucket, path), { method: 'GET' });
        if (!res.ok)
            throw await toError(res);
        return res.blob();
    }
    /**
     * A1: download a server-derived image variant (resize/reformat) of an object,
     * owner-scoped exactly like `download`. Requires the server to have
     * STORAGE_TRANSFORMS_ENABLED ON; when OFF the original bytes are returned
     * (byte-identical) so this is a safe superset of `download`.
     *   client.storage.from('avatars').transform('me.png', { width: 64, height: 64, format: 'webp' })
     */
    async transform(path, opts) {
        const res = await this.http.rawFetch(routes.storage.transform(this.bucket, path, transformQuery(opts)), { method: 'GET' });
        if (!res.ok)
            throw await toError(res);
        return res.blob();
    }
    async list(prefix) {
        const out = await this.http.request(routes.storage.list(this.bucket, prefix));
        return out.objects;
    }
    async remove(paths) {
        return Promise.all(paths.map(async (p) => {
            await this.http.request(routes.storage.object(this.bucket, p), { method: 'DELETE' });
            return { key: p, deleted: true };
        }));
    }
    createSignedUrl(path, expiresIn, method = 'GET') {
        return this.http.request(routes.storage.sign(this.bucket, path), {
            method: 'POST',
            body: { method, expiresIn },
        });
    }
}
export class StorageClient {
    http;
    constructor(http) {
        this.http = http;
    }
    /** Supabase-shaped entry point. */
    from(bucket) {
        return new StorageBucketClient(this.http, bucket);
    }
    async listBuckets() {
        const out = await this.http.request(routes.storage.buckets);
        return out.buckets;
    }
    createBucket(name) {
        return this.http.request(routes.storage.bucket(name), { method: 'POST' });
    }
    /** Low-level: presigned URL for direct-S3 access (back-compat). */
    presign(input) {
        return this.http.request(routes.storage.sign(input.bucket, input.key), {
            method: 'POST',
            body: { method: input.method ?? 'PUT', contentType: input.contentType },
        });
    }
}
const CONTENT_TYPES = {
    png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif',
    webp: 'image/webp', svg: 'image/svg+xml', pdf: 'application/pdf',
    json: 'application/json', txt: 'text/plain', csv: 'text/csv',
    html: 'text/html', md: 'text/markdown',
};
function guessContentType(path) {
    const ext = path.split('.').pop()?.toLowerCase() ?? '';
    return CONTENT_TYPES[ext] ?? 'application/octet-stream';
}
/** Build the `?width=&height=&format=&quality=` query for an image transform,
 *  emitting only the set keys (so a bare/empty spec yields the original-bytes URL). */
function transformQuery(opts) {
    const params = new URLSearchParams();
    if (opts.width !== undefined)
        params.set('width', String(opts.width));
    if (opts.height !== undefined)
        params.set('height', String(opts.height));
    if (opts.format !== undefined)
        params.set('format', opts.format);
    if (opts.quality !== undefined)
        params.set('quality', String(opts.quality));
    return params.toString();
}
async function toError(res) {
    let detail;
    try {
        detail = await res.clone().json();
    }
    catch {
        detail = undefined;
    }
    const message = detail && typeof detail === 'object' && typeof detail.message === 'string'
        ? detail.message
        : res.statusText;
    return new MiniBaasError(message, res.status, detail);
}
