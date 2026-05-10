import type { HttpClient } from '../core/http.js';
import type { AnalyticsTrackInput } from '../types.js';
export declare class AnalyticsClient {
    private readonly http;
    constructor(http: HttpClient);
    track(input: AnalyticsTrackInput | string, data?: Record<string, unknown>): Promise<void>;
}
