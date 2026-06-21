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
    /// 10 levels of envelope pyramid (Level 0~9)
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
            raw_buffer: Mutex::new(Vec::with_capacity(ENVELOPE_SCALE_FACTOR as usize)),
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
        while i < SCALE_STEP_COUNT - 1 {
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

    /// Read a range of raw samples [start, end) from storage.
    /// Returns None — raw sample storage is not yet implemented.
    /// Trace mode (samplesPerPixel < ENVELOPE_THRESHOLD) will use
    /// SegmentStorage once indexed chunk lookup is added.
    #[allow(dead_code)]
    fn read_raw_range(&self, _start: u64, _end: u64) -> Option<Vec<f32>> {
        None
    }

    /// Reset all state (clear pyramids, ring buffer, counters)
    pub fn reset(&self) {
        let mut levels = self.envelope_levels.write();
        for level in levels.iter_mut() {
            level.samples.clear();
            level.length = 0;
            level.capacity = 0;
        }
        self.raw_buffer.lock().clear();
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
        let seg = AnalogSegment::new(1000.0);
        seg.push_sample(3.0);
        seg.push_sample(7.0);
        seg.push_sample(2.0);
        assert_eq!(seg.sample_count(), 3);
        assert_eq!(seg.global_min(), 2.0);
        assert_eq!(seg.global_max(), 7.0);
    }

    #[test]
    fn test_level0_envelope_populated_at_16_samples() {
        let seg = AnalogSegment::new(1000.0);
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
        let seg = AnalogSegment::new(1000.0);
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
        let seg = AnalogSegment::new(1000.0);
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
        let seg = AnalogSegment::new(1000.0);
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
        let seg = AnalogSegment::new(1000.0);
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
        let seg = AnalogSegment::new(1000.0);
        let section = seg.get_envelope_section(0, 100, 10.0);
        assert_eq!(section.length, 0);
    }

    #[test]
    fn test_get_envelope_section_with_data() {
        let seg = AnalogSegment::new(1000.0);
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
        let seg = AnalogSegment::new(1000.0);
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
        let seg = AnalogSegment::new(1000.0);
        let data: Vec<f32> = (0..32).map(|i| i as f32).collect();
        seg.push_batch(&data);
        assert_eq!(seg.sample_count(), 32);
        let levels = seg.envelope_levels.read();
        assert_eq!(levels[0].length, 2);
    }
}
