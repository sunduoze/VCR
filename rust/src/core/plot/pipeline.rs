// Data Pipeline — Phase A: Background processing thread for lock-free data flow
//
// Architecture (reference framework aligned):
//   Serial receive → PENDING_BATCHES (batch buffer) → Pipeline thread → Per-channel pyramids
//                                                                          ↓
//                                                            RenderEnvelope (pre-computed)
//                                                                          ↓
//                                                        Dart Ticker → zero-copy read → CustomPainter
//
// Key improvement (P0-1): receive_loop writes to lightweight batch buffer;
// only the pipeline thread touches FFI_CH_PYRAMIDS → zero Mutex contention.
//
// Eliminates: Dart frb round-trip, per-frame pyramid Mutex contention, 50ms Timer jitter

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::thread::{self, JoinHandle};
use std::collections::HashMap;
use std::time::Duration;

use parking_lot::Mutex;
use lazy_static::lazy_static;

use crate::core::plot::ffi_bridge::FFI_CH_PYRAMIDS;
use crate::core::plot::analog_segment::AnalogSegment;
use std::sync::Arc;
use parking_lot::RwLock;

// ── P0-1: Receive→Pipeline batch buffer ───────────────────────────
// Eliminates Mutex contention between receive_loop (producer) and
// pipeline_loop (consumer) on FFI_CH_PYRAMIDS.
//
// Producer: receive_loop appends (x, values) — lock time = Vec::push (~50ns)
// Consumer: pipeline_loop drains via std::mem::take — lock time = pointer swap (~20ns)
// Prev: both contended on FFI_CH_PYRAMIDS Mutex during pyramid insert (many µs per batch)

/// One CSV line worth of multi-channel data
struct BatchEntry {
    x: f64,
    /// values[i] = sample value for channel i (single-channel push uses vec![value])
    values: Vec<f64>,
    /// If Some(id), override channel index (0-based) with explicit channel_id
    /// Used by push_sample() which carries an explicit channel_id.
    /// If None, values are indexed by their position (push_sample_batch / push_sample_batch_with_x).
    channel_id: Option<u32>,
}

lazy_static! {
    /// Pre-allocated batch buffer (producer appends, consumer drains)
    static ref PENDING_BATCHES: Mutex<Vec<BatchEntry>> = Mutex::new(Vec::with_capacity(256));

    /// Per-channel AnalogSegment instances (10-level envelope pyramid, f32)
    /// Parallel path alongside FFI_CH_PYRAMIDS for progressive migration.
    pub static ref FFI_CH_ANALOG: RwLock<HashMap<u32, Arc<AnalogSegment>>> = RwLock::new(HashMap::new());

    /// Toggle: when true, update_render_envelope reads from AnalogSegment
    /// instead of TimeBucketPyramid. Set via C-ABI from Dart.
    pub static ref USE_ANALOG_FOR_ENVELOPE: RwLock<bool> = RwLock::new(false);

    /// Toggle: when true, push_sample* via console (debug_api) routes to pyramids.
    /// When false (Demo active), console data is blocked from FFI_CH_PYRAMIDS
    /// to prevent timestampMs collision with Demo's sample-index-based pyramid entries.
    /// DEFAULT: false — VCR starts in Demo mode; real data is blocked until
    /// _toggleDataSource() explicitly enables it.
    pub static ref PYRAMIDS_ACCEPT_CONSOLE: RwLock<bool> = RwLock::new(false);
}

/// Drain all pending batches (called from pipeline_loop only).
/// Returns ownership of all buffered entries; lock held only for pointer swap.
fn drain_pending_batches() -> Vec<BatchEntry> {
    let mut pending = PENDING_BATCHES.lock();
    if pending.is_empty() {
        return Vec::new();
    }
    std::mem::take(&mut *pending)
}

// ── Viewport range storage (Dart → pipeline communication) ──────────

/// Dart sets this to the current viewport range (ABSOLUTE coordinates).
/// Stored as f64 bit patterns in atomics for lock-free read.
static VP_T_MIN: AtomicU64 = AtomicU64::new(0);
static VP_T_MAX: AtomicU64 = AtomicU64::new(f64::to_bits(1.0));
/// Anchor: the absolute X of the newest data point (ch.data.last.x).
/// Used by `update_render_envelope_from_analog` to convert absolute
/// viewport coords → AnalogSegment sample indices.
///   start_sample = anchor + (t_min - anchor) = t_min  (when anchor ≈ sample_count-1)
/// But in Real mode anchor=timestampMs while AnalogSegment uses push_count,
/// so we need the relative form: rel_min = t_min - anchor (= _xMin)
/// and then: start_sample = (sample_count - 1) + rel_min
static VP_ANCHOR: AtomicU64 = AtomicU64::new(0);
static VP_MAX_PTS: AtomicU64 = AtomicU64::new(2000);
/// Non-zero when Dart has set the viewport at least once.
static VP_DIRTY: AtomicBool = AtomicBool::new(false);
/// Counter incremented when viewport changes — pipeline compares to detect change.
static VP_GEN: AtomicU64 = AtomicU64::new(0);

/// Set to true by push_sample* functions when new data arrives.
/// Cleared by Dart Ticker after reading (via C-ABI).
pub static DATA_READY: AtomicBool = AtomicBool::new(false);

/// Set the viewport range from Dart.
/// Called each frame (or when viewport changes) from Ticker callback.
/// `t_min`/`t_max` are ABSOLUTE coords (e.g. timestampMs or sample-index).
/// `anchor` = ch.data.last.x (the newest data point's X).
/// For TimeBucketPyramid: uses `t_min`/`t_max` directly (pyramid stores abs coords).
/// For AnalogSegment: converts to relative via `t_min - anchor` → AnalogSegment idx.
pub fn set_viewport_range(t_min: f64, t_max: f64, max_points: u32, anchor: f64) {
    let old_min = VP_T_MIN.swap(f64::to_bits(t_min), Ordering::Release);
    let old_max = VP_T_MAX.swap(f64::to_bits(t_max), Ordering::Release);
    VP_ANCHOR.store(f64::to_bits(anchor), Ordering::Release);
    VP_MAX_PTS.store(max_points as u64, Ordering::Release);
    if (old_min != f64::to_bits(t_min)) || (old_max != f64::to_bits(t_max)) {
        VP_GEN.fetch_add(1, Ordering::Release);
    }
    VP_DIRTY.store(true, Ordering::Release);
}

// ── Global pipeline state ──────────────────────────────────────────

lazy_static! {
    /// Global sample counter — monotonically increasing, shared across all channels
    pub static ref GLOBAL_SAMPLE_IDX: AtomicU64 = AtomicU64::new(0);

    /// Pipeline worker thread handle
    static ref PIPELINE_HANDLE: Mutex<Option<JoinHandle<()>>> = Mutex::new(None);

    /// Pipeline running flag
    static ref PIPELINE_RUNNING: AtomicBool = AtomicBool::new(false);

    /// Current pyramid level count for newly created AnalogSegments (3-10).
    /// Must be set BEFORE creating channels. Changing requires data clear + recreate.
    pub static ref ANALOG_LEVEL_COUNT: RwLock<usize> = RwLock::new(10);
}

// ── Render envelope (pre-computed, ready for Dart paint) ───────────

/// Maximum channels supported
pub const MAX_CHANNELS: usize = 64;

/// Maximum envelope points per channel (2 floats each: x + y)
const MAX_ENVELOPE_PTS_PER_CHANNEL: usize = 4000 * 2; // 4000 px × 2 pts (min+max) × 2 floats

/// Pre-computed render envelope for zero-copy Dart consumption.
/// Layout: [ch0_min_pts..., ch0_max_pts..., ch1_min_pts..., ch1_max_pts..., ...]
/// channel_offsets[i] = byte offset of channel i's data
/// channel_counts[i] = number of float pairs (x,y) for channel i
/// 
/// NOTE: data is a Vec<f64> (heap-allocated) to avoid stack overflow from
/// the 4MB inline array (MAX_CHANNELS * MAX_ENVELOPE_PTS_PER_CHANNEL * 8 bytes).
pub struct RenderEnvelope {
    /// Total number of active channels
    pub num_channels: u32,
    /// Byte offset of each channel's data in `data`
    pub channel_offsets: [u32; MAX_CHANNELS],
    /// Number of f64 pairs (x,y) for each channel
    pub channel_counts: [u32; MAX_CHANNELS],
    /// Interleaved f64 data: x0,y0, x1,y1, ... (heap-allocated, ~4MB)
    pub data: Vec<f64>,
    /// Viewport X range used to compute this envelope
    pub viewport_x_min: f64,
    pub viewport_x_max: f64,
    /// Generation counter (incremented each update)
    pub generation: u64,
}

unsafe impl Send for RenderEnvelope {}
unsafe impl Sync for RenderEnvelope {}

lazy_static! {
    /// Global render envelope (updated by pipeline, read by Dart via C-ABI)
    pub static ref RENDER_ENVELOPE: Mutex<RenderEnvelope> = Mutex::new(RenderEnvelope {
        num_channels: 0,
        channel_offsets: [0u32; MAX_CHANNELS],
        channel_counts: [0u32; MAX_CHANNELS],
        data: vec![0f64; MAX_CHANNELS * MAX_ENVELOPE_PTS_PER_CHANNEL],
        viewport_x_min: 0.0,
        viewport_x_max: 0.0,
        generation: 0,
    });
}

// ── Pipeline lifecycle ─────────────────────────────────────────────

/// Start the background pipeline thread.
/// Processes incoming data and updates per-channel pyramids + render envelope.
pub fn start_pipeline() {
    if PIPELINE_RUNNING.load(Ordering::Acquire) {
        return;
    }

    PIPELINE_RUNNING.store(true, Ordering::Release);

    let handle = thread::Builder::new()
        .name("vcr-pipeline".into())
        .spawn(move || {
            pipeline_loop();
        })
        .expect("Failed to spawn pipeline thread");

    *PIPELINE_HANDLE.lock() = Some(handle);
    log::info!("[Pipeline] Background processing thread started");
}

/// Stop the pipeline thread.
pub fn stop_pipeline() {
    PIPELINE_RUNNING.store(false, Ordering::Release);
    if let Some(handle) = PIPELINE_HANDLE.lock().take() {
        let _ = handle.join();
        log::info!("[Pipeline] Background processing thread stopped");
    }
}

// ── Data ingestion (called from receive loop) ──────────────────────

/// Push a single sample into the batch buffer (producer-side).
/// Stores explicit channel_id so pipeline_loop can route correctly.
///
/// When pipeline is ON:  batch → pipeline_loop drains → pyramids + analog (no dual-write race).
/// When pipeline is OFF: direct push to pyramids for per-channel query.
pub fn push_sample(channel_id: u32, value: f64) {
    // Demo mode: console data must NOT pollute any Rust data path.
    // PYRAMIDS_ACCEPT_CONSOLE=false means Demo is active — console data
    // (timestampMs) would corrupt Demo's AnalogSegment and pyramid (sample-index based).
    if !*PYRAMIDS_ACCEPT_CONSOLE.read() {
        return;
    }
    let x = GLOBAL_SAMPLE_IDX.fetch_add(1, Ordering::Relaxed) as f64;
    if PIPELINE_RUNNING.load(Ordering::Acquire) {
        PENDING_BATCHES.lock().push(BatchEntry { x, values: vec![value], channel_id: Some(channel_id) });
        DATA_READY.store(true, Ordering::Release);
    } else {
        let analog_map = FFI_CH_ANALOG.read();
        let mut pyramids = FFI_CH_PYRAMIDS.lock();
        let pyramid = pyramids.entry(channel_id).or_default();
        pyramid.push(x, value);
        if let Some(analog) = analog_map.get(&channel_id) {
            analog.push_sample(value as f32);
        }
    }
}

/// Push a multi-channel sample (one CSV line → multiple channels).
/// Channel index = position in values array.
pub fn push_sample_batch(values: &[f64]) {
    // Demo mode guard: same rationale as push_sample.
    if !*PYRAMIDS_ACCEPT_CONSOLE.read() {
        return;
    }
    let x = GLOBAL_SAMPLE_IDX.fetch_add(1, Ordering::Relaxed) as f64;
    if PIPELINE_RUNNING.load(Ordering::Acquire) {
        PENDING_BATCHES.lock().push(BatchEntry { x, values: values.to_vec(), channel_id: None });
        DATA_READY.store(true, Ordering::Release);
    } else {
        let analog_map = FFI_CH_ANALOG.read();
        let mut pyramids = FFI_CH_PYRAMIDS.lock();
        for (ci, value) in values.iter().enumerate() {
            let channel_id = ci as u32;
            let pyramid = pyramids.entry(channel_id).or_default();
            pyramid.push(x, *value);
            if let Some(analog) = analog_map.get(&channel_id) {
                analog.push_sample(*value as f32);
            }
        }
    }
}

/// Push a multi-channel sample with explicit X value (syncs with PLOT_DATA counter).
/// Used from receive loop where PLOT_DATA.next_counter() is the canonical X.
///
/// Data path:
///   Pipeline ON  → PENDING_BATCHES → pipeline_loop drains → FFI_CH_PYRAMIDS + FFI_CH_ANALOG
///   Pipeline OFF → Direct push to FFI_CH_PYRAMIDS (no pipeline thread running)
///
/// This eliminates the previous dual-write race: when the pipeline thread holds
/// FFI_CH_PYRAMIDS lock during Step 1 drain, this function no longer contends on it.
pub fn push_sample_batch_with_x(x: f64, values: &[f64]) {
    // Demo mode guard: same rationale as push_sample.
    if !*PYRAMIDS_ACCEPT_CONSOLE.read() {
        return;
    }
    if PIPELINE_RUNNING.load(Ordering::Acquire) {
        PENDING_BATCHES.lock().push(BatchEntry { x, values: values.to_vec(), channel_id: None });
        DATA_READY.store(true, Ordering::Release);
    } else {
        let analog_map = FFI_CH_ANALOG.read();
        let mut pyramids = FFI_CH_PYRAMIDS.lock();
        for (ci, value) in values.iter().enumerate() {
            let channel_id = ci as u32;
            let pyramid = pyramids.entry(channel_id).or_default();
            pyramid.push(x, *value);
            if let Some(analog) = analog_map.get(&channel_id) {
                analog.push_sample(*value as f32);
            }
        }
    }
}

/// Get the current global sample index (for Dart to sync X values).
pub fn get_sample_index() -> f64 {
    GLOBAL_SAMPLE_IDX.load(Ordering::Relaxed) as f64
}

// ── Render envelope update (called from pipeline thread) ───────────

/// Update the render envelope for the given viewport range.
/// Called from pipeline thread periodically.
pub fn update_render_envelope(t_min: f64, t_max: f64, target_points: u32) {
    if *USE_ANALOG_FOR_ENVELOPE.read() {
        update_render_envelope_from_analog(t_min, t_max, target_points);
    } else {
        update_render_envelope_from_pyramids(t_min, t_max, target_points);
    }
}

/// Envelope from TimeBucketPyramid (existing path).
fn update_render_envelope_from_pyramids(t_min: f64, t_max: f64, target_points: u32) {
    let pyramids = FFI_CH_PYRAMIDS.lock();
    let num_channels = pyramids.len().min(MAX_CHANNELS);
    if num_channels == 0 {
        return;
    }

    let mut envelope = RENDER_ENVELOPE.lock();

    // Bump generation to odd (signals "update in progress" to readers)
    envelope.generation = envelope.generation.wrapping_add(1);

    // Sort channel IDs for consistent ordering
    let mut channel_ids: Vec<u32> = pyramids.keys().copied().collect();
    channel_ids.sort_unstable();
    channel_ids.truncate(MAX_CHANNELS);

    let mut byte_offset: u32 = 0;

    for (i, &ch_id) in channel_ids.iter().enumerate() {
        envelope.channel_offsets[i] = byte_offset;

        if let Some(pyramid) = pyramids.get(&ch_id) {
            let buckets = pyramid.query(t_min, t_max, target_points as usize);
            let max_pts = buckets.len().min(MAX_ENVELOPE_PTS_PER_CHANNEL / 2);
            let mut pt_count: u32 = 0;

            for &(ts, lo, hi, _count) in buckets.iter().take(max_pts) {
                let idx = (byte_offset as usize) + (pt_count as usize) * 2;
                if idx + 1 < envelope.data.len() {
                    // Write min point
                    envelope.data[idx] = ts;
                    envelope.data[idx + 1] = lo;
                    pt_count += 1;
                }
                let idx = (byte_offset as usize) + (pt_count as usize) * 2;
                if idx + 1 < envelope.data.len() {
                    // Write max point
                    envelope.data[idx] = ts + 0.001; // Slight offset for visual separation
                    envelope.data[idx + 1] = hi;
                    pt_count += 1;
                }
            }

            envelope.channel_counts[i] = pt_count;
            byte_offset += pt_count * 2; // Each point = 2 f64s
        } else {
            envelope.channel_counts[i] = 0;
        }
    }

    envelope.num_channels = num_channels as u32;
    envelope.viewport_x_min = t_min;
    envelope.viewport_x_max = t_max;
    // Bump generation to even (signals "update complete" to readers)
    envelope.generation = envelope.generation.wrapping_add(1);
}

/// Envelope from AnalogSegment (10-level 16^n pyramid, f32).
///
/// `t_min`/`t_max` are ABSOLUTE coordinates (from ch.data's X axis).
/// `anchor` = ch.data.last.x (newest data point's X).
///
/// AnalogSegment uses push_count as its index (0-based, continuous), independent
/// of ch.data's X coordinate (which is sample-index in Demo, timestampMs in Real).
///
/// Mapping:
///   rel_min = t_min - anchor  (= _xMin, negative)
///   rel_max = t_max - anchor  (= _xMax, usually 0)
///   start_sample = (sample_count - 1) + rel_min
///   end_sample   = (sample_count - 1) + rel_max
/// Output X = absolute coords (t_min + frac * range), so Dart side can use
/// `xRel = envelopeX - newestAbsX` uniformly for both pyramid and analog paths.
fn update_render_envelope_from_analog(t_min: f64, t_max: f64, target_points: u32) {
    let analog_map = FFI_CH_ANALOG.read();
    let num_channels = analog_map.len().min(MAX_CHANNELS);
    if num_channels == 0 {
        return;
    }

    let anchor = f64::from_bits(VP_ANCHOR.load(Ordering::Acquire));
    let rel_min = t_min - anchor;
    let rel_max = t_max - anchor;
    let time_range = t_max - t_min;

    let mut envelope = RENDER_ENVELOPE.lock();

    // Bump generation to odd (signals "update in progress" to readers)
    envelope.generation = envelope.generation.wrapping_add(1);

    // Sort channel IDs for consistent ordering
    let mut channel_ids: Vec<u32> = analog_map.keys().copied().collect();
    channel_ids.sort_unstable();
    channel_ids.truncate(MAX_CHANNELS);

    if time_range <= 0.0 {
        envelope.generation = envelope.generation.wrapping_add(1);
        return;
    }

    let mut byte_offset: u32 = 0;

    for (i, &ch_id) in channel_ids.iter().enumerate() {
        envelope.channel_offsets[i] = byte_offset;

        if let Some(analog) = analog_map.get(&ch_id) {
            let sample_count = analog.sample_count();
            if sample_count == 0 {
                envelope.channel_counts[i] = 0;
                continue;
            }

            // Map relative viewport coords to absolute sample indices.
            let newest_sample = sample_count - 1;
            let start_sample = ((newest_sample as f64 + rel_min).round() as i64)
                .max(0)
                .min(sample_count as i64) as u64;
            let end_sample = ((newest_sample as f64 + rel_max).round() as i64)
                .max(start_sample as i64 + 1)
                .min(sample_count as i64) as u64;

            if start_sample >= end_sample {
                envelope.channel_counts[i] = 0;
                continue;
            }

            // Samples per pixel = how many source samples per screen pixel
            let spp = (end_sample - start_sample) as f32 / target_points as f32;

            let section = analog.get_envelope_section(start_sample, end_sample, spp);
            let n = section.length as usize;
            let max_pts = n.min(MAX_ENVELOPE_PTS_PER_CHANNEL / 2);
            let mut pt_count: u32 = 0;

            for (j, sample) in section.samples.iter().take(max_pts).enumerate() {
                // Map envelope sample to its actual sample position.
                // section.start + j * section.scale = absolute sample index in AnalogSegment.
                // Convert to absolute X coordinate: absX = anchor + (abs_sample - newest_sample)
                let abs_sample = section.start + (j as u64) * (section.scale as u64);
                let rel_x = abs_sample as f64 - newest_sample as f64;
                let x_abs = anchor + rel_x;

                let idx = (byte_offset as usize) + (pt_count as usize) * 2;
                if idx + 3 < envelope.data.len() {
                    // Write min point (f32 → f64)
                    envelope.data[idx] = x_abs;
                    envelope.data[idx + 1] = sample.min as f64;
                    // Write max point (slight x offset for visual pair)
                    envelope.data[idx + 2] = x_abs + 0.001;
                    envelope.data[idx + 3] = sample.max as f64;
                    pt_count += 2;
                }
            }

            envelope.channel_counts[i] = pt_count;
            byte_offset += pt_count * 2;
        } else {
            envelope.channel_counts[i] = 0;
        }
    }

    envelope.num_channels = num_channels as u32;
    envelope.viewport_x_min = t_min;
    envelope.viewport_x_max = t_max;
    // Bump generation to even (signals "update complete" to readers)
    envelope.generation = envelope.generation.wrapping_add(1);
}

// ── Pipeline main loop ─────────────────────────────────────────────

fn pipeline_loop() {
    log::info!("[Pipeline] Loop started");

    let sleep_duration = Duration::from_millis(16); // ~60Hz wake-up

    while PIPELINE_RUNNING.load(Ordering::Acquire) {
        // ── Step 1: Drain pending batches into pyramids ──
        // Only the pipeline thread touches FFI_CH_PYRAMIDS (producer writes to PENDING_BATCHES)
        let batches = drain_pending_batches();
        // Guard: Demo mode blocks console data from all Rust paths.
        // When PYRAMIDS_ACCEPT_CONSOLE is false, discard any residual batches
        // (e.g. from a mode switch where PENDING_BATCHES still has entries).
        if !batches.is_empty() && *PYRAMIDS_ACCEPT_CONSOLE.read() {
            let mut pyramids = FFI_CH_PYRAMIDS.lock();
            let analog_map = FFI_CH_ANALOG.read();
            for entry in batches {
                if let Some(ch_id) = entry.channel_id {
                    // Single-channel push with explicit channel_id
                    let pyramid = pyramids.entry(ch_id).or_default();
                    pyramid.push(entry.x, entry.values[0]);
                    // Also push to AnalogSegment (f32 precision)
                    if let Some(analog) = analog_map.get(&ch_id) {
                        analog.push_sample(entry.values[0] as f32);
                    }
                } else {
                    // Multi-channel push: channel_id = array index
                    for (ci, value) in entry.values.iter().enumerate() {
                        let channel_id = ci as u32;
                        let pyramid = pyramids.entry(channel_id).or_default();
                        pyramid.push(entry.x, *value);
                        // Also push to AnalogSegment (f32 precision)
                        if let Some(analog) = analog_map.get(&channel_id) {
                            analog.push_sample(*value as f32);
                        }
                    }
                }
            }
        }

        // ── Step 2: Update render envelope on viewport change or new data ──
        let vp_dirty = VP_DIRTY.swap(false, Ordering::AcqRel);
        let data_ready = DATA_READY.swap(false, Ordering::AcqRel);
        if vp_dirty || data_ready {
            let t_min = f64::from_bits(VP_T_MIN.load(Ordering::Acquire));
            let t_max = f64::from_bits(VP_T_MAX.load(Ordering::Acquire));
            let max_pts = VP_MAX_PTS.load(Ordering::Acquire) as u32;
            if t_max > t_min && max_pts > 0 {
                update_render_envelope(t_min, t_max, max_pts);
            }
        }

        thread::sleep(sleep_duration);
    }

    log::info!("[Pipeline] Loop stopped");
}

// ── Reset ──────────────────────────────────────────────────────────

/// Reset pipeline state (clear all pyramids, batches, counters, and envelope).
pub fn reset_pipeline() {
    GLOBAL_SAMPLE_IDX.store(0, Ordering::Release);
    // Discard any in-flight batches
    PENDING_BATCHES.lock().clear();
    FFI_CH_PYRAMIDS.lock().clear();
    // Reset all AnalogSegments and clear map
    let analog_map = FFI_CH_ANALOG.read();
    for seg in analog_map.values() {
        seg.reset();
    }
    drop(analog_map);
    FFI_CH_ANALOG.write().clear();
    // Reset viewport anchor
    VP_ANCHOR.store(0, Ordering::Release);
    let mut envelope = RENDER_ENVELOPE.lock();
    envelope.num_channels = 0;
    envelope.generation = 0;
    for i in 0..MAX_CHANNELS {
        envelope.channel_offsets[i] = 0;
        envelope.channel_counts[i] = 0;
    }
}
