//! Concrete pool registry + engine adapters for the Rust data plane.
//!
//! This crate replaces the legacy TypeScript query-router behaviour of
//! constructing a fresh `new Client()` / `new MongoClient()` per request with
//! long-lived, mount-keyed connection pools. Implemented engines:
//!
//! - PostgreSQL (R2): `tokio-postgres` + `deadpool-postgres`, RLS GUCs
//!   `app.current_user_id` + `app.current_tenant_id` re-applied per checkout.
//! - MongoDB (R3): `mongodb` 2.8 driver (built-in pool per `Client`), tenant
//!   filter intersected server-side, `owner_id`/`tenant_id` decoration on every
//!   write so a forged document body cannot leak cross-tenant rows.
//! - MySQL (R7): `mysql_async` driver with built-in pool; server-side
//!   `owner_id` predicate enforced on every read/write.
//! - Redis (R8): `redis` crate with auto-reconnecting `ConnectionManager`;
//!   keys namespaced under `{owner}:{resource}:{id}` for tenant isolation.
//! - HTTP (R8): `reqwest` passthrough adapter that treats arbitrary REST
//!   backends as a "database"; forwards `X-Owner-Id` for upstream authz.

#[cfg(test)]
mod capability_honesty;
mod credential;
mod http;
mod ident;
mod mongo;
mod mysql;
mod postgres;
mod redis;
mod registry;
mod resolver;

pub use http::HttpEngineAdapter;
pub use mongo::MongoEngineAdapter;
pub use mysql::MysqlEngineAdapter;
pub use postgres::{PgDialect, PostgresEngineAdapter};
pub use redis::RedisEngineAdapter;
pub use credential::{
    AdapterRegistryProvider, CredentialProvider, ProviderConfig, ProviderRegistry, VaultProvider,
};
pub use registry::DefaultPoolRegistry;
pub use resolver::{EnvMountResolver, MountResolver};
