const DEFAULT_STORAGE_KEY = 'mini-baas.auth.session';
export function createMemoryStorageAdapter() {
    let current;
    return {
        load: () => current,
        save: (session) => {
            current = session;
        },
        clear: () => {
            current = undefined;
        },
    };
}
export function createBrowserStorageAdapter(key = DEFAULT_STORAGE_KEY) {
    const localStorageRef = getLocalStorage();
    if (!localStorageRef)
        return undefined;
    return {
        load: () => {
            const value = localStorageRef.getItem(key);
            if (!value)
                return undefined;
            try {
                return JSON.parse(value);
            }
            catch {
                localStorageRef.removeItem(key);
                return undefined;
            }
        },
        save: (session) => {
            localStorageRef.setItem(key, JSON.stringify(session));
        },
        clear: () => {
            localStorageRef.removeItem(key);
        },
    };
}
function getLocalStorage() {
    try {
        if (typeof globalThis === 'undefined')
            return undefined;
        return globalThis.localStorage;
    }
    catch {
        return undefined;
    }
}
