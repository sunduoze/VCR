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
        // 🔧 Find first non-empty bucket (may be after logical index 0 in sliding window)
        let first_ts = (0..self.len)
            .find_map(|i| self.get(i))
            .filter(|b| b.count > 0)
            .map(|b| b.timestamp_ms)?;
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

        // 🔧 Find first non-empty bucket (after sliding window, logical index 0 may be empty)
        let first_bucket = (0..self.len).find_map(|i| self.get(i));
        let first_ts = match first_bucket {
            Some(b) if b.count > 0 => b.timestamp_ms,
            _ => return (0, 0), // All buckets empty
        };

        // Find last non-empty bucket for accurate time range
        let last_ts = (0..self.len)
            .rev()
            .find_map(|i| self.get(i))
            .filter(|b| b.count > 0)
            .map(|b| b.timestamp_ms + self.bucket_width_ms)
            .unwrap_or(first_ts + self.bucket_width_ms);

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

        // 🔧 After sliding window, logical index 0 may be empty. Find first non-empty.
        let first_bucket = match (0..self.len).find_map(|i| self.get(i)) {
            Some(b) if b.count > 0 => b,
            _ => {
                // All buckets empty (e.g. after full window slide): restart fresh
                self.buckets.clear();
                self.write_idx = 0;
                self.len = 0;
                let aligned_ts =
                    (timestamp_ms / self.bucket_width_ms).floor() * self.bucket_width_ms;
                self.buckets.push(BucketStats {
                    timestamp_ms: aligned_ts,
                    min_value: value,
                    max_value: value,
                    avg_value: value,
                    count: 1,
                });
                self.len = 1;
                return;
            }
        };
        let first_ts = first_bucket.timestamp_ms;
        let bucket_offset = ((timestamp_ms - first_ts) / self.bucket_width_ms).floor();

        if bucket_offset < 0.0 {
            // Before first bucket: ignore or prepend
            return;
        }

        let mut bucket_idx = bucket_offset as usize;

        // Expand or wrap: proper sliding window (not frozen after max_buckets)
        if self.max_buckets > 0 {
            // Fixed size: sliding window circular buffer
            if bucket_idx >= self.max_buckets {
                // 🔧 Slide window forward: drop oldest buckets, reuse slots for newest
                let overflow = bucket_idx - self.max_buckets + 1;
                let drop_count = overflow.min(self.max_buckets);
                // Clear the buckets being dropped (between old write_idx and new write_idx)
                for offset in 0..drop_count {
                    let pos = (self.write_idx + offset) % self.max_buckets;
                    self.buckets[pos] = BucketStats {
                        timestamp_ms: 0.0,
                        min_value: f64::MAX,
                        max_value: f64::MIN,
                        avg_value: 0.0,
                        count: 0,
                    };
                }
                self.write_idx = (self.write_idx + drop_count) % self.max_buckets;
                // Adjust bucket_idx to fit within the new window
                bucket_idx = self.max_buckets - 1;
            }

            self.ensure_buckets_circular(bucket_idx + 1);
            self.len = self.len.max(bucket_idx + 1).min(self.max_buckets);

            let write_pos = (self.write_idx + bucket_idx) % self.max_buckets;

            // 🔧 Compute aligned timestamp BEFORE taking mutable reference
            if self.buckets[write_pos].count == 0 {
                // Use absolute alignment (ts / bucket_width) to avoid stale first_ts
                // after sliding window resets the oldest buckets
                let aligned_ts =
                    (timestamp_ms / self.bucket_width_ms).floor() * self.bucket_width_ms;
                self.buckets[write_pos] = BucketStats {
                    timestamp_ms: aligned_ts,
                    min_value: value,
                    max_value: value,
                    avg_value: value,
                    count: 1,
                };
            } else {
                // Update existing
                let existing = &mut self.buckets[write_pos];
                existing.min_value = existing.min_value.min(value);
                existing.max_value = existing.max_value.max(value);
                existing.avg_value = (existing.avg_value * existing.count as f64 + value)
                    / (existing.count + 1) as f64;
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
                existing.avg_value = (existing.avg_value * existing.count as f64 + value)
                    / (existing.count + 1) as f64;
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
    // Bucket widths in data-native units (sample index for Demo, ms for Real @ 1000Hz).
    // Level 0 is finest (2 units/bucket ≈ 2 raw points), level 3 coarsest (250 units).
    // At 1000Hz, 2ms bucket holds ~2 raw data points.
    pub const LEVEL_WIDTHS: [f64; 4] = [
        2.0,    // Level 0: ~2 raw points per bucket (raw-level detail)
        10.0,   // Level 1: ~10 raw points per bucket
        50.0,   // Level 2: ~50 raw points per bucket
        250.0,  // Level 3: ~250 raw points per bucket
    ];

    /// Pre-defined max buckets per level
    pub const LEVEL_MAX_BUCKETS: [usize; 4] = [
        3600, // Level 0: up to 7200 data units
        2160, // Level 1: up to 21600 data units
        1440, // Level 2: up to 72000 data units
        1008, // Level 3: up to 252000 data units
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
    /// Select the best pyramid level for a time range query.
    ///
    /// Returns the level index where bucket count ≈ target_points AND data overlaps [t_min, t_max].
    pub fn select_level(&self, t_min: f64, t_max: f64, target_points: usize) -> usize {
        if t_min >= t_max {
            return self.levels.len() - 1;
        }
        let t_range = t_max - t_min;
        // Iterate finest→coarsest: pick the MOST detailed level that fits within target
        // AND has data that overlaps the query range (sliding window may have evicted old data).
        for (i, level) in self.levels.iter().enumerate() {
            let buckets_in_range = (t_range / level.bucket_width_ms).ceil() as usize;
            if buckets_in_range <= target_points {
                // Verify this level has data covering [t_min, t_max]
                let (start, end) = level.query_range_indices(t_min, t_max);
                if end > start {
                    return i;
                }
            }
        }
        self.levels.len() - 1 // Default to coarsest level (all levels exceed target or no data)
    }

    /// Query the pyramid for buckets in [t_min, t_max]
    ///
    /// Returns tuples of (bucket_start_ms, min, max, count) from the best available level.
    pub fn query(&self, t_min: f64, t_max: f64, target_points: usize) -> Vec<(f64, f64, f64, u32)> {
        if t_min >= t_max {
            return vec![];
        }

        // Try levels from finest→coarsest: use the first one that has data
        let start_level = self.select_level(t_min, t_max, target_points);
        for level_idx in start_level..self.levels.len() {
            let level = &self.levels[level_idx];
            let (start, end) = level.query_range_indices(t_min, t_max);

            let mut result = Vec::with_capacity(end.saturating_sub(start));
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

            if !result.is_empty() {
                return result;
            }
        }

        vec![]
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
            result.push(DataPoint {
                timestamp_ms: ts,
                value: min,
            });
            result.push(DataPoint {
                timestamp_ms: ts + 1.0,
                value: max,
            });
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

        // With new widths [2, 10, 50, 250], push data within pyramid's range.
        // Level 3 (250-unit buckets × 1008) covers 252000 units total.
        // Push 252000 units of data at 1 unit spacing.
        for i in 0..50000 {
            let ts = i as f64;
            let val = (ts * 0.001).sin();
            pyramid.push(ts, val);
        }

        // Query a visible viewport (1000 units) — should use fine level
        let result = pyramid.query(5000.0, 6000.0, 100);
        assert!(!result.is_empty(), "query() returned empty for 1000-unit range");

        // Query as datapoints on a larger range
        let dps = pyramid.query_as_datapoints(0.0, 500.0, 50);
        assert!(!dps.is_empty(), "query_as_datapoints returned empty");
    }

    #[test]
    fn test_level_selection() {
        let pyramid = TimeBucketPyramid::new();

        // 1000-unit range → level 1 (2-unit buckets would need 500 > 100 target; 10-unit = 100 fits)
        // No data yet, so select_level returns coarsest (level 3) since no level has data
        let level = pyramid.select_level(0.0, 1000.0, 100);
        assert_eq!(level, 3);

        // Very large range → all levels exceed target, fallback to coarsest (level 3)
        let level = pyramid.select_level(0.0, 3600_000.0, 100);
        assert_eq!(level, 3);
    }

    #[test]
    fn test_level_selection_small_range() {
        let mut pyramid = TimeBucketPyramid::new();
        // Push some data so pyramid is non-empty
        for i in 0..50 {
            pyramid.push(i as f64, (i as f64).sin());
        }
        // Small range (2 units) → fits in level 0 (1 bucket), data exists
        let level = pyramid.select_level(0.0, 2.0, 4000);
        assert_eq!(level, 0);
        // Medium range (1000 units) with large target → level 0 (500 buckets fits)
        let level = pyramid.select_level(0.0, 1000.0, 4000);
        assert_eq!(level, 0);
    }
}
