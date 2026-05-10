export function normalizeSession(session) {
    if (typeof session === 'string')
        return { accessToken: session };
    if (isClientSession(session)) {
        return {
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: session.expiresAt,
        };
    }
    return {
        accessToken: session.access_token,
        refreshToken: session.refresh_token,
        expiresAt: session.expires_at ?? computeExpiresAt(session.expires_in),
    };
}
function computeExpiresAt(expiresIn) {
    if (!expiresIn)
        return undefined;
    return Math.floor(Date.now() / 1000) + expiresIn;
}
function isClientSession(session) {
    return typeof session.accessToken === 'string';
}
