/// Scale power — each envelope level aggregates 2^5 = 32 samples
pub const ENVELOPE_SCALE_POWER: u32 = 5;
/// Per-level scale factor
pub const ENVELOPE_SCALE_FACTOR: u32 = 1 << 5; // 32
/// ln(32) ~ 3.465735903 — precomputed for level selection formula
pub const LN_ENVELOPE_SCALE_FACTOR: f64 = 3.4657359027997265;
/// Envelope memory allocation alignment unit (64KB)
pub const ENVELOPE_DATA_UNIT: usize = 64 * 1024;
/// Number of envelope levels
pub const SCALE_STEP_COUNT: usize = 6;
/// Default pyramid level count (configurable at runtime, 3-6)
pub const DEFAULT_LEVEL_COUNT: usize = 6;
/// Minimum allowed level count
pub const MIN_LEVEL_COUNT: usize = 3;
/// Maximum allowed level count
pub const MAX_LEVEL_COUNT: usize = 6;
/// Bytes per sample (f32)
pub const UNIT_SIZE: usize = std::mem::size_of::<f32>(); // 4
/// Raw data chunk storage size (1MB)
pub const MAX_CHUNK_SIZE: usize = 1 * 1024 * 1024;
/// Maximum number of channels (unchanged from existing)
pub const MAX_CHANNELS: usize = 64;
/// Max raw_trace samples per channel (250K × 4 bytes = 1MB).
/// Caps the unbounded Vec<f32> to prevent realloc memcpy spikes
/// when push_sample is called at high frequency (720/sec per channel).
pub const MAX_RAW_TRACE_SAMPLES: usize = 250_000;
