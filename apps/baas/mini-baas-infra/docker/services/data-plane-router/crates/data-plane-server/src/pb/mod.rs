//! PocketBase-compatible facade (`/api/...`) — feature `pbcompat`, shipped in
//! binocle-one, NEVER in nano.
//!
//! A translation layer over the existing engine: PB wire shapes (filter DSL,
//! response envelopes, collection schemas) in, native operations out. The
//! native `/data/v1` + `/one/v1` contracts stay untouched and remain the fast
//! path; this module exists so the OFFICIAL PocketBase JS/Dart SDKs work
//! against binocle-one unchanged (gate m48 runs the real `pocketbase` npm
//! package against both us and real PB and diffs the outcomes).

pub mod filter;
