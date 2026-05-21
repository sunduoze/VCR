// shader.wgsl - WGSL shader for waveform rendering

// Vertex shader - 绘制一个三角形（测试）
struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var output: VertexOutput;
    
    // 简单的三角形（屏幕中心，大小 0.5）
    var positions = array<vec2<f32>, 3>(
        vec2<f32>( 0.0,  0.5),  // 上
        vec2<f32>(-0.5, -0.5),  // 左下
        vec2<f32>( 0.5, -0.5),  // 右下
    );
    
    var pos = positions[vertex_index];
    output.position = vec4<f32>(pos.x, pos.y, 0.0, 1.0);
    output.color = vec4<f32>(1.0, 0.0, 0.0, 1.0);  // 红色
    
    return output;
}

// Fragment shader - 输出颜色
@fragment
fn fs_main(@location(0) color: vec4<f32>) -> @location(0) vec4<f32> {
    return color;
}
