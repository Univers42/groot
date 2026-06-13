import type { HttpClient } from '../core/http.js';
import type { PresignInput } from '../types.js';
export interface StorageObject {
    key: string;
    size: number;
    lastModified: string | null;
    etag?: string;
}
export interface BucketInfo {
    name: string;
    createdAt: string | null;
}
export interface UploadResult {
    bucket: string;
    key: string;
    size: number;
}
export interface UploadOptions {
    contentType?: string;
}
export type UploadBody = Blob | ArrayBuffer | ArrayBufferView | string;
/**
 * Per-bucket client, Supabase-shaped:
 *   client.storage.from('avatars').upload('me.png', file)
 * Upload/download proxy through storage-router (so they work with the internal
 * MinIO endpoint); list/remove are JSON; createSignedUrl returns a direct-S3
 * presigned URL (usable externally only when S3_PUBLIC_ENDPOINT is configured).
 * All keys are auto-prefixed with the caller's user id server-side.
 */
export declare class StorageBucketClient {
    private readonly http;
    private readonly bucket;
    constructor(http: HttpClient, bucket: string);
    upload(path: string, body: UploadBody, opts?: UploadOptions): Promise<UploadResult>;
    download(path: string): Promise<Blob>;
    list(prefix?: string): Promise<StorageObject[]>;
    remove(paths: string[]): Promise<Array<{
        key: string;
        deleted: boolean;
    }>>;
    createSignedUrl(path: string, expiresIn?: number, method?: 'GET' | 'PUT'): Promise<{
        signedUrl: string;
        expiresAt: string;
        method: string;
        bucket: string;
        key: string;
    }>;
}
export declare class StorageClient {
    private readonly http;
    constructor(http: HttpClient);
    /** Supabase-shaped entry point. */
    from(bucket: string): StorageBucketClient;
    listBuckets(): Promise<BucketInfo[]>;
    createBucket(name: string): Promise<{
        name: string;
        created: boolean;
    }>;
    /** Low-level: presigned URL for direct-S3 access (back-compat). */
    presign<TResult = unknown>(input: PresignInput): Promise<TResult>;
}
