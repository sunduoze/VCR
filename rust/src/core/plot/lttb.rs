// LTTB Decimation — Phase 4: Largest-Triangle-Three-Buckets downsampling
// Preserves visual shape while reducing millions of points to thousands.
// Reference: Sveinn Steinarsson, "Downsampling Time Series for Visual Representation"

use crate::core::plot::data_buffer::DataPoint;

/// Apply LTTB downsampling to a sorted slice of data points.
///
/// # Arguments
/// * `data` - input data slice, must be sorted by timestamp ascending
/// * `threshold` - target number of output points
///
/// # Returns
/// Downsampled vector with at most `threshold` points.
/// First and last points are always preserved.
///
/// # Complexity
/// O(n) time, O(threshold) space
pub fn lttb_downsample(data: &[DataPoint], threshold: usize) -> Vec<DataPoint> {
    if threshold <= 2 || data.len() <= threshold {
        return data.to_vec();
    }

    let data_length = data.len();
    let mut sampled = Vec::with_capacity(threshold);

    // Always include first point
    sampled.push(data[0]);

    let bucket_size = (data_length - 2) as f64 / (threshold - 2) as f64;
    let mut prev_idx = 0;

    for i in 0..(threshold - 2) {
        let avg_start = 1 + (i as f64 * bucket_size) as usize;
        let avg_end = 1 + ((i as f64 + 1.0) * bucket_size) as usize;
        let avg_end = avg_end.min(data_length - 1);

        if avg_start >= avg_end {
            continue;
        }

        // Average of next bucket (for triangle calculation)
        let next_avg_start = avg_end;
        let next_avg_end = 1 + ((i as f64 + 2.0) * bucket_size) as usize;
        let next_avg_end = next_avg_end.min(data_length);

        // Calculate average point in next bucket
        let mut avg_x = 0.0;
        let mut avg_y = 0.0;
        let mut count = 0usize;

        for j in next_avg_start..next_avg_end {
            avg_x += data[j].timestamp_ms;
            avg_y += data[j].value;
            count += 1;
        }

        if count == 0 {
            continue;
        }

        avg_x /= count as f64;
        avg_y /= count as f64;

        // Find point in current bucket with largest triangle area
        let mut max_area = -1.0f64;
        let mut max_idx = avg_start;

        let prev_point = &data[prev_idx];
        for j in avg_start..avg_end {
            let area = triangle_area(
                prev_point.timestamp_ms,
                prev_point.value,
                data[j].timestamp_ms,
                data[j].value,
                avg_x,
                avg_y,
            );
            if area > max_area {
                max_area = area;
                max_idx = j;
            }
        }

        sampled.push(data[max_idx]);
        prev_idx = max_idx;
    }

    // Always include last point
    sampled.push(data[data_length - 1]);

    sampled
}

/// Calculate triangle area using 3 points.
/// Area = 0.5 * |(x_a - x_c)*(y_b - y_a) - (x_a - x_b)*(y_c - y_a)|
#[inline]
fn triangle_area(x_a: f64, y_a: f64, x_b: f64, y_b: f64, x_c: f64, y_c: f64) -> f64 {
    ((x_a - x_c) * (y_b - y_a) - (x_a - x_b) * (y_c - y_a)).abs()
}

/// Simple min/max decimation (faster than LTTB, slightly lower visual quality).
/// Good for real-time rendering where speed matters more than perfect shape preservation.
pub fn minmax_downsample(data: &[DataPoint], threshold: usize) -> Vec<DataPoint> {
    if threshold <= 2 || data.len() <= threshold {
        return data.to_vec();
    }

    let bucket_size = data.len() as f64 / (threshold / 2) as f64;
    let mut result = Vec::with_capacity(threshold);

    result.push(data[0]);

    for i in 0..(threshold / 2) {
        let start = 1 + (i as f64 * bucket_size) as usize;
        let end = 1 + ((i as f64 + 1.0) * bucket_size) as usize;
        let end = end.min(data.len());

        if start >= end {
            continue;
        }

        let mut min_pt = data[start];
        let mut max_pt = data[start];

        for j in (start + 1)..end {
            if data[j].value < min_pt.value {
                min_pt = data[j];
            }
            if data[j].value > max_pt.value {
                max_pt = data[j];
            }
        }

        // Preserve time order
        if min_pt.timestamp_ms <= max_pt.timestamp_ms {
            result.push(min_pt);
            if min_pt.timestamp_ms != max_pt.timestamp_ms {
                result.push(max_pt);
            }
        } else {
            result.push(max_pt);
            result.push(min_pt);
        }
    }

    result.push(data[data.len() - 1]);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_point(t: f64, v: f64) -> DataPoint {
        DataPoint {
            timestamp_ms: t,
            value: v,
        }
    }

    #[test]
    fn test_lttb_smaller_than_threshold() {
        let data = vec![
            make_point(0.0, 1.0),
            make_point(1.0, 2.0),
            make_point(2.0, 3.0),
        ];
        let result = lttb_downsample(&data, 10);
        assert_eq!(result.len(), 3);
    }

    #[test]
    fn test_lttb_first_last_preserved() {
        let data: Vec<DataPoint> = (0..100)
            .map(|i| make_point(i as f64, (i as f64).sin()))
            .collect();
        let result = lttb_downsample(&data, 10);
        assert!(result.len() <= 10);
        assert_eq!(result[0].timestamp_ms, 0.0);
        assert_eq!(result.last().unwrap().timestamp_ms, 99.0);
    }

    #[test]
    fn test_lttb_flat_line() {
        let data: Vec<DataPoint> = (0..1000).map(|i| make_point(i as f64, 5.0)).collect();
        let result = lttb_downsample(&data, 50);
        assert!(result.len() <= 50);
        // Flat line: all values should be 5.0
        for pt in &result {
            assert_eq!(pt.value, 5.0);
        }
    }

    #[test]
    fn test_minmax_result_length() {
        let data: Vec<DataPoint> = (0..10000)
            .map(|i| make_point(i as f64, (i as f64).cos()))
            .collect();
        let result = minmax_downsample(&data, 100);
        // Minmax: up to 2*(threshold/2)+2 = threshold+2 points
        assert!(result.len() <= 110);
    }

    #[test]
    fn test_lttb_large_dataset() {
        // 100K points → 1K result
        let data: Vec<DataPoint> = (0..100000)
            .map(|i| make_point(i as f64, (i as f64 * 0.01).sin()))
            .collect();
        let result = lttb_downsample(&data, 1000);
        assert!(result.len() <= 1000);
        assert_eq!(result[0].timestamp_ms, 0.0);
        assert_eq!(result.last().unwrap().timestamp_ms, 99999.0);
    }
}
