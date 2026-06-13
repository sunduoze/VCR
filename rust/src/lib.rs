// ===== Crate-level clippy allows (architectural decisions) =====
// FFI bridge: raw pointers are inherent to C-ABI interop
#![allow(clippy::not_unsafe_ptr_arg_deref)]
// flutter_rust_bridge codegen: API functions inherently have many parameters
#![allow(clippy::too_many_arguments)]
// Global data structures: complex types by design
#![allow(clippy::type_complexity)]
// Signal processing loops: range indexing is idiomatic for min/max bucketing
#![allow(clippy::needless_range_loop)]

pub mod api;
pub mod core;
mod frb_generated;
pub mod renderer;
