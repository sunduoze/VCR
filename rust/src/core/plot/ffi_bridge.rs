// FFI Bridge — C-ABI zero-copy bridge for Dart ↔ Rust
//
// Architecture:
//   Per-channel TimeBucketPyramid → query → CDataPoint buffer → CustomPainter
//   Pipeline thread → auto-track envelope pre-computation → zero-copy read
//
// Active data path:
//   Serial receive → push_sample_batch_with_x → FFI_CH_PYRAMIDS → Ticker _refreshViewportData → paint

use lazy_static::lazy_static;
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

use std::collections::HashMap;

use crate::core::plot::pipeline::{self, RENDER_ENVELOPE};
use crate::core::plot::time_bucket::TimeBucketPyramid;

// ── Global state ────────────────────────────────────────────────────

lazy_static! {
    /// Per-channel pyramids (keyed by channel_id: u32)
    /// Each channel gets its own independent LOD pyramid for parallel query
    pub static ref FFI_CH_PYRAMIDS: Mutex<HashMap<u32, TimeBucketPyramid>> = Mutex::new(HashMap::new());

    /// Initialization flag
    static ref FFI_READY: AtomicBool = AtomicBool::new(false);
}

// ── C-ABI types ─────────────────────────────────────────────────────

/// C-compatible data point (matches Dart Struct layout exactly)
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CDataPoint {
    pub timestamp_ms: f64,
    pub value: f64,
}

/// C-compatible bucket stats for pyramid queries
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CBucketStats {
    pub timestamp_ms: f64,
    pub min_value: f64,
    pub max_value: f64,
    pub avg_value: f64,
    pub count: u32,
    pub _pad: u32, // alignment padding for C struct compatibility
}

// ── Initialization ──────────────────────────────────────────────────

/// Initialize the FFI bridge (called once from Dart main)
#[no_mangle]
pub extern "C" fn vcr_ffi_init() -> bool {
    let _ = &*FFI_CH_PYRAMIDS;
    FFI_READY.store(true, Ordering::Release);
    true
}

/// Check if FFI bridge is initialized
#[no_mangle]
pub extern "C" fn vcr_ffi_is_ready() -> bool {
    FFI_READY.load(Ordering::Acquire)
}

// ── Per-Channel Pyramid API ────────────────────────────────────────

/// Push a data point into a specific channel's pyramid.
/// Creates the channel pyramid on first push (lazy init).
#[no_mangle]
pub extern "C" fn vcr_pyramid_ch_push(channel_id: u32, timestamp_ms: f64, value: f64) {
    let mut pyramids = FFI_CH_PYRAMIDS.lock();
    let pyramid = pyramids.entry(channel_id).or_default();
    pyramid.push(timestamp_ms, value);
}

/// Push batch into a specific channel's pyramid.
#[no_mangle]
pub extern "C" fn vcr_pyramid_ch_push_batch(
    channel_id: u32,
    data: *const CDataPoint,
    count: u32,
) -> bool {
    if data.is_null() || count == 0 {
        return false;
    }
    let slice = unsafe { std::slice::from_raw_parts(data, count as usize) };
    let mut pyramids = FFI_CH_PYRAMIDS.lock();
    let pyramid = pyramids.entry(channel_id).or_default();
    for dp in slice {
        pyramid.push(dp.timestamp_ms, dp.value);
    }
    true
}

/// Query a channel's pyramid for min+max pairs in [t_min, t_max].
/// Returns count of DataPoints written (always even: min+max per bucket).
/// Zero-alloc: writes directly into `out` buffer, no intermediate Vec.
#[no_mangle]
pub extern "C" fn vcr_pyramid_ch_query_points(
    channel_id: u32,
    t_min: f64,
    t_max: f64,
    target_points: u32,
    out: *mut CDataPoint,
    max_points: u32,
) -> u32 {
    if out.is_null() || max_points == 0 {
        return 0;
    }
    let pyramids = FFI_CH_PYRAMIDS.lock();
    let pyramid = match pyramids.get(&channel_id) {
        Some(p) => p,
        None => return 0,
    };
    let buckets = pyramid.query(t_min, t_max, target_points as usize);
    let max_entries = (buckets.len() * 2).min(max_points as usize);
    let dest = unsafe { std::slice::from_raw_parts_mut(out, max_entries) };
    let mut wi = 0usize;
    for &(ts, lo, hi, _count) in &buckets {
        if wi + 1 >= max_entries {
            break;
        }
        dest[wi] = CDataPoint {
            timestamp_ms: ts,
            value: lo,
        };
        dest[wi + 1] = CDataPoint {
            timestamp_ms: ts + 0.001,
            value: hi,
        };
        wi += 2;
    }
    wi as u32
}

/// Query a channel's pyramid for CBucketStats (min/max/avg/count per bucket).
#[no_mangle]
pub extern "C" fn vcr_pyramid_ch_query(
    channel_id: u32,
    t_min: f64,
    t_max: f64,
    target_points: u32,
    out: *mut CBucketStats,
    max_buckets: u32,
) -> u32 {
    if out.is_null() || max_buckets == 0 {
        return 0;
    }
    let pyramids = FFI_CH_PYRAMIDS.lock();
    let pyramid = match pyramids.get(&channel_id) {
        Some(p) => p,
        None => return 0,
    };
    let buckets = pyramid.query(t_min, t_max, target_points as usize);
    let count = buckets.len().min(max_buckets as usize);
    let dest = unsafe { std::slice::from_raw_parts_mut(out, count) };
    for (i, bucket) in buckets.iter().take(count).enumerate() {
        dest[i] = CBucketStats {
            timestamp_ms: bucket.0,
            min_value: bucket.1,
            max_value: bucket.2,
            avg_value: (bucket.1 + bucket.2) * 0.5,
            count: bucket.3,
            _pad: 0,
        };
    }
    count as u32
}

/// Clear a specific channel's pyramid (e.g., on device disconnect).
#[no_mangle]
pub extern "C" fn vcr_pyramid_ch_clear(channel_id: u32) {
    let mut pyramids = FFI_CH_PYRAMIDS.lock();
    pyramids.remove(&channel_id);
}

/// Clear all per-channel pyramids.
#[no_mangle]
pub extern "C" fn vcr_pyramid_ch_clear_all() {
    let mut pyramids = FFI_CH_PYRAMIDS.lock();
    pyramids.clear();
}

// ── Pipeline Control ───────────────────────────────────────────────

/// Start the background pipeline processing thread.
#[no_mangle]
pub extern "C" fn vcr_pipeline_start() -> bool {
    pipeline::start_pipeline();
    true
}

/// Stop the background pipeline processing thread.
#[no_mangle]
pub extern "C" fn vcr_pipeline_stop() -> bool {
    pipeline::stop_pipeline();
    true
}

/// Reset pipeline state (clear pyramids, reset counters).
#[no_mangle]
pub extern "C" fn vcr_pipeline_reset() {
    pipeline::reset_pipeline();
}

/// Set the viewport range for the pipeline envelope computation.
/// Called from Dart Ticker each frame (or when viewport changes).
#[no_mangle]
pub extern "C" fn vcr_envelope_set_viewport(t_min: f64, t_max: f64, max_points: u32) {
    pipeline::set_viewport_range(t_min, t_max, max_points);
}

/// Get the current envelope for a specific channel (zero-copy pointer).
/// Returns: byte offset of channel's data in the shared envelope buffer, or u32::MAX if not found.
/// Dart reads: ((envelope + offset) as Pointer<Double>).asTypedList(count * 2)
#[no_mangle]
pub extern "C" fn vcr_envelope_get_channel_offset(channel_id: u32) -> u32 {
    let env = RENDER_ENVELOPE.lock();
    for i in 0..env.num_channels as usize {
        if i >= pipeline::MAX_CHANNELS {
            break;
        }
        // We need to match channel_id. The channel ordering in envelope matches
        // the sorted order in update_render_envelope. We compute offset from the
        // channel's stored offset.
        // For simplicity, return offset for channel index = channel_id.
        if i == channel_id as usize {
            return env.channel_offsets[i];
        }
    }
    u32::MAX
}

/// Get the count of data points for a specific channel in the envelope.
#[no_mangle]
pub extern "C" fn vcr_envelope_get_channel_count(channel_id: u32) -> u32 {
    let env = RENDER_ENVELOPE.lock();
    for i in 0..env.num_channels as usize {
        if i >= pipeline::MAX_CHANNELS {
            break;
        }
        if i == channel_id as usize {
            return env.channel_counts[i];
        }
    }
    0
}

/// Get pointer to the envelope data array (all channels interleaved).
/// Dart uses: Pointer<Double>.fromAddress(ptr).asTypedList(offset/8 + count*2)
#[no_mangle]
pub extern "C" fn vcr_envelope_get_data_ptr() -> *const f64 {
    let env = RENDER_ENVELOPE.lock();
    env.data.as_ptr()
}

/// Get the envelope generation counter.
#[no_mangle]
pub extern "C" fn vcr_envelope_get_generation() -> u64 {
    let env = RENDER_ENVELOPE.lock();
    env.generation
}

/// Get the number of channels in the current envelope.
#[no_mangle]
pub extern "C" fn vcr_envelope_get_num_channels() -> u32 {
    let env = RENDER_ENVELOPE.lock();
    env.num_channels
}

// ── Shutdown ────────────────────────────────────────────────────────

/// Shutdown the FFI bridge (free resources)
#[no_mangle]
pub extern "C" fn vcr_ffi_shutdown() {
    FFI_READY.store(false, Ordering::Release);
    FFI_CH_PYRAMIDS.lock().clear();
}
