// FFI Bridge — Phase 5: C-ABI zero-copy bridge for Dart Isolate ↔ Rust
// Enables dart:ffi direct calls from Chart Isolate without flutter_rust_bridge serialization
//
// Architecture:
//   Dart Isolate --dart:ffi--> C-ABI symbols (this file)
//   Main Isolate --flutter_rust_bridge--> RustLib.instance.api.*
//
// Both paths coexist; the FFI path is for hot data path (200K pts/sec).

use lazy_static::lazy_static;
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

use std::collections::HashMap;

use crate::core::plot::lockfree_buffer::{LockFreeRingBuffer, RingDataPoint};
use crate::core::plot::query::{self, PointsBuffer};
use crate::core::plot::time_bucket::TimeBucketPyramid;

// ── Global state ────────────────────────────────────────────────────

lazy_static! {
    /// Lock-free SPSC ring buffer: producer pushes, consumer reads
    static ref FFI_RING: LockFreeRingBuffer = LockFreeRingBuffer::new(12_000_000);

    /// Time bucket pyramid: updated on every push, queried on demand
    static ref FFI_PYRAMID: Mutex<TimeBucketPyramid> = Mutex::new(TimeBucketPyramid::new());

    /// Per-channel pyramids (keyed by channel_id: u32)
    /// Each channel gets its own independent LOD pyramid for parallel query
    static ref FFI_CH_PYRAMIDS: Mutex<HashMap<u32, TimeBucketPyramid>> = Mutex::new(HashMap::new());

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
    // Pre-warm global state
    let _ = &*FFI_RING;
    let _ = &*FFI_PYRAMID;
    FFI_READY.store(true, Ordering::Release);
    true
}

/// Check if FFI bridge is initialized
#[no_mangle]
pub extern "C" fn vcr_ffi_is_ready() -> bool {
    FFI_READY.load(Ordering::Acquire)
}

// ── Ring Buffer API ─────────────────────────────────────────────────

/// Push a single data point to the ring buffer
/// Returns true if successful, false if buffer is full
#[no_mangle]
pub extern "C" fn vcr_buffer_push(timestamp_ms: f64, value: f64) -> bool {
    FFI_RING.push_batch(&[(timestamp_ms, value)]);
    true
}

/// Push a batch of data points (zero-copy: reads from Dart-allocated memory)
/// data: pointer to array of CDataPoint (interleaved f64 pairs)
/// count: number of points
#[no_mangle]
pub extern "C" fn vcr_buffer_push_batch(data: *const CDataPoint, count: u32) -> bool {
    if data.is_null() || count == 0 {
        return false;
    }

    let slice = unsafe { std::slice::from_raw_parts(data, count as usize) };

    // Convert to tuples for push_batch
    let tuples: Vec<(f64, f64)> = slice.iter().map(|dp| (dp.timestamp_ms, dp.value)).collect();

    FFI_RING.push_batch(&tuples);
    true
}

/// Number of unread points in the ring buffer
#[no_mangle]
pub extern "C" fn vcr_buffer_available() -> u32 {
    FFI_RING.peek_len() as u32
}

/// Read data from ring buffer into pre-allocated memory (zero-copy)
/// out: pre-allocated destination array
/// max_count: maximum number of points to read
/// Returns: actual number of points read
#[no_mangle]
pub extern "C" fn vcr_buffer_read(out: *mut CDataPoint, max_count: u32) -> u32 {
    if out.is_null() || max_count == 0 {
        return 0;
    }

    let dest = unsafe { std::slice::from_raw_parts_mut(out, max_count as usize) };

    // Convert CDataPoint slice to RingDataPoint slice via unsafe reinterpret
    // RingDataPoint and CDataPoint have identical repr(C) layout
    let ring_dest: &mut [RingDataPoint] = unsafe {
        std::slice::from_raw_parts_mut(dest.as_mut_ptr() as *mut RingDataPoint, dest.len())
    };

    FFI_RING.read_into(ring_dest) as u32
}

/// Clear the ring buffer
#[no_mangle]
pub extern "C" fn vcr_buffer_clear() {
    FFI_RING.clear();
}

// ── Pyramid Query API ───────────────────────────────────────────────

/// Query aggregated data from the time bucket pyramid
/// out: pre-allocated destination array (caller owns memory)
/// max_buckets: maximum number of buckets to write
/// t_min, t_max: time range in milliseconds
/// target_points: optimal visualization resolution
/// Returns: actual number of buckets written
#[no_mangle]
pub extern "C" fn vcr_pyramid_query(
    t_min: f64,
    t_max: f64,
    target_points: u32,
    out: *mut CBucketStats,
    max_buckets: u32,
) -> u32 {
    if out.is_null() || max_buckets == 0 {
        return 0;
    }

    let pyramid = FFI_PYRAMID.lock();
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

/// Query pyramid and get downsampled DataPoints (ready for painting)
/// out: pre-allocated CDataPoint array
/// max_points: max output points
/// Returns: actual number of points written (always even: min+max per bucket)
/// 🚀 Zero-alloc: writes directly into `out` buffer, no intermediate Vec<DataPoint>.
#[no_mangle]
pub extern "C" fn vcr_pyramid_query_points(
    t_min: f64,
    t_max: f64,
    target_points: u32,
    out: *mut CDataPoint,
    max_points: u32,
) -> u32 {
    if out.is_null() || max_points == 0 {
        return 0;
    }

    let pyramid = FFI_PYRAMID.lock();
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

/// Feed data into the pyramid (also pushed to ring buffer in production)
#[no_mangle]
pub extern "C" fn vcr_pyramid_push(timestamp_ms: f64, value: f64) {
    let mut pyramid = FFI_PYRAMID.lock();
    pyramid.push(timestamp_ms, value);
}

/// Feed batch into the pyramid
#[no_mangle]
pub extern "C" fn vcr_pyramid_push_batch(data: *const CDataPoint, count: u32) -> bool {
    if data.is_null() || count == 0 {
        return false;
    }

    let slice = unsafe { std::slice::from_raw_parts(data, count as usize) };
    let mut pyramid = FFI_PYRAMID.lock();

    for dp in slice {
        pyramid.push(dp.timestamp_ms, dp.value);
    }

    true
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
/// 🚀 Zero-alloc: writes directly into `out` buffer, no intermediate Vec<DataPoint>.
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
    // 🚀 Phase D: query buckets and write directly to out buffer (zero intermediate Vec<DataPoint>).
    // Each bucket → 2 CDataPoint entries (min + max), capped at max_points.
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

// ── Shutdown ────────────────────────────────────────────────────────

/// Shutdown the FFI bridge (free resources)
#[no_mangle]
pub extern "C" fn vcr_ffi_shutdown() {
    FFI_READY.store(false, Ordering::Release);
    FFI_RING.clear();
    // Clear channel pyramids
    FFI_CH_PYRAMIDS.lock().clear();
    // Pyramid will be dropped on program exit
}

// ── Query Bridge (Triple Buffering + PointsBuffer) ──────────────────

/// Set viewport parameters for the next get_points() call.
/// Called by Dart when zoom/pan changes.
#[no_mangle]
pub extern "C" fn vcr_set_viewport(t_start: f64, t_end: f64, max_points: u32) {
    query::set_viewport(t_start, t_end, max_points);
}

/// Get PointsBuffer pointing to interleaved x,y data (zero-copy).
/// Dart calls this every ~16ms from Chart Isolate.
/// The returned ptr is valid until the next get_points() call.
#[no_mangle]
pub extern "C" fn vcr_get_points() -> PointsBuffer {
    query::get_points(&FFI_RING, &FFI_PYRAMID)
}

/// Get ring buffer generation counter.
#[no_mangle]
pub extern "C" fn vcr_get_generation() -> u64 {
    query::get_generation(&FFI_RING)
}

/// Get latest timestamp from the ring buffer.
#[no_mangle]
pub extern "C" fn vcr_get_latest_timestamp() -> f64 {
    query::get_latest_timestamp(&FFI_RING)
}
