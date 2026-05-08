import { createClient } from '@mini-baas/js';
import { baasConfig } from './baas-config';

export type BaaSUser = {
	id: number;
	username: string;
	email: string;
};

export const createPublicBaasClient = (accessToken?: string) => {
	if (!baasConfig.anonKey) {
		throw new Error('Missing PUBLIC_BAAS_ANON_KEY. Copy opposite-osiris/.env.example to .env.local and set it from the project-owned BaaS env.');
	}

	return createClient({
		url: baasConfig.url,
		anonKey: baasConfig.anonKey,
		accessToken,
		persistSession: false,
	});
};

export async function fetchSeededUsers(limit = 3): Promise<BaaSUser[]> {
	return createPublicBaasClient().from<BaaSUser>('users').select({ columns: 'id,username,email', limit });
}
