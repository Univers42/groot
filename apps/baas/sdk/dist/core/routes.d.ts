export declare const routes: {
    readonly auth: {
        readonly token: (grantType: "password" | "refresh_token") => string;
        readonly signup: "/auth/v1/signup";
        readonly recover: "/auth/v1/recover";
        readonly verify: "/auth/v1/verify";
        readonly logout: "/auth/v1/logout";
        readonly user: "/auth/v1/user";
        readonly adminUsers: "/auth/v1/admin/users";
        readonly adminUser: (id: string) => string;
        readonly adminGenerateLink: "/auth/v1/admin/generate_link";
    };
    readonly rest: {
        readonly root: "/rest/v1/";
        readonly resource: (resource: string) => string;
        readonly rpc: (name: string) => string;
    };
    readonly query: {
        readonly execute: "/query/v1/execute";
    };
    readonly storage: {
        readonly sign: (bucket: string, key: string) => string;
    };
    readonly analytics: {
        readonly events: "/analytics/v1/events";
    };
    readonly realtime: {
        readonly channel: (channel: string) => string;
    };
};
