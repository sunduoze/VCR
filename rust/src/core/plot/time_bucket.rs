// Time Bucket Pyramid — Phase 4: 4-level hierarchical time aggregation
//
// Layer structure:
//   Level 0: 1-second buckets  (raw/near-raw data)
//   Level 1: 10-second buckets (medium aggregation)
//   Level 2: 1-minute buckets  (coarse aggregation)
//   Level 3: 10-minute buckets (broad overview)
//
// Query algorithm:
//   1. Measure requested time range (x_max - x_min)
//   2. Select pyramid level where bucket count ≈ target_points
//   3. Query that level's buckets for min/max/count
//   4. Return aggregated data for rendering

use crate::core::plot::data_buffer::DataPoint;

/// Pre-computed bucket statistics for a time range
#[derive(Debug, Clone, Copy)]
pub struct BucketStats {
    /// Start of the bucket (timestamp_ms)
    pub timestamp_ms: f64,
    /// Minimum value in the bucket
    pub min_value: f64,
    /// Maximum value in the bucket
    pub max_value: f64,
    /// Average value in the bucket
    pub avg_value: f64,
    /// Number of raw data points in the bucket
    pub count: u32,
}

/// A single level of the time bucket pyramid
#[derive(Debug, Clone)]
pub struct TimeBucket {
    /// Bucket width in milliseconds (e.g., 1000.0 = 1 second)
    pub bucket_width_ms: f64,
    /// Aggregated bucket data
    buckets: Vec<BucketStats>,
    /// Max number of buckets to retain (infinite if 0)
    max_buckets: usize,
    /// Index of the next bucket to write (circular)
    write_idx: usize,
    /// Current number of valid buckets
    len: usize,
}

impl TimeBucket {
    /// Create a new time bucket level
    pub fn new(bucket_width_ms: f64, max_buckets: usize) -> Self {
        Self {
            bucket_width_ms,
            buckets: Vec::new(),
            max_buckets,
            write_idx: 0,
            len: 0,
        }
    }

    /// Get number of buckets
    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Get a bucket by index
    pub fn get(&self, idx: usize) -> Option<&BucketStats> {
        if idx >= self.len {
            return None;
        }
        if self.max_buckets > 0 && self.buckets.len() == self.max_buckets {
            // Circular buffer mode
            let actual_idx = (self.write_idx + idx) % self.max_buckets;
            Some(&self.buckets[actual_idx])
        } else {
            Some(&self.buckets[idx])
        }
    }

    /// Find the first bucket covering a timestamp
    pub fn find_bucket(&self, timestamp_ms: f64) -> Option<usize> {
        if self.is_empty() {
            return None;
        }
        let first_ts = self.get(0)?.timestamp_ms;
        let bucket_idx = ((timestamp_ms - first_ts) / self.bucket_width_ms).floor() as isize;
        if bucket_idx < 0 {
            Some(0)
        } else if bucket_idx as usize >= self.len {
            Some(self.len - 1)
        } else {
            Some(bucket_idx as usize)
        }
    }

    /// Query buckets in a time range [t_min, t_max]
    /// Returns a slice of bucket indices that cover the range
    pub fn query_range_indices(&self, t_min: f64, t_max: f64) -> (usize, usize) {
        if self.is_empty() {
            return (0, 0);
        }

        let first_ts = self.get(0).unwrap().timestamp_ms;
        let last_ts = first_ts + self.len as f64 * self.bucket_width_ms;

        if t_max < first_ts || t_min > last_ts {
            return (0, 0);
        }

        let start_idx = if t_min <= first_ts {
            0
        } else {
            ((t_min - first_ts) / self.bucket_width_ms).floor() as usize
        };

        let end_idx = if t_max >= last_ts {
            self.len
        } else {
            ((t_max - first_ts) / self.bucket_width_ms).ceil() as usize
        };

        (start_idx.min(self.len), end_idx.min(self.len))
    }

    /// Update a data point into the appropriate bucket
    pub fn update(&mut self, timestamp_ms: f64, value: f64) {
        if self.is_empty() {
            // First point: align to bucket boundary
            let aligned_ts = (timestamp_ms / self.bucket_width_ms).floor() * self.bucket_width_ms;
            self.buckets.push(BucketStats {
                timestamp_ms: aligned_ts,
                min_value: value,
                max_value: value,
                avg_value: value,
                count: 1,
            });
            self.write_idx = 0;
            self.len = 1;
            return;
        }

        let first_ts = self.get(0).unwrap().timestamp_ms;
        let bucket_offset = ((timestamp_ms - first_ts) / self.bucket_width_ms).floor();

        if bucket_offset < 0.0 {
            // Before first bucket: ignore or prepend
            return;
        }

        let bucket_idx = bucket_offset as usize;

        // Expand or wrap as needed
        if self.max_buckets > 0 {
            // Fixed size: circular buffer
            if bucket_idx >= self.max_buckets {
                // Wrapping: only keep the latest max_buckets
                return;
            }

            self.ensure_buckets_circular(bucket_idx + 1);

            let write_pos = (self.write_idx + bucket_idx) % self.max_buckets;
            let existing = &mut self.buckets[write_pos];

            if existing.count == 0 {
                // New bucket
                let aligned_ts = first_ts + bucket_idx as f64 * self.bucket_width_ms;
                *existing = BucketStats {
                    timestamp_ms: aligned_ts,
                    min_value: value,
                    max_value: value,
                    avg_value: value,
                    count: 1,
                };
            } else {
                // Update existing
                existing.min_value = existing.min_value.min(value);
                existing.max_value = existing.max_value.max(value);
                existing.avg_value = (existing.avg_value * existing.count as f64 + value) / (existing.count + 1) as f64;
                existing.count += 1;
            }
        } else {
            // Unlimited: grow vector
            while bucket_idx >= self.buckets.len() {
                let aligned_ts = first_ts + self.buckets.len() as f64 * self.bucket_width_ms;
                self.buckets.push(BucketStats {
                    timestamp_ms: aligned_ts,
                    min_value: f64::MAX,
                    max_value: f64::MIN,
                    avg_value: 0.0,
                    count: 0,
                });
            }

            let existing = &mut self.buckets[bucket_idx];
            if existing.count == 0 {
                existing.timestamp_ms = first_ts + bucket_idx as f64 * self.bucket_width_ms;
                existing.min_value = value;
                existing.max_value = value;
                existing.avg_value = value;
                existing.count = 1;
            } else {
                existing.min_value = existing.min_value.min(value);
                existing.max_value = existing.max_value.max(value);
                existing.avg_value = (existing.avg_value * existing.count as f64 + value) / (existing.count + 1) as f64;
                existing.count += 1;
            }
        }

        if bucket_idx + 1 > self.len {
            self.len = bucket_idx + 1;
        }
    }

    fn ensure_buckets_circular(&mut self, needed: usize) {
        while self.buckets.len() < needed.min(self.max_buckets) {
            self.buckets.push(BucketStats {
                timestamp_ms: 0.0,
                min_value: f64::MAX,
                max_value: f64::MIN,
                avg_value: 0.0,
                count: 0,
            });
        }
    }
}

/// Multi-level time bucket pyramid for hierarchical time aggregation
pub struct TimeBucketPyramid {
    /// 4 levels: [1s, 10s, 60s, 600s]
    levels: Vec<TimeBucket>,
}

impl TimeBucketPyramid {
    /// Pre-defined level bucket widths (milliseconds)
    pub const LEVEL_WIDTHS: [f64; 4] = [
        1_000.0,      // Level 0: 1 second
        10_000.0,     // Level 1: 10 seconds
        60_000.0,     // Level 2: 1 minute
        600_000.0,    // Level 3: 10 minutes
    ];

    /// Pre-defined max buckets per level
    pub const LEVEL_MAX_BUCKETS: [usize; 4] = [
        3600,   // Level 0: up to 1 hour of 1s data
        2160,   // Level 1: up to 6 hours of 10s data
        1440,   // Level 2: up to 24 hours of 1min data
        1008,   // Level 3: up to 7 days of 10min data
    ];

    pub fn new() -> Self {
        let levels: Vec<TimeBucket> = Self::LEVEL_WIDTHS
            .iter()
            .zip(Self::LEVEL_MAX_BUCKETS.iter())
            .map(|(&width, &max)| TimeBucket::new(width, max))
            .collect();

        Self { levels }
    }

    /// Push a new data point (updates all pyramid levels)
    pub fn push(&mut self, timestamp_ms: f64, value: f64) {
        for level in &mut self.levels {
            level.update(timestamp_ms, value);
        }
    }

    /// Push a batch of data points
    pub fn push_batch(&mut self, points: &[(f64, f64)]) {
        for &(ts, val) in points {
            self.push(ts, val);
        }
    }

    /// Select the best pyramid level for a time range query.
    ///
    /// Returns the level index where bucket count ≈ target_points.
    pub fn select_level(&self, t_range_ms: f64, target_points: usize) -> usize {
        for (i, level) in self.levels.iter().enumerate().rev() {
            let buckets_in_range = (t_range_ms / level.bucket_width_ms).ceil() as usize;
            if buckets_in_range <= target_points {
                return i;
            }
        }
        0 // Default to finest level
    }

    /// Query the pyramid for buckets in [t_min, t_max]
    ///
    /// Returns tuples of (bucket_start_ms, min, max, count) from the best level.
    pub fn query(
        &self,
        t_min: f64,
        t_max: f64,
        target_points: usize,
    ) -> Vec<(f64, f64, f64, u32)> {
        if t_min >= t_max {
            return vec![];
        }

        let t_range = t_max - t_min;
        let level_idx = self.select_level(t_range, target_points);
        let level = &self.levels[level_idx];

        let (start, end) = level.query_range_indices(t_min, t_max);

        let mut result = Vec::with_capacity(end - start);
        for i in start..end {
            if let Some(bucket) = level.get(i) {
                if bucket.count > 0 {
                    result.push((
                        bucket.timestamp_ms,
                        bucket.min_value,
                        bucket.max_value,
                        bucket.count,
                    ));
                }
            }
        }

        result
    }

    /// Query and convert to DataPoint pairs (min + max for each bucket)
    pub fn query_as_datapoints(
        &self,
        t_min: f64,
        t_max: f64,
        target_points: usize,
    ) -> Vec<DataPoint> {
        let buckets = self.query(t_min, t_max, target_points);
        let mut result = Vec::with_capacity(buckets.len() * 2);

        for (ts, min, max, _count) in buckets {
            result.push(DataPoint { timestamp_ms: ts, value: min });
            result.push(DataPoint { timestamp_ms: ts + 1.0, value: max });
        }

        result
    }

    /// Get a reference to a pyramid level
    pub fn level(&self, idx: usize) -> Option<&TimeBucket> {
        self.levels.get(idx)
    }

    /// Total buckets across all levels
    pub fn total_buckets(&self) -> usize {
        self.levels.iter().map(|l| l.len()).sum()
    }
}

impl Default for TimeBucketPyramid {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_time_bucket_single_point() {
        let mut bucket = TimeBucket::new(1000.0, 0);
        bucket.update(1500.0, 3.14);
        assert_eq!(bucket.len(), 1);
        let b = bucket.get(0).unwrap();
        assert!((b.timestamp_ms - 1000.0).abs() < 0.1); // aligned to 1s boundary
        assert_eq!(b.min_value, 3.14);
        assert_eq!(b.max_value, 3.14);
    }

    #[test]
    fn test_time_bucket_aggregation() {
        let mut bucket = TimeBucket::new(1000.0, 0);
        bucket.update(0.0, 1.0);
        bucket.update(500.0, 5.0);
        bucket.update(999.0, 3.0);
        assert_eq!(bucket.len(), 1);
        let b = bucket.get(0).unwrap();
        assert_eq!(b.min_value, 1.0);
        assert_eq!(b.max_value, 5.0);
        assert!(b.avg_value > 1.0 && b.avg_value < 5.0);
        assert_eq!(b.count, 3);
    }

    #[test]
    fn test_pyramid_push_and_query() {
        let mut pyramid = TimeBucketPyramid::new();

        // Push 3600 seconds of data at 10Hz (fills all pyramid levels)
        for i in 0..36000 {
            let ts = (i as f64) * 100.0; // 100ms per point
            let val = (ts * 0.001).sin();
            pyramid.push(ts, val);
        }

        // Query last 10 seconds (should return data from level 0)
        let result = pyramid.query(3_590_000.0, 3_600_000.0, 100);
        assert!(!result.is_empty(), "query() returned empty for range");

        // Query as datapoints
        let dps = pyramid.query_as_datapoints(0.0, 60000.0, 50);
        assert!(dps.len() > 0);
    }

    #[test]
    fn test_level_selection() {
        let pyramid = TimeBucketPyramid::new();

        // 1 second range → should use level 0 (1s buckets)
        let level = pyramid.select_level(1000.0, 100);
        assert_eq!(level, 3); // Level 3 has 10min buckets → 1 bucket for 1s range

        // Large range → coarse level
        let level = pyramid.select_level(3600_000.0, 100);
        assert_eq!(level, 3); // Level 3: 10min buckets → 6 buckets for 1hr
    }
}