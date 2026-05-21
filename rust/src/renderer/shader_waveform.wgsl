// shader_waveform.wgsl - 波形渲染着色器

struct Uniforms {
    color: vec4<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct Vertex {
    @location(0) position: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
};

@vertex
fn vs_main(vert: Vertex) -> VertexOutput {
    var out: VertexOutput;
    // 将 [0,1] 范围变换到 NDC [-1,1]
    // Y 轴翻转（纹理坐标系 Y 向下，NDC Y 向上）
    let x = vert.position.x * 2.0 - 1.0;
    let y = (1.0 - vert.position.y) * 2.0 - 1.0;
    out.position = vec4<f32>(x, y, 0.0, 1.0);
    out.color = uniforms.color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return in.color;
}
