import type { HttpClient } from '../core/http.js';
import type { PresignInput } from '../types.js';
export declare class StorageClient {
    private readonly http;
    constructor(http: HttpClient);
    presign<TResult = unknown>(input: PresignInput): Promise<TResult>;
}
