export const baasConfig = {
        get url() {
                const envUrl = import.meta.env.PUBLIC_BAAS_URL ?? '/api';
                return envUrl.replaceAll(/\/$/g, '');
        },
        get anonKey() {
                return import.meta.env.PUBLIC_BAAS_ANON_KEY ?? '';
        },
};

export const isBaasConfigured = (): boolean => Boolean(baasConfig.url && baasConfig.anonKey);
