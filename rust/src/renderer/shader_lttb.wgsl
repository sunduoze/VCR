// shader_lttb.wgsl — GPU-side LTTB decimation via compute shader
// Reduces 200K+ points → ~target points directly on GPU before rendering.
// Eliminates CPU→GPU bandwidth bottleneck.

struct LTTBParams {
    input_count: u32,   // total points in input buffer
    output_count: u32,  // target output points
    threshold: u32,     // if input < threshold, passthrough
};

@group(0) @binding(0) var<storage, read> input_data: array<vec2<f32>>;
@group(0) @binding(1) var<storage, read_write> output_data: array<vec2<f32>>;
@group(0) @binding(2) var<uniform> params: LTTBParams;

// Each workgroup processes one bucket
@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let bucket_idx = gid.x;
    let n = params.input_count;
    let m = params.output_count;

    // Passthrough: if input <= output, just copy
    if (n <= m) {
        if (bucket_idx < n) {
            output_data[bucket_idx] = input_data[bucket_idx];
        }
        return;
    }

    // LTTB: divide into m-2 buckets (first and last are preserved)
    if (bucket_idx >= m) {
        return;
    }

    // First point preserved
    if (bucket_idx == 0u) {
        output_data[0u] = input_data[0u];
        return;
    }

    // Last point preserved
    if (bucket_idx == m - 1u) {
        output_data[m - 1u] = input_data[n - 1u];
        return;
    }

    // Compute bucket boundaries for current position
    let bucket_size = f32(n - 1u) / f32(m - 1u);

    // Current bucket: boundaries
    let bucket_start = u32(f32(bucket_idx - 1u) * bucket_size) + 1u;
    let bucket_end = u32(f32(bucket_idx) * bucket_size) + 1u;
    let bucket_end_clamped = min(bucket_end, n);

    // Point being selected (average of current bucket)
    let avg_x = (f32(bucket_start) + f32(bucket_end_clamped - 1u)) * 0.5;
    let avg_idx = u32(avg_x);

    // Previous selected point (last point of previous bucket)
    let prev_idx = u32(f32(bucket_idx - 1u) * bucket_size);

    // Next bucket avg point
    let next_bucket_avg = u32((f32(bucket_idx + 1u) * bucket_size + f32(bucket_idx) * bucket_size) * 0.5);
    let next_idx = min(next_bucket_avg, n - 1u);

    // Find point in current bucket with max triangle area
    var max_area: f32 = -1.0;
    var max_idx: u32 = bucket_start;

    let a = input_data[prev_idx];
    let c = input_data[next_idx];

    for (var i = bucket_start; i < bucket_end_clamped; i++) {
        let b = input_data[i];

        // Triangle area = 0.5 * |(a.x - c.x)*(b.y - a.y) - (a.x - b.x)*(c.y - a.y)|
        let area = abs((a.x - c.x) * (b.y - a.y) - (a.x - b.x) * (c.y - a.y));

        if (area > max_area) {
            max_area = area;
            max_idx = i;
        }
    }

    output_data[bucket_idx] = input_data[max_idx];
}