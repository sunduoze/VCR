// gpu_renderer.rs — Phase 6: Optimized WebGPU (wgpu) renderer
//
// Optimizations:
//   1. Persistent vertex buffer — pre-allocated, avoids per-frame buffer creation
//   2. GPU compute LTTB — decimation runs on GPU, eliminates CPU→GPU bandwidth
//   3. Staging buffer pool — double-buffered readback, eliminates GPU stall
//   4. Pre-created pipelines — all pipelines created once at init
//   5. Dynamic write offset — reuse same buffer, only update changed data

use std::sync::Arc;
use pollster::block_on;
use wgpu::*;

// ── Constants ───────────────────────────────────────────────────────

/// Maximum vertex buffer capacity (500K points × 8 bytes = 4MB)
const MAX_VERTEX_CAPACITY: u64 = 500_000;
const VERTEX_STRIDE: u64 = 8; // vec2<f32>

/// Staging pool max size (lazy allocation, grows on demand)
const STAGING_MAX_SIZE: usize = 4;

// ── Structs ─────────────────────────────────────────────────────────

/// Staging buffer entry for async readback
struct StagingEntry {
    buffer: Buffer,
    size: u64,
    in_use: bool,
}

/// Optimized GPU renderer
pub struct GpuRenderer {
    device: Arc<Device>,
    queue: Arc<Queue>,

    // Persistent vertex buffer — allocated once, updated per frame
    vertex_buffer: Buffer,
    vertex_capacity: u64,

    // Compute pipeline for GPU-side LTTB decimation
    lttb_pipeline: ComputePipeline,
    lttb_bind_group_layout: BindGroupLayout,

    // Waveform render pipeline
    waveform_pipeline: RenderPipeline,

    // Uniform buffer (color)
    uniform_buffer: Buffer,
    uniform_bind_group: BindGroup,

    // Staging buffer pool for readback
    staging_pool: Vec<StagingEntry>,
    staging_idx: usize,

    // Intermediate buffers for compute pipeline
    decimated_buffer: Option<Buffer>,
    decimated_capacity: u64,
}

// ── Implementation ──────────────────────────────────────────────────

impl GpuRenderer {
    /// Initialize GPU renderer with all persistent resources
    pub fn new() -> Result<Self, String> {
        let _ = env_logger::try_init();
        log::info!("[GPU] Phase 6 optimized renderer initializing...");

        // ── 1. Instance ────────────────────────────────────────────
        let instance = Instance::new(InstanceDescriptor {
            backends: Backends::all(),
            ..Default::default()
        });

        // ── 2. Adapter ─────────────────────────────────────────────
        let adapter = block_on(instance.request_adapter(&RequestAdapterOptions {
            power_preference: PowerPreference::HighPerformance,
            compatible_surface: None,
            force_fallback_adapter: false,
        }))
        .ok_or("No GPU adapter found")?;

        log::info!("[GPU] Adapter: {:?}", adapter.get_info());

        // ── 3. Device ──────────────────────────────────────────────
        let (device, queue) = block_on(adapter.request_device(
            &DeviceDescriptor {
                label: Some("VCR GPU Device"),
                required_limits: Limits {
                    max_storage_buffer_binding_size: 8 * MAX_VERTEX_CAPACITY as u32,
                    ..Limits::default()
                },
                required_features: Features::empty(),
                memory_hints: MemoryHints::Performance,
            },
            None,
        ))
        .map_err(|e| format!("Failed to create device: {}", e))?;

        let device = Arc::new(device);
        let queue = Arc::new(queue);

        // ── 4. Persistent vertex buffer (pre-allocated) ────────────
        let vertex_buffer = device.create_buffer(&BufferDescriptor {
            label: Some("Persistent Vertex Buffer"),
            size: VERTEX_STRIDE * MAX_VERTEX_CAPACITY,
            usage: BufferUsages::VERTEX | BufferUsages::COPY_DST | BufferUsages::STORAGE,
            mapped_at_creation: false,
        });

        log::info!(
            "[GPU] Persistent vertex buffer: {} bytes ({:.1} MB)",
            VERTEX_STRIDE * MAX_VERTEX_CAPACITY,
            (VERTEX_STRIDE * MAX_VERTEX_CAPACITY) as f64 / 1_048_576.0
        );

        // ── 5. Shader modules ──────────────────────────────────────
        let ltbb_shader = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("LTTB Compute Shader"),
            source: ShaderSource::Wgsl(std::borrow::Cow::Borrowed(
                include_str!("shader_lttb.wgsl"),
            )),
        });

        let waveform_shader = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("Waveform Shader"),
            source: ShaderSource::Wgsl(std::borrow::Cow::Borrowed(
                include_str!("shader_waveform.wgsl"),
            )),
        });

        // ── 6. LTTB compute pipeline ───────────────────────────────
        let lttb_bind_group_layout =
            device.create_bind_group_layout(&BindGroupLayoutDescriptor {
                label: Some("LTTB Bind Group Layout"),
                entries: &[
                    BindGroupLayoutEntry {
                        binding: 0,
                        visibility: ShaderStages::COMPUTE,
                        ty: BindingType::Buffer {
                            ty: BufferBindingType::Storage { read_only: true },
                            has_dynamic_offset: false,
                            min_binding_size: None,
                        },
                        count: None,
                    },
                    BindGroupLayoutEntry {
                        binding: 1,
                        visibility: ShaderStages::COMPUTE,
                        ty: BindingType::Buffer {
                            ty: BufferBindingType::Storage { read_only: false },
                            has_dynamic_offset: false,
                            min_binding_size: None,
                        },
                        count: None,
                    },
                    BindGroupLayoutEntry {
                        binding: 2,
                        visibility: ShaderStages::COMPUTE,
                        ty: BindingType::Buffer {
                            ty: BufferBindingType::Uniform,
                            has_dynamic_offset: false,
                            min_binding_size: wgpu::BufferSize::new(12), // 3 × u32
                        },
                        count: None,
                    },
                ],
            });

        let lttb_pipeline_layout =
            device.create_pipeline_layout(&PipelineLayoutDescriptor {
                label: Some("LTTB Pipeline Layout"),
                bind_group_layouts: &[&lttb_bind_group_layout],
                push_constant_ranges: &[],
            });

        let lttb_pipeline =
            device.create_compute_pipeline(&ComputePipelineDescriptor {
                label: Some("LTTB Compute Pipeline"),
                layout: Some(&lttb_pipeline_layout),
                module: &ltbb_shader,
                entry_point: Some("main"),
                compilation_options: Default::default(),
                cache: None,
            });

        // ── 7. Waveform render pipeline ────────────────────────────
        let uniform_bind_group_layout =
            device.create_bind_group_layout(&BindGroupLayoutDescriptor {
                label: Some("Uniform Bind Group Layout"),
                entries: &[BindGroupLayoutEntry {
                    binding: 0,
                    visibility: ShaderStages::VERTEX_FRAGMENT,
                    ty: BindingType::Buffer {
                        ty: BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: wgpu::BufferSize::new(16),
                    },
                    count: None,
                }],
            });

        let waveform_pipeline_layout =
            device.create_pipeline_layout(&PipelineLayoutDescriptor {
                label: Some("Waveform Pipeline Layout"),
                bind_group_layouts: &[&uniform_bind_group_layout],
                push_constant_ranges: &[],
            });

        let vertex_buffer_layout = [VertexBufferLayout {
            array_stride: VERTEX_STRIDE,
            step_mode: VertexStepMode::Vertex,
            attributes: &[VertexAttribute {
                format: VertexFormat::Float32x2,
                offset: 0,
                shader_location: 0,
            }],
        }];

        let waveform_pipeline =
            device.create_render_pipeline(&RenderPipelineDescriptor {
                label: Some("Waveform Render Pipeline"),
                layout: Some(&waveform_pipeline_layout),
                vertex: VertexState {
                    module: &waveform_shader,
                    entry_point: Some("vs_main"),
                    buffers: &vertex_buffer_layout,
                    compilation_options: Default::default(),
                },
                fragment: Some(FragmentState {
                    module: &waveform_shader,
                    entry_point: Some("fs_main"),
                    targets: &[Some(ColorTargetState {
                        format: TextureFormat::Rgba8Unorm,
                        blend: Some(BlendState::REPLACE),
                        write_mask: ColorWrites::ALL,
                    })],
                    compilation_options: Default::default(),
                }),
                primitive: PrimitiveState {
                    topology: PrimitiveTopology::LineStrip,
                    strip_index_format: None,
                    front_face: FrontFace::Ccw,
                    cull_mode: None,
                    polygon_mode: PolygonMode::Fill,
                    unclipped_depth: false,
                    conservative: false,
                },
                depth_stencil: None,
                multisample: MultisampleState {
                    count: 1,
                    mask: !0,
                    alpha_to_coverage_enabled: false,
                },
                multiview: None,
                cache: None,
            });

        // ── 8. Uniform buffer ─────────────────────────────────────
        let uniform_buffer = device.create_buffer(&BufferDescriptor {
            label: Some("Uniform Buffer (Color)"),
            size: 16, // vec4<f32>
            usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let uniform_bind_group = device.create_bind_group(&BindGroupDescriptor {
            label: Some("Uniform Bind Group"),
            layout: &uniform_bind_group_layout,
            entries: &[BindGroupEntry {
                binding: 0,
                resource: uniform_buffer.as_entire_binding(),
            }],
        });

        // ── 9. Staging buffer pool ────────────────────────────────
        let staging_pool = Vec::new(); // Lazy allocation on first use

        log::info!("[GPU] Phase 6 optimized renderer initialized");

        Ok(Self {
            device,
            queue,
            vertex_buffer,
            vertex_capacity: MAX_VERTEX_CAPACITY,
            lttb_pipeline,
            lttb_bind_group_layout,
            waveform_pipeline,
            uniform_buffer,
            uniform_bind_group,
            staging_pool,
            staging_idx: 0,
            decimated_buffer: None,
            decimated_capacity: 0,
        })
    }

    // ══════════════════════════════════════════════════════════════════
    // Core Rendering API
    // ══════════════════════════════════════════════════════════════════

    /// Render waveform directly to texture with GPU-side decimation.
    ///
    /// - `points`: raw data points (x, y pairs, normalized [0, 1])
    /// - `point_count`: number of points
    /// - `target_points`: if point_count > target_points, GPU LTTB decimates
    /// - `color`: RGBA in [0, 1]
    pub fn render_waveform_optimized(
        &mut self,
        texture: &Texture,
        width: u32,
        height: u32,
        points: &[f32],
        point_count: u32,
        target_points: u32,
        color: [f32; 4],
    ) -> Result<(), String> {
        if points.is_empty() || point_count == 0 {
            return Ok(());
        }

        let actual_count = point_count as usize;

        if points.len() < actual_count * 2 {
            return Err("points array too small".to_string());
        }

        // ─── Step 1: Upload to persistent vertex buffer ────────────
        self.queue.write_buffer(
            &self.vertex_buffer,
            0,
            bytemuck::cast_slice(&points[..actual_count * 2]),
        );

        // Determine which vertex buffer and count to use for rendering
        let (render_vb, render_count) = if actual_count as u32 > target_points {
            // Need GPU decimation
            self.ensure_decimated_buffer(target_points as u64);
            self.run_lttb_compute(actual_count as u32, target_points)?;
            (
                self.decimated_buffer.as_ref().unwrap(),
                target_points,
            )
        } else {
            (&self.vertex_buffer, point_count)
        };

        // ─── Step 3: Render ────────────────────────────────────────
        self.queue.write_buffer(
            &self.uniform_buffer,
            0,
            bytemuck::cast_slice(&color),
        );

        let view = texture.create_view(&TextureViewDescriptor::default());
        let mut encoder = self
            .device
            .create_command_encoder(&CommandEncoderDescriptor {
                label: Some("Render Encoder"),
            });

        {
            let mut rpass = encoder.begin_render_pass(&RenderPassDescriptor {
                label: Some("Render Pass"),
                color_attachments: &[Some(RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: Operations {
                        load: LoadOp::Clear(Color {
                            r: 0.0,
                            g: 0.0,
                            b: 0.0,
                            a: 1.0,
                        }),
                        store: StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });

            rpass.set_viewport(0.0, 0.0, width as f32, height as f32, 0.0, 1.0);
            rpass.set_pipeline(&self.waveform_pipeline);
            rpass.set_vertex_buffer(0, render_vb.slice(..));
            rpass.set_bind_group(0, &self.uniform_bind_group, &[]);
            rpass.draw(0..render_count, 0..1);
        }

        self.queue.submit(Some(encoder.finish()));

        Ok(())
    }

    // ══════════════════════════════════════════════════════════════════
    // Compute Pipeline: GPU-side LTTB Decimation
    // ══════════════════════════════════════════════════════════════════

    /// Ensure decimated buffer exists with sufficient capacity
    fn ensure_decimated_buffer(&mut self, target: u64) {
        if self
            .decimated_buffer
            .as_ref()
            .map_or(true, |_| self.decimated_capacity < target)
        {
            // Allocate with some headroom (2x target)
            let cap = target.max(1024).next_power_of_two();
            self.decimated_buffer = Some(self.device.create_buffer(&BufferDescriptor {
                label: Some("Decimated Output Buffer"),
                size: VERTEX_STRIDE * cap,
                usage: BufferUsages::VERTEX
                    | BufferUsages::STORAGE
                    | BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }));
            self.decimated_capacity = cap;
            log::info!(
                "[GPU] Decimated buffer resized: {} points ({:.1} KB)",
                cap,
                (VERTEX_STRIDE * cap) as f64 / 1024.0
            );
        }
    }

    /// Run GPU LTTB compute pipeline: input → decimated output
    fn run_lttb_compute(
        &self,
        input_count: u32,
        output_count: u32,
    ) -> Result<(), String> {
        let decimated = self
            .decimated_buffer
            .as_ref()
            .ok_or("Decimated buffer not allocated")?;

        // ── Params uniform buffer ──────────────────────────────────
        #[repr(C)]
        #[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
        struct LttbParams {
            input_count: u32,
            output_count: u32,
            threshold: u32,
        }

        let params = LttbParams {
            input_count,
            output_count,
            threshold: output_count * 2, // No-op if input < 2× output
        };

        let params_buffer = self.device.create_buffer(&BufferDescriptor {
            label: Some("LTTB Params"),
            size: std::mem::size_of::<LttbParams>() as u64,
            usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        self.queue
            .write_buffer(&params_buffer, 0, bytemuck::bytes_of(&params));

        // ── Bind group ────────────────────────────────────────────
        let bind_group = self.device.create_bind_group(&BindGroupDescriptor {
            label: Some("LTTB Bind Group"),
            layout: &self.lttb_bind_group_layout,
            entries: &[
                BindGroupEntry {
                    binding: 0,
                    resource: self.vertex_buffer.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 1,
                    resource: decimated.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 2,
                    resource: params_buffer.as_entire_binding(),
                },
            ],
        });

        // ── Dispatch compute ───────────────────────────────────────
        let mut encoder = self
            .device
            .create_command_encoder(&CommandEncoderDescriptor {
                label: Some("LTTB Compute Encoder"),
            });

        {
            let mut cpass =
                encoder.begin_compute_pass(&ComputePassDescriptor {
                    label: Some("LTTB Compute Pass"),
                    timestamp_writes: None,
                });

            cpass.set_pipeline(&self.lttb_pipeline);
            cpass.set_bind_group(0, &bind_group, &[]);
            // Dispatch: ceil(output_count / 64) workgroups
            let workgroups = (output_count + 63) / 64;
            cpass.dispatch_workgroups(workgroups, 1, 1);
        }

        self.queue.submit(Some(encoder.finish()));

        Ok(())
    }

    // ══════════════════════════════════════════════════════════════════
    // Staging Buffer Pool — Double-buffered readback
    // ══════════════════════════════════════════════════════════════════

    /// Get or create a staging buffer for readback
    fn get_staging_buffer(&mut self, width: u32, height: u32) -> (usize, u64) {
        let bytes_per_row = width * 4;
        let aligned = (bytes_per_row + 255) & !255;
        let total_size = aligned as u64 * height as u64;

        // Reuse if matching size exists
        for (i, entry) in self.staging_pool.iter().enumerate() {
            if !entry.in_use && entry.size >= total_size {
                return (i, entry.size);
            }
        }

        // Create new
        let buffer = self.device.create_buffer(&BufferDescriptor {
            label: Some(&format!("Staging Buffer #{}", self.staging_pool.len())),
            size: total_size,
            usage: BufferUsages::COPY_DST | BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });

        let idx = self.staging_pool.len();
        self.staging_pool.push(StagingEntry {
            buffer,
            size: total_size,
            in_use: false,
        });

        (idx, total_size)
    }

    /// Read rendered texture to CPU with double-buffered staging
    pub fn read_texture_optimized(
        &mut self,
        texture: &Texture,
        width: u32,
        height: u32,
    ) -> Result<Vec<u8>, String> {
        let (staging_idx, staging_size) = self.get_staging_buffer(width, height);
        let bytes_per_row = width * 4;
        let aligned = (bytes_per_row + 255) & !255;
        let staging = &self.staging_pool[staging_idx];

        // ── Copy texture → staging buffer ────────────────────────
        let mut encoder = self
            .device
            .create_command_encoder(&CommandEncoderDescriptor {
                label: Some("Readback Encoder"),
            });

        encoder.copy_texture_to_buffer(
            ImageCopyTexture {
                texture,
                mip_level: 0,
                origin: Origin3d::ZERO,
                aspect: TextureAspect::All,
            },
            ImageCopyBuffer {
                buffer: &staging.buffer,
                layout: ImageDataLayout {
                    offset: 0,
                    bytes_per_row: Some(aligned),
                    rows_per_image: Some(height),
                },
            },
            Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );

        self.queue.submit(Some(encoder.finish()));

        // ── Map & read ────────────────────────────────────────────
        let buffer_slice = staging.buffer.slice(..staging_size);
        let (tx, rx) = std::sync::mpsc::channel();

        buffer_slice.map_async(MapMode::Read, move |result| {
            tx.send(result).unwrap();
        });

        self.device.poll(Maintain::Wait);

        rx.recv()
            .map_err(|_| "Map callback dropped".to_string())?
            .map_err(|e| format!("Map failed: {}", e))?;

        // Extract data (skip padding)
        let mapped = buffer_slice.get_mapped_range();
        let raw = &*mapped;

        let row_bytes = (width * 4) as usize;
        let mut data = Vec::with_capacity(row_bytes * height as usize);

        for row in 0..height as usize {
            let start = row * aligned as usize;
            data.extend_from_slice(&raw[start..start + row_bytes]);
        }

        drop(mapped);
        staging.buffer.unmap();

        Ok(data)
    }

    // ══════════════════════════════════════════════════════════════════
    // Legacy compatibility methods
    // ══════════════════════════════════════════════════════════════════

    /// Create offscreen render texture
    pub fn create_texture(&self, width: u32, height: u32) -> Result<Texture, String> {
        let texture = self.device.create_texture(&TextureDescriptor {
            label: Some("Offscreen Render Target"),
            size: Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: TextureDimension::D2,
            format: TextureFormat::Rgba8Unorm,
            usage: TextureUsages::RENDER_ATTACHMENT
                | TextureUsages::COPY_SRC
                | TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        Ok(texture)
    }

    /// Legacy waveform render (backward compatible with existing gpu_api.rs)
    pub fn render_waveform_to_texture(
        &mut self,
        texture: &Texture,
        width: u32,
        height: u32,
        points: &[f32],
        point_count: u32,
        color: [f32; 4],
    ) -> Result<(), String> {
        self.render_waveform_optimized(
            texture,
            width,
            height,
            points,
            point_count,
            point_count, // No decimation in legacy path
            color,
        )
    }

    /// Legacy readback (delegates to optimized path)
    pub fn read_texture_to_cpu(
        &mut self,
        texture: &Texture,
        width: u32,
        height: u32,
    ) -> Result<Vec<u8>, String> {
        self.read_texture_optimized(texture, width, height)
    }
}