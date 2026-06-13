// Query Module — Phase 7: Triple Buffering + PointsBuffer zero-copy bridge
// Bridges the gap between LockFreeRingBuffer/Pyramid and dart:ffi.
// Provides PointsBuffer (ptr, len, generation) for zero-copy Dart read.

use lazy_static::lazy_static;
use parking_lot::Mutex;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

use crate::core::plot::lockfree_buffer::{LockFreeRingBuffer, RingDataPoint};
use crate::core::plot::time_bucket::TimeBucketPyramid;

// ── C-ABI export types ──────────────────────────────────────────────

/// PointsBuffer — zero-copy data bridge between Rust and Dart.
/// Dart reads this struct via dart:ffi, then uses ptr.asTypedList(len*2) for O(1) access.
#[repr(C)]
pub struct PointsBuffer {
    /// Pointer to interleaved x,y,x,y... Float32 array (pre-allocated, never freed)
    pub ptr: *const f32,
    /// Number of data points (not float count! actual points = len, floats = len*2)
    pub len: u32,
    /// Ring buffer generation counter — Dart compares to detect data overwrite
    pub generation: u64,
}

/// Latest timestamp helper (also exported via FFI)
#[repr(C)]
pub struct LatestTimestamp {
    pub timestamp_ms: f64,
    pub generation: u64,
}

// ── Triple Buffer ────────────────────────────────────────────────────

/// Triple buffering state: 3 pre-allocated Vec<f32>, rotated each get_points() call.
/// - Buffer 0: being read by Dart (via PointsBuffer.ptr)
/// - Buffer 1: being written by current query
/// - Buffer 2: idle / ready for next write
struct TripleBuffers {
    buffers: [Vec<f32>; 3],
    /// Which buffer is currently the "read" buffer (returned to Dart)
    read_idx: AtomicUsize,
    /// Maximum points per buffer (capacity for interleaved x,y pairs)
    capacity: usize,
}

impl TripleBuffers {
    fn new(max_points: usize) -> Self {
        let capacity = max_points * 2; // interleaved x,y
        Self {
            buffers: [
                vec![0.0f32; capacity],
                vec![0.0f32; capacity],
                vec![0.0f32; capacity],
            ],
            read_idx: AtomicUsize::new(0),
            capacity,
        }
    }

    /// Get pointer to the current read buffer (for Dart zero-copy access)
    fn read_ptr(&self) -> *const f32 {
        let idx = self.read_idx.load(Ordering::Acquire);
        self.buffers[idx].as_ptr()
    }

    /// Get which buffer index is the write target (next after read)
    fn write_idx(&self) -> usize {
        (self.read_idx.load(Ordering::Acquire) + 1) % 3
    }

    /// Get immutable reference to a buffer by index
    fn get_buf(&self, idx: usize) -> &Vec<f32> {
        &self.buffers[idx]
    }

    /// Get mutable reference to a buffer by index
    fn get_buf_mut(&mut self, idx: usize) -> &mut Vec<f32> {
        &mut self.buffers[idx]
    }

    /// Rotate: advance read index to point to freshly-written data.
    fn rotate(&self) {
        let old_read = self.read_idx.load(Ordering::Acquire);
        let new_read = (old_read + 1) % 3;
        self.read_idx.store(new_read, Ordering::Release);
    }

    /// Get capacity per buffer (in points, not floats)
    fn point_capacity(&self) -> usize {
        self.capacity / 2
    }
}

// ── Query State (global singleton) ───────────────────────────────────

/// Global query state: triple buffers + cached viewport parameters.
/// The Mutex protects only the brief write-to-buffer step, not the read path.
struct QueryState {
    buffers: TripleBuffers,
    /// Cached viewport time range (stored as f64 bits in atomics)
    t_start: AtomicU64,
    t_end: AtomicU64,
    max_points: AtomicUsize,
    /// Last known ring buffer generation for delta detection
    last_generation: AtomicU64,
}

impl QueryState {
    fn new(max_points: usize) -> Self {
        Self {
            buffers: TripleBuffers::new(max_points),
            t_start: AtomicU64::new(0),
            t_end: AtomicU64::new(f64::to_bits(1.0)),
            max_points: AtomicUsize::new(max_points),
            last_generation: AtomicU64::new(0),
        }
    }
}

lazy_static! {
    /// Global query state
    static ref QUERY_STATE: Mutex<QueryState> = Mutex::new(QueryState::new(4096));
}

// ── Public API ───────────────────────────────────────────────────────

/// Set viewport parameters for the next get_points() call.
pub fn set_viewport(t_start: f64, t_end: f64, max_points: u32) {
    let state = &mut *QUERY_STATE.lock();
    state
        .t_start
        .store(f64::to_bits(t_start), Ordering::Release);
    state.t_end.store(f64::to_bits(t_end), Ordering::Release);
    state
        .max_points
        .store(max_points as usize, Ordering::Release);
}

/// Get PointsBuffer pointing to freshly-interleaved data.
/// Called by Chart Isolate every ~16ms.
/// Returns pointer to pre-allocated buffer — no heap allocation on read path.
pub fn get_points(ring: &LockFreeRingBuffer, pyramid: &Mutex<TimeBucketPyramid>) -> PointsBuffer {
    let state = &mut *QUERY_STATE.lock();

    let t_start = f64::from_bits(state.t_start.load(Ordering::Acquire));
    let t_end = f64::from_bits(state.t_end.load(Ordering::Acquire));
    let max_points = state.max_points.load(Ordering::Acquire);

    let ring_gen = ring.generation();
    let delta_gen = ring_gen - state.last_generation.load(Ordering::Acquire);
    state.last_generation.store(ring_gen, Ordering::Release);

    let cap = state.buffers.point_capacity();

    // Phase 1: query data
    let pyramid_lock = pyramid.lock();
    let buckets = pyramid_lock.query(t_start, t_end, max_points);
    drop(pyramid_lock);

    // Phase 2: write into triple buffer (mutable borrow, then drop it)
    {
        let write_idx = state.buffers.write_idx();
        let write_buf = state.buffers.get_buf_mut(write_idx);

        if buckets.is_empty() {
            let available = ring.peek_len();
            if available > 0 {
                let mut raw = vec![
                    RingDataPoint {
                        timestamp_ms: 0.0,
                        value: 0.0
                    };
                    available.min(cap)
                ];
                let count = ring.read_into(&mut raw);
                interleave_ring_points(&raw[..count], write_buf);
            }
        } else {
            interleave_buckets(&buckets, max_points, write_buf);
        }
    } // mutable borrow ends here

    let point_count = {
        let write_idx = state.buffers.write_idx();
        let write_buf = state.buffers.get_buf(write_idx);
        if write_buf.len() >= 2 {
            write_buf.len() / 2
        } else {
            0
        }
    };

    state.buffers.rotate();

    PointsBuffer {
        ptr: state.buffers.read_ptr(),
        len: point_count as u32,
        generation: ring_gen.wrapping_add(delta_gen),
    }
}

/// Get just the generation counter (lightweight, no lock needed).
pub fn get_generation(ring: &LockFreeRingBuffer) -> u64 {
    ring.generation()
}

/// Get latest timestamp from ring buffer.
pub fn get_latest_timestamp(ring: &LockFreeRingBuffer) -> f64 {
    if ring.is_empty() {
        return 0.0;
    }
    let write_pos = ring.head();
    if write_pos == 0 {
        return 0.0;
    }
    let last_idx = (write_pos as usize - 1) & (ring.capacity() - 1);
    let data_ptr = unsafe { &*ring.data_ptr() };
    data_ptr[last_idx].timestamp_ms
}

// ── Internal helpers ─────────────────────────────────────────────────

fn interleave_ring_points(points: &[RingDataPoint], out: &mut Vec<f32>) {
    let needed = points.len() * 2;
    if out.len() < needed {
        out.resize(needed, 0.0);
    }
    for (i, pt) in points.iter().enumerate() {
        out[i * 2] = pt.timestamp_ms as f32;
        out[i * 2 + 1] = pt.value as f32;
    }
}

fn interleave_buckets(buckets: &[(f64, f64, f64, u32)], target_points: usize, out: &mut Vec<f32>) {
    let bucket_count = buckets.len();
    if bucket_count == 0 {
        return;
    }

    let needed = bucket_count * 4;
    if out.len() < needed {
        out.resize(needed, 0.0);
    }
    out.clear();

    if bucket_count > target_points {
        let ratio = bucket_count as f64 / target_points as f64;
        let mut i = 0;
        while i < bucket_count {
            let end = (((i + 1) as f64 * ratio) as usize).min(bucket_count);
            let mut chunk_min = f64::MAX;
            let mut chunk_max = f64::MIN;
            let ts = buckets[i].0;

            for j in i..end {
                let (_, lo, hi, _) = buckets[j];
                chunk_min = chunk_min.min(lo);
                chunk_max = chunk_max.max(hi);
            }

            out.push(ts as f32);
            out.push(chunk_min as f32);
            out.push(ts as f32 + 0.001);
            out.push(chunk_max as f32);

            i = end;
        }
    } else {
        for &(ts, lo, hi, _) in buckets {
            out.push(ts as f32);
            out.push(lo as f32);
            out.push(ts as f32 + 0.001);
            out.push(hi as f32);
        }
    }
}
