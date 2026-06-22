// AnalogSegment - 10-level envelope pyramid for hierarchical multi-resolution rendering
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

use parking_lot::{Mutex, RwLock};
use std::sync::atomic::AtomicU64;
use std::sync::Arc;

use super::constants::*;
use super::envelope::{EnvelopeLayer, EnvelopeSample, EnvelopeSection};
use super::segment::SegmentStorage;

/// Full analog segment: storage + multi-level envelope pyramid
pub struct AnalogSegment {
    /// Raw sample storage
    pub storage: Arc<SegmentStorage>,
    /// Number of envelope pyramid levels (3-10)
    pub level_count: usize,
    /// Envelope pyramid levels (Level 0 ~ level_count-1)
    pub envelope_levels: RwLock<Vec<EnvelopeLayer>>,
    /// Global minimum value (O(1) access for Y-axis auto-ranging)
    pub min_value: RwLock<f32>,
    /// Global maximum value
    pub max_value: RwLock<f32>,
    /// Total pushed sample count (for Demo mode x-axis)
    pub push_count: AtomicU64,
    /// Ring buffer of recent raw samples for envelope computation.
    /// Accumulates up to ENVELOPE_SCALE_FACTOR samples, then computes a
    /// Level 0 EnvelopeSample and clears. Avoids storing all raw data.
    raw_buffer: Mutex<Vec<f32>>,
    /// Full raw trace for trace-mode rendering (samplesPerPixel < ENVELOPE_THRESHOLD).
    /// Stores every pushed sample as f32 value. Read via read_trace().
    raw_trace: Mutex<Vec<f32>>,
    /// Sampling rate in Hz. Settable via set_samplerate().
    samplerate: RwLock<f64>,
}

impl AnalogSegment {
    /// Create a new AnalogSegment with pre-allocated envelope pyramid.
    /// `level_count` is clamped to [MIN_LEVEL_COUNT, MAX_LEVEL_COUNT] (3-10).
    pub fn new(samplerate: f64, level_count: usize) -> Arc<Self> {
        let count = level_count.clamp(MIN_LEVEL_COUNT, MAX_LEVEL_COUNT);
        let levels: Vec<EnvelopeLayer> = (0..count)
            .map(|_| EnvelopeLayer::new())
            .collect();

        Arc::new(Self {
            level_count: count,
            storage: Arc::new(SegmentStorage::new(samplerate)),
            envelope_levels: RwLock::new(levels),
            min_value: RwLock::new(f32::MAX),
            max_value: RwLock::new(f32::MIN),
            push_count: AtomicU64::new(0),
            raw_buffer: Mutex::new(Vec::with_capacity(ENVELOPE_SCALE_FACTOR as usize)),
            raw_trace: Mutex::new(Vec::new()),
            samplerate: RwLock::new(samplerate),
        })
    }

    /// Push a single data point (value only, x = push_count).
    /// This is the simplest API for Demo mode (single channel).
    pub fn push_sample(&self, value: f32) {
        self.push_count.fetch_add(1, std::sync::atomic::Ordering::Release);
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
        // Append to full raw trace for trace-mode rendering
        self.raw_trace.lock().push(value);
        // Accumulate in ring buffer; compute envelope when buffer is full
        self.try_compact_envelope(value);
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
        let level_f = ((samples_per_pixel as f64).ln() / LN_ENVELOPE_SCALE_FACTOR) - 1.0;
        let level = (level_f.floor() as i32).max(0) as usize;
        level.min(self.level_count.saturating_sub(1))
    }

    /// Get an envelope section for a sample range [start, end) at given samples_per_pixel.
    /// Returns EnvelopeSection with pre-computed min/max pairs for rendering.
    /// Get an envelope section for a sample range [start, end) at given samples_per_pixel.
    ///
    /// **Coverage-aware fallback**: starts at the ideal level from `select_level_for_spp`,
    /// then falls back to lower levels if coverage < 10% (e.g. data hasn't cascaded up yet).
    /// This prevents empty/gappy envelope when scrolling near the live edge or shortly
    /// after receiving new data.
    pub fn get_envelope_section(&self, start: u64, end: u64, samples_per_pixel: f32) -> EnvelopeSection {
        let empty_section = EnvelopeSection {
            start: 0,
            scale: 1,
            length: 0,
            samples: vec![],
        };

        let total = self.sample_count();
        let end = end.min(total);
        if start >= end {
            return empty_section;
        }

        let ideal_level = self.select_level_for_spp(samples_per_pixel);

        // Coverage-aware fallback loop: try ideal → 0
        for level in (0..=ideal_level).rev() {
            let scale_power = ((level + 1) * ENVELOPE_SCALE_POWER as usize) as u32;
            let scale = 1u64 << scale_power;

            let env_start = start >> scale_power;
            let env_end = ((end - 1) >> scale_power) + 1;
            let requested = env_end - env_start;

            let levels = self.envelope_levels.read();
            let layer = &levels[level];
            let actual_end = env_end.min(layer.length);
            if actual_end <= env_start {
                continue; // No data at this level → try lower
            }
            let length = actual_end - env_start;

            // Coverage: how much of the requested envelope range is filled?
            let coverage = if requested > 0 { length as f64 / requested as f64 } else { 0.0 };
            if coverage < 0.1 && level > 0 {
                continue; // < 10% coverage → likely not ready, try lower level
            }

            let samples = layer.samples[env_start as usize..actual_end as usize].to_vec();
            return EnvelopeSection {
                start: env_start << scale_power,
                scale: scale as u32,
                length,
                samples,
            };
        }

        empty_section
    }

    /// Get global min/max (O(1))
    pub fn global_min(&self) -> f32 {
        *self.min_value.read()
    }

    pub fn global_max(&self) -> f32 {
        *self.max_value.read()
    }

    /// Accumulate sample in ring buffer. When buffer reaches ENVELOPE_SCALE_FACTOR,
    /// compute one Level-0 EnvelopeSample (min/max of the batch), then cascade to
    /// higher levels iteratively (every 16 Level-i entries → 1 Level-(i+1) entry).
    fn try_compact_envelope(&self, value: f32) {
        let mut buf = self.raw_buffer.lock();
        buf.push(value);
        if buf.len() < ENVELOPE_SCALE_FACTOR as usize {
            return;
        }

        // Compute Level 0 envelope sample from the buffered raw samples
        let level0_sample = EnvelopeSample {
            min: buf.iter().cloned().fold(f32::MAX, f32::min),
            max: buf.iter().cloned().fold(f32::MIN, f32::max),
        };
        buf.clear();
        drop(buf);

        // Push to Level 0, then cascade up
        let mut levels = self.envelope_levels.write();
        let l0 = &mut levels[0];
        l0.reserve(l0.length + 1);
        l0.push(level0_sample);
        // NOTE: push() already increments l0.length

        // Cascade: every ENVELOPE_SCALE_FACTOR samples at Level i → 1 sample at Level i+1
        let mut i = 0;
        let max_cascade = self.level_count.saturating_sub(1);
        while i < max_cascade {
            if levels[i].length % ENVELOPE_SCALE_FACTOR as u64 != 0 {
                break;
            }
            let chunk_start = levels[i].length - ENVELOPE_SCALE_FACTOR as u64;
            let chunk = &levels[i].samples[chunk_start as usize..levels[i].length as usize];
            let aggregated = EnvelopeSample {
                min: chunk.iter().map(|s| s.min).fold(f32::MAX, f32::min),
                max: chunk.iter().map(|s| s.max).fold(f32::MIN, f32::max),
            };
            let upper = &mut levels[i + 1];
            upper.reserve(upper.length + 1);
            upper.push(aggregated);
            // NOTE: push() already increments upper.length
            i += 1;
        }
    }

    /// Read raw samples [start, end) for trace mode rendering.
    /// Returns empty vec if range is out of bounds.
    pub fn read_trace(&self, start: u64, end: u64) -> Vec<f32> {
        let trace = self.raw_trace.lock();
        let end = end.min(trace.len() as u64);
        if start >= end {
            return vec![];
        }
        trace[start as usize..end as usize].to_vec()
    }

    /// Set the sampling rate (Hz).
    pub fn set_samplerate(&self, rate: f64) {
        *self.samplerate.write() = rate;
    }

    /// Get the sampling rate (Hz).
    pub fn get_samplerate(&self) -> f64 {
        *self.samplerate.read()
    }

    /// Format full debug state as a human-readable string for diagnostic popup.
    pub fn dump_debug(&self) -> String {
        let mut s = String::with_capacity(2048);
        let total = self.push_count.load(std::sync::atomic::Ordering::Acquire);
        let min_val = *self.min_value.read();
        let max_val = *self.max_value.read();
        let sr = *self.samplerate.read();
        let levels = self.envelope_levels.read();
        let raw_trace_len = self.raw_trace.lock().len();
        let raw_buf_len = self.raw_buffer.lock().len();

        s.push_str(&format!("Samples: {total}\n"));
        s.push_str(&format!("Global min/max: {min_val:.6} / {max_val:.6}\n"));
        s.push_str(&format!("Samplerate: {sr} Hz\n"));
        s.push_str(&format!("Raw trace buffer: {raw_trace_len} values\n"));
        s.push_str(&format!("Raw ring buffer: {raw_buf_len}/16\n\n"));

        s.push_str(&format!("── Level 0-{} Pyramid ──\n", self.level_count.saturating_sub(1)));
        s.push_str("Lvl  Scale       Entries   Capacity   Coverage\n");
        s.push_str("───  ──────────  ────────  ────────   ────────\n");

        let mut scale: u64 = 16; // Level 0: 1 sample = 16 raw
        for (i, layer) in levels.iter().enumerate() {
            let count = layer.length as u64;
            let cap = layer.samples.len();
            // Coverage: what fraction of the total samples this level covers
            let coverage = if total > 0 {
                (count as f64 * scale as f64 / total as f64 * 100.0).min(100.0)
            } else {
                0.0
            };
            let scale_label = if scale >= 1_000_000_000 {
                format!("{:4.1}B", scale as f64 / 1e9)
            } else if scale >= 1_000_000 {
                format!("{:4.1}M", scale as f64 / 1e6)
            } else if scale >= 1000 {
                format!("{:4.1}K", scale as f64 / 1e3)
            } else {
                format!("{scale:5}")
            };
            s.push_str(&format!(
                " {i:2}   {scale_label:>10}  {count:>8}  {cap:>8}    {coverage:>5.1}%\n"
            ));
            scale = scale.saturating_mul(16);
        }

        // Suggest best level for current viewport
        if total > 0 {
            let viewport_samples = total.min(2000);
            let spp = viewport_samples as f64 / 2000.0;
            let selected = self.select_level_for_spp(spp as f32);
            let samp_per_pixel_raw = (total as f64 / 2000.0).max(1.0);
            s.push_str(&format!(
                "\nViewport (~2000px): spp_raw={samp_per_pixel_raw:.1} → Level {selected}\n"
            ));
        }

        s
    }

    /// Reset all state (clear pyramids, ring buffer, counters)
    pub fn reset(&self) {
        let mut levels = self.envelope_levels.write();
        for level in levels.iter_mut() {
            level.length = 0;
            level.samples.clear();
        }
        // If level_count changed (rare), ensure vec has correct length
        if levels.len() != self.level_count {
            *levels = (0..self.level_count).map(|_| EnvelopeLayer::new()).collect();
        }
        self.raw_buffer.lock().clear();
        self.raw_trace.lock().clear();
        *self.min_value.write() = f32::MAX;
        *self.max_value.write() = f32::MIN;
        self.push_count.store(0, std::sync::atomic::Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_push_sample_updates_count_and_minmax() {
        let seg = AnalogSegment::new(1000.0, 10);
        seg.push_sample(3.0);
        seg.push_sample(7.0);
        seg.push_sample(2.0);
        assert_eq!(seg.sample_count(), 3);
        assert_eq!(seg.global_min(), 2.0);
        assert_eq!(seg.global_max(), 7.0);
    }

    #[test]
    fn test_level0_envelope_populated_at_16_samples() {
        let seg = AnalogSegment::new(1000.0, 10);
        // Push exactly 16 samples
        for i in 0..16 {
            seg.push_sample(i as f32);
        }
        let levels = seg.envelope_levels.read();
        // Level 0 should have 1 entry (16 raw → 1 envelope sample)
        assert_eq!(levels[0].length, 1);
        let l0 = &levels[0];
        let s0 = l0.samples[0];
        assert_eq!(s0.min, 0.0);
        assert_eq!(s0.max, 15.0);
        // Higher levels should still be empty
        assert_eq!(levels[1].length, 0);
    }

    #[test]
    fn test_level0_multiple_batches() {
        let seg = AnalogSegment::new(1000.0, 10);
        // Push 32 samples → 2 Level-0 entries
        for i in 0..32 {
            seg.push_sample((i % 10) as f32);
        }
        let levels = seg.envelope_levels.read();
        assert_eq!(levels[0].length, 2);
        // 32 samples = count 32
        assert_eq!(seg.sample_count(), 32);
    }

    #[test]
    fn test_cascade_to_level1() {
        let seg = AnalogSegment::new(1000.0, 10);
        // Push 16 * 16 = 256 samples → 16 Level-0 → 1 Level-1
        for i in 0..256 {
            seg.push_sample((i % 50) as f32);
        }
        let levels = seg.envelope_levels.read();
        assert_eq!(levels[0].length, 16, "Level 0 should have 16 entries");
        assert_eq!(levels[1].length, 1, "Level 1 should have 1 entry (16 L0 → 1 L1)");
        assert_eq!(levels[2].length, 0, "Level 2 should be empty");
    }

    #[test]
    fn test_cascade_two_levels() {
        let seg = AnalogSegment::new(1000.0, 10);
        // Push 16 * 16 * 16 = 4096 samples → L0:16, L1:1, L2:0 (need 16 L1 for L2)
        // Actually for cascade to L2 we need 16*16=256 L0 + 16 more full cascades...
        // Push 16^2 * 16 = 256*16 = 4096 samples:
        //   L0: 16 per cascade, 4096/16 = 256 entries
        //   But wait, each time we get 16 entries at L0, we cascade 1 to L1.
        //   After 16 cascades (256 samples), L1 gets 1 entry.
        //   To get 16 L1 entries → L2 gets 1, we need 16*256 = 4096 samples.
        for i in 0..4096u64 {
            seg.push_sample((i % 100) as f32);
        }
        let levels = seg.envelope_levels.read();
        assert_eq!(levels[0].length, 256);
        assert_eq!(levels[1].length, 16);
        assert_eq!(levels[2].length, 1);
    }

    #[test]
    fn test_select_level_for_spp() {
        let seg = AnalogSegment::new(1000.0, 10);
        // spp < 16 → Level 0
        assert_eq!(seg.select_level_for_spp(10.0), 0);
        // 256 ≤ spp < 4096 → Level 1
        assert_eq!(seg.select_level_for_spp(300.0), 1);
        // ~1M → ln(1M)/ln(16)-1 = 3.98 → Level 3
        assert_eq!(seg.select_level_for_spp(1_000_000.0), 3);
        // ~1B → ln(1B)/ln(16)-1 = 6.47 → Level 6
        assert_eq!(seg.select_level_for_spp(1_000_000_000.0), 6);
    }

    #[test]
    fn test_get_envelope_section_empty() {
        let seg = AnalogSegment::new(1000.0, 10);
        let section = seg.get_envelope_section(0, 100, 10.0);
        assert_eq!(section.length, 0);
    }

    #[test]
    fn test_get_envelope_section_with_data() {
        let seg = AnalogSegment::new(1000.0, 10);
        // Push 32 samples → 2 Level-0 entries
        for i in 0..32 {
            seg.push_sample(i as f32);
        }
        // Query with spp < 16 → uses Level 0
        let section = seg.get_envelope_section(0, 32, 10.0);
        assert_eq!(section.length, 2, "Should get 2 envelope samples covering all 32 raw samples");
        assert_eq!(section.samples[0].min, 0.0);
        assert_eq!(section.samples[0].max, 15.0);
        assert_eq!(section.samples[1].min, 16.0);
        assert_eq!(section.samples[1].max, 31.0);
    }

    #[test]
    fn test_reset_clears_all() {
        let seg = AnalogSegment::new(1000.0, 10);
        for i in 0..32 {
            seg.push_sample(i as f32);
        }
        assert!(seg.sample_count() > 0);
        seg.reset();
        assert_eq!(seg.sample_count(), 0);
        assert_eq!(seg.global_min(), f32::MAX);
        assert_eq!(seg.global_max(), f32::MIN);
        let levels = seg.envelope_levels.read();
        assert_eq!(levels[0].length, 0);
    }

    #[test]
    fn test_push_batch() {
        let seg = AnalogSegment::new(1000.0, 10);
        let data: Vec<f32> = (0..32).map(|i| i as f32).collect();
        seg.push_batch(&data);
        assert_eq!(seg.sample_count(), 32);
        let levels = seg.envelope_levels.read();
        assert_eq!(levels[0].length, 2);
    }
}
