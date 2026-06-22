/// Scale power — each envelope level aggregates 2^4 = 16 samples
pub const ENVELOPE_SCALE_POWER: u32 = 4;
/// Per-level scale factor
pub const ENVELOPE_SCALE_FACTOR: u32 = 1 << 4; // 16
/// ln(16) ~ 2.772588722 — precomputed for level selection formula
pub const LN_ENVELOPE_SCALE_FACTOR: f64 = 2.772588722239781;
/// Envelope memory allocation alignment unit (64KB)
pub const ENVELOPE_DATA_UNIT: usize = 64 * 1024;
/// Number of envelope levels
pub const SCALE_STEP_COUNT: usize = 10;
/// Default pyramid level count (configurable at runtime, 3-10)
pub const DEFAULT_LEVEL_COUNT: usize = 10;
/// Minimum allowed level count
pub const MIN_LEVEL_COUNT: usize = 3;
/// Maximum allowed level count
pub const MAX_LEVEL_COUNT: usize = 10;
/// Bytes per sample (f32)
pub const UNIT_SIZE: usize = std::mem::size_of::<f32>(); // 4
/// Raw data chunk storage size (1MB)
pub const MAX_CHUNK_SIZE: usize = 1 * 1024 * 1024;
/// Maximum number of channels (unchanged from existing)
pub const MAX_CHANNELS: usize = 64;
