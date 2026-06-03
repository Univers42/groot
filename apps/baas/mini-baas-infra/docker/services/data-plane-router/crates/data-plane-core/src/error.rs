use thiserror::Error;

pub type DataPlaneResult<T> = Result<T, DataPlaneError>;

#[derive(Debug, Error)]
pub enum DataPlaneError {
    #[error("engine '{engine}' does not support requested capability '{capability}'")]
    UnsupportedCapability { engine: String, capability: String },

    #[error("mount '{mount_id}' was not found")]
    MountNotFound { mount_id: String },

    #[error("transaction '{tx_id}' was not found")]
    TransactionNotFound { tx_id: String },

    #[error("invalid identifier '{value}'")]
    InvalidIdentifier { value: String },

    #[error("credential for mount '{mount_id}' could not be resolved")]
    CredentialUnavailable { mount_id: String },

    /// A configured credential provider (Vault / adapter-registry) was reached
    /// but failed to return a usable credential (transport error, non-2xx, or a
    /// missing field in the response). Distinct from `CredentialUnavailable`,
    /// which means no source even produced an attempt (unknown provider /
    /// fail-closed). NEVER carries the DSN — only the provider name + mount id.
    #[error("credential provider '{provider}' failed for mount '{mount_id}'")]
    CredentialProviderFailed { provider: String, mount_id: String },

    #[error("backend error: {message}")]
    Backend { message: String },

    /// An integrity-constraint violation (unique/primary key, foreign key,
    /// not-null, check) — the client's write conflicts with existing data or a
    /// declared constraint. A client error (409 Conflict), distinct from
    /// `Backend` (an engine/transport failure, 5xx).
    #[error("conflict: {message}")]
    Conflict { message: String },

    /// The request itself is malformed or violates a safety rule (empty mutation
    /// filter, no updatable columns, wrong `data` shape). A client error (4xx),
    /// distinct from `Backend` (an engine/transport failure, 5xx).
    #[error("invalid request: {message}")]
    InvalidRequest { message: String },

    #[error("{feature} is not implemented in the Rust shadow data plane yet")]
    NotImplemented { feature: String },
}
