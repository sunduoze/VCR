// Data Pipeline — Phase A: Background processing thread for lock-free data flow
//
// Architecture (reference framework aligned):
//   Serial receive → LockFreeRingBuffer → Pipeline thread → Per-channel pyramids
//                                                            ↓
//                                              RenderEnvelope (pre-computed)
//                                                            ↓
//                                          Dart Ticker → zero-copy read → CustomPainter
//
// Eliminates: Dart frb round-trip, per-frame pyramid Mutex, 50ms Timer jitter

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use parking_lot::Mutex;
use lazy_static::lazy_static;

use crate::core::plot::ffi_bridge::FFI_CH_PYRAMIDS;

// ── Global pipeline state ──────────────────────────────────────────

lazy_static! {
    /// Global sample counter — monotonically increasing, shared across all channels
    pub static ref GLOBAL_SAMPLE_IDX: AtomicU64 = AtomicU64::new(0);

    /// Pipeline worker thread handle
    static ref PIPELINE_HANDLE: Mutex<Option<JoinHandle<()>>> = Mutex::new(None);

    /// Pipeline running flag
    static ref PIPELINE_RUNNING: AtomicBool = AtomicBool::new(false);
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
#[repr(C)]
pub struct RenderEnvelope {
    /// Total number of active channels
    pub num_channels: u32,
    /// Byte offset of each channel's data in `data`
    pub channel_offsets: [u32; MAX_CHANNELS],
    /// Number of f64 pairs (x,y) for each channel
    pub channel_counts: [u32; MAX_CHANNELS],
    /// Interleaved f64 data: x0,y0, x1,y1, ...
    pub data: [f64; MAX_CHANNELS * MAX_ENVELOPE_PTS_PER_CHANNEL],
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
        data: [0f64; MAX_CHANNELS * MAX_ENVELOPE_PTS_PER_CHANNEL],
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

/// Push a batch of data directly into the pipeline.
/// Called from serial receive loop — eliminates Dart round-trip.
///
/// `channels`: slice of (channel_id, value) pairs for one sample instant.
pub fn push_sample(channel_id: u32, value: f64) {
    let x = GLOBAL_SAMPLE_IDX.fetch_add(1, Ordering::Relaxed) as f64;
    let mut pyramids = FFI_CH_PYRAMIDS.lock();
    let pyramid = pyramids.entry(channel_id).or_default();
    pyramid.push(x, value);
}

/// Push a multi-channel sample (one CSV line → multiple channels).
pub fn push_sample_batch(values: &[f64]) {
    let x = GLOBAL_SAMPLE_IDX.fetch_add(1, Ordering::Relaxed) as f64;
    let mut pyramids = FFI_CH_PYRAMIDS.lock();
    for (ci, &value) in values.iter().enumerate() {
        let channel_id = ci as u32;
        let pyramid = pyramids.entry(channel_id).or_default();
        pyramid.push(x, value);
    }
}

/// Push a multi-channel sample with explicit X value (syncs with PLOT_DATA counter).
/// Used from receive loop where PLOT_DATA.next_counter() is the canonical X.
pub fn push_sample_batch_with_x(x: f64, values: &[f64]) {
    let mut pyramids = FFI_CH_PYRAMIDS.lock();
    for (ci, &value) in values.iter().enumerate() {
        let channel_id = ci as u32;
        let pyramid = pyramids.entry(channel_id).or_default();
        pyramid.push(x, value);
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
    let pyramids = FFI_CH_PYRAMIDS.lock();
    let num_channels = pyramids.len().min(MAX_CHANNELS);
    if num_channels == 0 {
        return;
    }

    let mut envelope = RENDER_ENVELOPE.lock();

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
    envelope.generation = envelope.generation.wrapping_add(1);
}

// ── Pipeline main loop ─────────────────────────────────────────────

fn pipeline_loop() {
    log::info!("[Pipeline] Loop started");

    let sleep_duration = Duration::from_millis(16); // ~60Hz wake-up
    let mut last_sample_idx: u64 = 0;

    while PIPELINE_RUNNING.load(Ordering::Acquire) {
        let current_idx = GLOBAL_SAMPLE_IDX.load(Ordering::Relaxed);

        if current_idx != last_sample_idx {
            last_sample_idx = current_idx;
            // 🚀 Render envelope pre-computation (disabled by default — use pyramid query path for now)
            // Will be enabled in Phase B when Ticker replaces Timer.
            // update_render_envelope(t_min, t_max, 2000);
        }

        thread::sleep(sleep_duration);
    }

    log::info!("[Pipeline] Loop stopped");
}

// ── Reset ──────────────────────────────────────────────────────────

/// Reset pipeline state (clear all pyramids and counters).
pub fn reset_pipeline() {
    GLOBAL_SAMPLE_IDX.store(0, Ordering::Release);
    FFI_CH_PYRAMIDS.lock().clear();
    let mut envelope = RENDER_ENVELOPE.lock();
    envelope.num_channels = 0;
    envelope.generation = 0;
    for i in 0..MAX_CHANNELS {
        envelope.channel_offsets[i] = 0;
        envelope.channel_counts[i] = 0;
    }
}
