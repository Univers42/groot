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

// The boot-time honesty battery iterates every adapter, so it only compiles
// when every engine feature is on (the default — `cargo test` runs it).
#[cfg(all(
    test,
    feature = "postgres",
    feature = "mongodb",
    feature = "mysql",
    feature = "redis",
    feature = "sqlite",
    feature = "mssql",
    feature = "http"
))]
mod capability_honesty;
mod credential;
pub mod service_auth;
#[cfg(feature = "http")]
mod http;
mod ident;
#[cfg(feature = "mongodb")]
mod mongo;
#[cfg(feature = "mssql")]
mod mssql;
#[cfg(feature = "mysql")]
mod mysql;
#[cfg(feature = "postgres")]
mod postgres;
#[cfg(feature = "redis")]
mod redis;
mod registry;
mod resolver;
#[cfg(feature = "sqlite")]
mod sqlite;
mod tls;

#[cfg(feature = "http")]
pub use http::{guard_and_resolve, HttpEngineAdapter};
#[cfg(feature = "mongodb")]
pub use mongo::MongoEngineAdapter;
#[cfg(feature = "mssql")]
pub use mssql::MssqlEngineAdapter;
#[cfg(feature = "mysql")]
pub use mysql::MysqlEngineAdapter;
#[cfg(feature = "postgres")]
pub use postgres::{PgDialect, PostgresEngineAdapter};
#[cfg(feature = "redis")]
pub use redis::RedisEngineAdapter;
#[cfg(feature = "sqlite")]
pub use sqlite::SqliteEngineAdapter;
pub use credential::{
    AdapterRegistryProvider, CredentialProvider, ProviderConfig, ProviderRegistry, VaultProvider,
};
pub use registry::DefaultPoolRegistry;
pub use resolver::{EnvMountResolver, MountResolver};
