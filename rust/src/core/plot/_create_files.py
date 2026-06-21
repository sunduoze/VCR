import os

base = os.path.dirname(os.path.abspath(__file__))

files = {}

files['constants.rs'] = '''/// Scale power — each envelope level aggregates 2^4 = 16 samples
pub const ENVELOPE_SCALE_POWER: u32 = 4;
/// Per-level scale factor
pub const ENVELOPE_SCALE_FACTOR: u32 = 1 << 4; // 16
/// ln(16) ~ 2.772588722 — precomputed for level selection formula
pub const LN_ENVELOPE_SCALE_FACTOR: f64 = 2.772588722239781;
/// Envelope memory allocation alignment unit (64KB)
pub const ENVELOPE_DATA_UNIT: usize = 64 * 1024;
/// Number of envelope levels
pub const SCALE_STEP_COUNT: usize = 10;
/// Bytes per sample (f32)
pub const UNIT_SIZE: usize = std::mem::size_of::<f32>(); // 4
/// Raw data chunk storage size (1MB)
pub const MAX_CHUNK_SIZE: usize = 1 * 1024 * 1024;
/// Maximum number of channels (unchanged from existing)
pub const MAX_CHANNELS: usize = 64;
'''

files['envelope.rs'] = '''/// Single envelope sample: min/max pair (8 bytes total, f32)
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct EnvelopeSample {
    pub min: f32,
    pub max: f32,
}

/// A single level of the envelope pyramid
#[derive(Debug, Clone)]
pub struct EnvelopeLayer {
    /// Logical number of EnvelopeSamples in this layer
    pub length: u64,
    /// Allocated capacity (aligned to ENVELOPE_DATA_UNIT)
    pub capacity: u64,
    /// The actual envelope samples
    pub samples: Vec<EnvelopeSample>,
}

impl EnvelopeLayer {
    pub fn new() -> Self {
        Self {
            length: 0,
            capacity: 0,
            samples: Vec::new(),
        }
    }

    /// Reserve capacity aligned to ENVELOPE_DATA_UNIT
    pub fn reserve(&mut self, target_capacity: u64) {
        use super::constants::ENVELOPE_DATA_UNIT;
        let units = (target_capacity as usize).div_ceil(ENVELOPE_DATA_UNIT);
        let aligned = units * ENVELOPE_DATA_UNIT / std::mem::size_of::<EnvelopeSample>();
        if aligned > self.samples.capacity() {
            self.samples.reserve_exact(aligned - self.samples.len());
        }
        self.capacity = aligned as u64;
    }

    /// Push a single envelope sample
    pub fn push(&mut self, sample: EnvelopeSample) {
        self.samples.push(sample);
        self.length += 1;
    }

    /// Get total number of samples
    pub fn len(&self) -> u64 {
        self.length
    }

    pub fn is_empty(&self) -> bool {
        self.length == 0
    }
}

/// A section of envelope data for rendering
#[derive(Debug, Clone)]
pub struct EnvelopeSection {
    /// Start sample number (in original sample space)
    pub start: u64,
    /// Scale factor (1 envelope sample = scale original samples)
    pub scale: u32,
    /// Number of envelope samples in this section
    pub length: u64,
    /// The envelope samples
    pub samples: Vec<EnvelopeSample>,
}
'''

files['segment.rs'] = '''use parking_lot::RwLock;
use std::sync::atomic::AtomicU64;

/// Storage for raw sample data, split into chunks
pub struct SegmentStorage {
    /// Raw data chunks (each <= MAX_CHUNK_SIZE bytes)
    pub data_chunks: RwLock<Vec<Vec<u8>>>,
    /// Total number of samples (lock-free read)
    pub sample_count: AtomicU64,
    /// Bytes per sample (= 4 for f32)
    pub unit_size: u32,
    /// Start time (Unix timestamp or sample index)
    pub start_time: i64,
    /// Sampling rate in Hz
    pub samplerate: f64,
    /// Whether data collection is complete
    pub is_complete: RwLock<bool>,
}

impl SegmentStorage {
    /// Create new storage with given samplerate
    pub fn new(samplerate: f64) -> Self {
        Self {
            data_chunks: RwLock::new(Vec::new()),
            sample_count: AtomicU64::new(0),
            unit_size: std::mem::size_of::<f32>() as u32,
            start_time: 0,
            samplerate,
            is_complete: RwLock::new(false),
        }
    }

    /// Get the total number of samples (lock-free)
    pub fn sample_count(&self) -> u64 {
        self.sample_count.load(std::sync::atomic::Ordering::Acquire)
    }

    /// Append interleaved f32 samples (value per channel)
    /// Each channel gets its own sample; for multi-channel, values are stored sequentially.
    /// Returns the sample index of the first sample written.
    pub fn append_interleaved_samples(&self, data: &[f32], _channel_count: usize) -> u64 {
        use super::constants::MAX_CHUNK_SIZE;

        let sample_start = self.sample_count.fetch_add(1, std::sync::atomic::Ordering::Release);
        let byte_data: &[u8] = unsafe {
            std::slice::from_raw_parts(
                data.as_ptr() as *const u8,
                data.len() * std::mem::size_of::<f32>(),
            )
        };

        let mut chunks = self.data_chunks.write();
        if chunks.is_empty() || chunks.last().unwrap().len() + byte_data.len() > MAX_CHUNK_SIZE {
            chunks.push(Vec::with_capacity(MAX_CHUNK_SIZE));
        }
        chunks.last_mut().unwrap().extend_from_slice(byte_data);

        sample_start
    }

    /// Get min/max for a range of samples [start, end) for a specific channel
    /// Returns (min, max) or (0.0, 0.0) if range is invalid
    pub fn range_min_max(&self, _start: u64, _end: u64, _channel: usize, _total_channels: usize) -> (f32, f32) {
        // TODO: implement indexed range lookup from chunks
        // For now, placeholder
        (0.0, 0.0)
    }
}
'''

files['analog_segment.rs'] = '''// AnalogSegment - 10-level envelope pyramid for hierarchical multi-resolution rendering
//
// Reference: Scopy AnalogSegment design (ENVELOPE_SCALE_FACTOR=16, SCALE_STEP_COUNT=10)
//
// Architecture:
//   Level 0: 1 EnvelopeSample = 16 raw data points
//   Level 1: 1 EnvelopeSample = 256 raw data points
//   ...
//   Level 9: 1 EnvelopeSample = 16^10 ~ 1.1e12 raw data points
//
// Level selection: ln(samples_per_pixel) / ln(16) - 1

use parking_lot::RwLock;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;

use super::constants::*;
use super::envelope::{EnvelopeLayer, EnvelopeSample, EnvelopeSection};
use super::segment::SegmentStorage;

/// Full analog segment: storage + multi-level envelope pyramid
pub struct AnalogSegment {
    /// Raw sample storage
    pub storage: Arc<SegmentStorage>,
    /// 10 levels of envelope pyramid (Level 0~9)
    pub envelope_levels: RwLock<Vec<EnvelopeLayer>>,
    /// Global minimum value (O(1) access for Y-axis auto-ranging)
    pub min_value: RwLock<f32>,
    /// Global maximum value
    pub max_value: RwLock<f32>,
    /// Total pushed sample count (for Demo mode x-axis)
    pub push_count: AtomicU64,
}

impl AnalogSegment {
    /// Create a new AnalogSegment with pre-allocated 10-level envelope pyramid
    pub fn new(samplerate: f64) -> Arc<Self> {
        let levels: Vec<EnvelopeLayer> = (0..SCALE_STEP_COUNT)
            .map(|_| EnvelopeLayer::new())
            .collect();

        Arc::new(Self {
            storage: Arc::new(SegmentStorage::new(samplerate)),
            envelope_levels: RwLock::new(levels),
            min_value: RwLock::new(f32::MAX),
            max_value: RwLock::new(f32::MIN),
            push_count: AtomicU64::new(0),
        })
    }

    /// Push a single data point (value only, x = push_count).
    /// This is the simplest API for Demo mode (single channel).
    pub fn push_sample(&self, value: f32) {
        let idx = self.push_count.fetch_add(1, std::sync::atomic::Ordering::Release);
        // Update global min/max
        {
            let mut min = self.min_value.write();
            if value < *min {
                *min = value;
            }
        }
        {
            let mut max = self.max_value.write();
            if value > *max {
                *max = value;
            }
        }
        // Update envelope levels incrementally
        self.update_envelope_levels(idx, value);
    }

    /// Push a batch of data points for a channel.
    pub fn push_batch(&self, data: &[f32]) {
        for &value in data {
            self.push_sample(value);
        }
    }

    /// Get the total number of samples pushed
    pub fn sample_count(&self) -> u64 {
        self.push_count.load(std::sync::atomic::Ordering::Acquire)
    }

    /// Select the best envelope level for given samples_per_pixel.
    /// Uses the mathematical formula: level = floor(ln(spp) / ln(16) - 1)
    pub fn select_level_for_spp(&self, samples_per_pixel: f32) -> usize {
        if samples_per_pixel < ENVELOPE_SCALE_FACTOR as f32 {
            return 0; // Less than 16 samples per pixel -> use raw/Level 0
        }
        let level_f = (samples_per_pixel.ln() / LN_ENVELOPE_SCALE_FACTOR) - 1.0;
        let level = (level_f.floor() as i32).max(0) as usize;
        level.min(SCALE_STEP_COUNT - 1)
    }

    /// Get an envelope section for a sample range [start, end) at given samples_per_pixel.
    /// Returns EnvelopeSection with pre-computed min/max pairs for rendering.
    pub fn get_envelope_section(&self, start: u64, end: u64, samples_per_pixel: f32) -> EnvelopeSection {
        let total = self.sample_count();
        let end = end.min(total);
        if start >= end {
            return EnvelopeSection {
                start: 0,
                scale: 1,
                length: 0,
                samples: vec![],
            };
        }

        let level = self.select_level_for_spp(samples_per_pixel);

        // Scale: 1 envelope sample at this level = scale original samples
        let scale_power = ((level + 1) * ENVELOPE_SCALE_POWER as usize) as u32;
        let scale = 1u64 << scale_power;

        let env_start = start >> scale_power;
        let env_end = ((end - 1) >> scale_power) + 1;

        let levels = self.envelope_levels.read();
        let layer = &levels[level];
        let actual_end = env_end.min(layer.length);
        let length = actual_end.saturating_sub(env_start);

        let samples = if length > 0 {
            layer.samples[env_start as usize..(env_start + length) as usize].to_vec()
        } else {
            vec![]
        };

        EnvelopeSection {
            start: env_start << scale_power,
            scale: scale as u32,
            length: samples.len() as u64,
            samples,
        }
    }

    /// Get global min/max (O(1))
    pub fn global_min(&self) -> f32 {
        *self.min_value.read()
    }

    pub fn global_max(&self) -> f32 {
        *self.max_value.read()
    }

    /// Update envelope levels incrementally after pushing a new sample.
    fn update_envelope_levels(&self, sample_idx: u64, value: f32) {
        let mut levels = self.envelope_levels.write();

        // Level 0: every 16 samples -> 1 EnvelopeSample
        if sample_idx > 0 && (sample_idx + 1) % ENVELOPE_SCALE_FACTOR as u64 == 0 {
            let start = sample_idx + 1 - ENVELOPE_SCALE_FACTOR as u64;
            let end = sample_idx + 1;

            // Aggregate the last 16 values into one envelope sample
            if let Some(raw) = self.read_raw_range(start, end) {
                let s = EnvelopeSample {
                    min: raw.iter().cloned().fold(f32::MAX, f32::min),
                    max: raw.iter().cloned().fold(f32::MIN, f32::max),
                };
                let l0 = &mut levels[0];
                l0.reserve(l0.length + 1);
                l0.push(s);

                // Cascade to higher levels
                let mut i = 0;
                while i < SCALE_STEP_COUNT - 1 && levels[i].length % ENVELOPE_SCALE_FACTOR as u64 == 0 {
                    let chunk_start = levels[i].length - ENVELOPE_SCALE_FACTOR as u64;
                    let chunk: Vec<EnvelopeSample> = levels[i].samples
                        [chunk_start as usize..levels[i].length as usize]
                        .to_vec();
                    let aggregated = EnvelopeSample {
                        min: chunk.iter().map(|s| s.min).fold(f32::MAX, f32::min),
                        max: chunk.iter().map(|s| s.max).fold(f32::MIN, f32::max),
                    };
                    let upper = &mut levels[i + 1];
                    upper.reserve(upper.length + 1);
                    upper.push(aggregated);
                    i += 1;
                }
            }
        }
    }

    /// Read a range of raw samples [start, end) from storage.
    /// Returns None if the range is not fully available.
    fn read_raw_range(&self, _start: u64, _end: u64) -> Option<Vec<f32>> {
        // For Demo mode without SegmentStorage, return a simple approximation.
        // In production, this reads from self.storage.data_chunks.
        // Placeholder: we don't store raw samples yet in this implementation.
        None
    }

    /// Reset all state (clear pyramids, reset counters)
    pub fn reset(&self) {
        let mut levels = self.envelope_levels.write();
        for level in levels.iter_mut() {
            level.samples.clear();
            level.length = 0;
            level.capacity = 0;
        }
        *self.min_value.write() = f32::MAX;
        *self.max_value.write() = f32::MIN;
        self.push_count.store(0, std::sync::atomic::Ordering::Release);
    }
}
'''

for name, content in files.items():
    path = os.path.join(base, name)
    with open(path, 'w', encoding='utf-8-sig', newline='\r\n') as f:
        f.write(content)
    print(f'Created {path}')

print('All files created successfully.')
