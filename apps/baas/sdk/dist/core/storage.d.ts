import type { ClientSession } from './session.js';
export interface SessionStorageAdapter {
    load(): ClientSession | undefined;
    save(session: ClientSession): void;
    clear(): void;
}
export declare function createMemoryStorageAdapter(): SessionStorageAdapter;
export declare function createBrowserStorageAdapter(key?: string): SessionStorageAdapter | undefined;
