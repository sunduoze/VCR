// gpu_renderer.rs - WebGPU (wgpu) 渲染器（续）

use pollster::block_on;
use wgpu::*;
use std::sync::Arc;

/// WebGPU 渲染器
pub struct GpuRenderer {
    device: Arc<Device>,
    queue: Arc<Queue>,
    render_pipeline: Option<RenderPipeline>,  // 测试用三角形管道
    shader_module: Option<ShaderModule>,     // 测试用 shader
    waveform_pipeline: Option<RenderPipeline>,  // 波形渲染管道
    uniform_buffer: Buffer,  // 统一缓冲区（颜色）
    bind_group: BindGroup,   // 绑定组
    vertex_buffer: Option<Buffer>,  // 顶点缓冲区
    max_points: usize,  // 当前顶点缓冲区大小（点数）
}

impl GpuRenderer {
    /// 初始化 WebGPU
    pub fn new() -> Result<Self, String> {
        // 0. 初始化日志（输出到终端和控制台）
        let _ = env_logger::try_init();
        log::info!("[GPU] ========== GPU Renderer Initializing ==========");
        
        // 1. 创建 wgpu Instance
        log::info!("[GPU] Step 1: Creating wgpu instance...");
        let instance = Instance::new(InstanceDescriptor {
            backends: Backends::all(),  // 自动选择最佳后端（DX12/Metal/Vulkan）
            ..Default::default()
        });
        log::info!("[GPU] Step 1 completed: Instance created");
        
        // 2. 请求 GPU adapter
        log::info!("[GPU] Step 2: Requesting GPU adapter...");
        let adapter = match block_on(instance.request_adapter(&RequestAdapterOptions {
            power_preference: PowerPreference::HighPerformance,
            compatible_surface: None,  // 离屏渲染，不需要 surface
            force_fallback_adapter: false,
        })) {
            Some(adapter) => {
                log::info!("[GPU] Step 2 completed: GPU adapter found: {:?}", adapter.get_info());
                adapter
            }
            None => {
                log::error!("[GPU] Step 2 FAILED: No GPU adapter found!");
                return Err("Failed to find GPU adapter".to_string());
            }
        };
        
        // 3. 请求设备（Device）和队列（Queue）
        log::info!("[GPU] Step 3: Requesting GPU device...");
        let (device, queue) = block_on(adapter.request_device(&DeviceDescriptor {
            label: Some("VCR GPU Device"),
            required_limits: Limits::default(),
            required_features: Features::empty(),
            memory_hints: MemoryHints::Performance,
        }, None)).map_err(|e| {
            log::error!("[GPU] Step 3 FAILED: Failed to create device: {}", e);
            format!("Failed to create device: {}", e)
        })?;
        log::info!("[GPU] Step 3 completed: GPU device created");
        
        // 将 device 和 queue 包装为 Arc（线程安全共享）
        let device = Arc::new(device);
        let queue = Arc::new(queue);
        
        // 6. 加载 WGSL shader
        let shader_code = include_str!("shader.wgsl");
        let shader_module = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("Waveform Shader"),
            source: ShaderSource::Wgsl(std::borrow::Cow::Borrowed(shader_code)),
        });
        
        log::info!("[GPU] Step 4: Creating render pipeline...");
        // 7. 创建渲染管道（测试用三角形）
        let render_pipeline = match Self::create_render_pipeline(&device, &shader_module) {
            Ok(pipeline) => {
                log::info!("[GPU] Step 4 completed: Render pipeline created");
                pipeline
            }
            Err(e) => {
                log::error!("[GPU] Step 4 FAILED: Failed to create render pipeline: {}", e);
                return Err(format!("Failed to create render pipeline: {}", e));
            }
        };
        
        log::info!("[GPU] Step 5: Creating waveform shader module...");
        // 8. 加载波形渲染 shader
        let waveform_shader_code = include_str!("shader_waveform.wgsl");
        let waveform_shader_module = match device.create_shader_module(ShaderModuleDescriptor {
            label: Some("Waveform Shader"),
            source: ShaderSource::Wgsl(std::borrow::Cow::Borrowed(waveform_shader_code)),
        }) {
            module => {
                log::info!("[GPU] Step 5 completed: Waveform shader module created");
                module
            }
        };
        
        // 9. 创建统一缓冲区（颜色）
        let uniform_buffer = device.create_buffer(&BufferDescriptor {
            label: Some("Uniform Buffer (Color)"),
            size: 16,  // vec4<f32> = 16 bytes
            usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        
        // 10. 创建绑定组布局
        let bind_group_layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
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
        
        // 11. 创建绑定组
        let bind_group = device.create_bind_group(&BindGroupDescriptor {
            label: Some("Uniform Bind Group"),
            layout: &bind_group_layout,
            entries: &[BindGroupEntry {
                binding: 0,
                resource: uniform_buffer.as_entire_binding(),
            }],
        });
        
        // 12. 创建波形渲染管道
        let waveform_pipeline = Self::create_waveform_pipeline(&device, &waveform_shader_module, &bind_group_layout)?;
        
        Ok(Self {
            device,
            queue,
            render_pipeline: Some(render_pipeline),
            shader_module: Some(shader_module),
            waveform_pipeline: Some(waveform_pipeline),
            uniform_buffer,
            bind_group,
            vertex_buffer: None,
            max_points: 0,
        })
    }
    
    /// 创建渲染管道
    fn create_render_pipeline(
        device: &Device,
        shader_module: &ShaderModule,
    ) -> Result<RenderPipeline, String> {
        let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("Render Pipeline Layout"),
            bind_group_layouts: &[],
            push_constant_ranges: &[],
        });
        
        let render_pipeline = device.create_render_pipeline(&RenderPipelineDescriptor {
            label: Some("Render Pipeline"),
            layout: Some(&pipeline_layout),
            vertex: VertexState {
                module: shader_module,
                entry_point: Some("vs_main"),
                buffers: &[],  // 暂时不使用顶点缓冲
                compilation_options: Default::default(),
            },
            fragment: Some(FragmentState {
                module: shader_module,
                entry_point: Some("fs_main"),
                targets: &[Some(ColorTargetState {
                    format: TextureFormat::Rgba8Unorm,
                    blend: Some(BlendState::REPLACE),
                    write_mask: ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: PrimitiveState {
                topology: PrimitiveTopology::TriangleList,
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
        
        Ok(render_pipeline)
    }
    
    /// 创建波形渲染管道
    fn create_waveform_pipeline(
        device: &Device,
        shader_module: &ShaderModule,
        bind_group_layout: &BindGroupLayout,
    ) -> Result<RenderPipeline, String> {
        let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("Waveform Render Pipeline Layout"),
            bind_group_layouts: &[bind_group_layout],
            push_constant_ranges: &[],
        });
        
        // 顶点缓冲区布局：每个顶点是 vec2<f32> (8 bytes)
        let vertex_buffer_layout = [VertexBufferLayout {
            array_stride: 8,  // 2 * 4 bytes (f32)
            step_mode: VertexStepMode::Vertex,
            attributes: &[VertexAttribute {
                format: VertexFormat::Float32x2,
                offset: 0,
                shader_location: 0,
            }],
        }];
        
        let render_pipeline = device.create_render_pipeline(&RenderPipelineDescriptor {
            label: Some("Waveform Render Pipeline"),
            layout: Some(&pipeline_layout),
            vertex: VertexState {
                module: shader_module,
                entry_point: Some("vs_main"),
                buffers: &vertex_buffer_layout,
                compilation_options: Default::default(),
            },
            fragment: Some(FragmentState {
                module: shader_module,
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
        
        Ok(render_pipeline)
    }
    
    /// 渲染波形到纹理
    pub fn render_waveform_to_texture(
        &mut self,
        texture: &Texture,
        width: u32,
        height: u32,
        points: &[f32],  // 波形数据点 (x, y 交替)
        point_count: u32,
        color: [f32; 4],  // RGBA 颜色 (0.0-1.0)
    ) -> Result<(), String> {
        let device = &self.device;
        let queue = &self.queue;
        let waveform_pipeline = self.waveform_pipeline.as_ref().ok_or("Waveform pipeline not initialized")?;
        
        // 1. 检查参数
        if points.is_empty() || point_count == 0 {
            return Ok(());  // 没有数据，直接返回
        }
        let point_count = point_count as usize;
        if points.len() < point_count * 2 {
            return Err("points array too small".to_string());
        }
        
        // 2. 创建顶点缓冲区
        let vertex_buffer = device.create_buffer(&BufferDescriptor {
            label: Some("Vertex Buffer (Waveform)"),
            size: (point_count * 2 * 4) as u64,  // point_count * 2 floats * 4 bytes
            usage: BufferUsages::VERTEX | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        
        // 3. 上传数据到顶点缓冲区
        queue.write_buffer(&vertex_buffer, 0, bytemuck::cast_slice(&points[0..point_count * 2]));
        
        // 4. 存储到 self.vertex_buffer
        self.vertex_buffer = Some(vertex_buffer);
        
        // 3. 写入颜色到统一缓冲区
        queue.write_buffer(&self.uniform_buffer, 0, bytemuck::cast_slice(&color));
        
        // 4. 创建命令编码器
        let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor {
            label: Some("Render Encoder"),
        });
        
        // 5. 创建渲染通道
        let view = texture.create_view(&TextureViewDescriptor::default());
        {
            let mut render_pass = encoder.begin_render_pass(&RenderPassDescriptor {
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
            
            // 6. 设置视口
            render_pass.set_viewport(0.0, 0.0, width as f32, height as f32, 0.0, 1.0);
            
            // 7. 设置渲染管线
            render_pass.set_pipeline(waveform_pipeline);
            
            // 8. 设置顶点缓冲区
            render_pass.set_vertex_buffer(0, self.vertex_buffer.as_ref().unwrap().slice(..));
            
            // 9. 设置统一缓冲区（绑定组）
            render_pass.set_bind_group(0, &self.bind_group, &[]);
            
            // 10. 绘制调用
            render_pass.draw(0..point_count as u32, 0..1);
        }
        
        // 11. 提交命令
        queue.submit(Some(encoder.finish()));
        
        Ok(())
    }
    
    /// 创建离屏渲染纹理
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
            format: TextureFormat::Rgba8Unorm,  // RGBA 8-bit 纹理
            usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::COPY_SRC | TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        
        Ok(texture)
    }
    
    /// 读取纹理数据到 CPU 内存
    pub fn read_texture_to_cpu(
        &self,
        texture: &Texture,
        width: u32,
        height: u32,
    ) -> Result<Vec<u8>, String> {
        let device = &self.device;
        let queue = &self.queue;
        
        // 计算对齐后的 bytes_per_row（必须 256 字节对齐）
        let bytes_per_row = width * 4;  // RGBA = 4 bytes/pixel
        let aligned_bytes_per_row = (bytes_per_row + 255) & !255;  // 对齐到 256 字节
        
        // 1. 创建 staging 缓冲区（CPU 可访问）
        let staging_buffer = device.create_buffer(&BufferDescriptor {
            label: Some("Staging Buffer"),
            size: (aligned_bytes_per_row * height) as u64,  // 使用对齐后的大小
            usage: BufferUsages::COPY_DST | BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        
        // 2. 创建命令编码器，复制纹理到缓冲区
        let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor {
            label: Some("Copy Encoder"),
        });
        
        encoder.copy_texture_to_buffer(
            ImageCopyTexture {
                texture,
                mip_level: 0,
                origin: Origin3d::ZERO,
                aspect: TextureAspect::All,
            },
            ImageCopyBuffer {
                buffer: &staging_buffer,
                layout: ImageDataLayout {
                    offset: 0,
                    bytes_per_row: Some(aligned_bytes_per_row),  // 使用对齐后的值
                    rows_per_image: Some(height),
                },
            },
            Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );
        
        // 3. 提交命令
        queue.submit(Some(encoder.finish()));
        
        // 4. 映射缓冲区到 CPU 内存
        let buffer_slice = staging_buffer.slice(..);
        buffer_slice.map_async(MapMode::Read, |_| {});
        
        // 5. 等待 GPU 完成
        device.poll(Maintain::Wait);
        
        // 6. 读取数据（去除 padding）
        let mut data = Vec::with_capacity((width * height * 4) as usize);
        
        // 重要：必须在单独的作用域内使用 BufferView，确保 drop 在 unmap() 之前
        {
            let mapped_range = buffer_slice.get_mapped_range();  // BufferView
            let mapped_slice: &[u8] = &mapped_range;  // &[u8]
            
            eprintln!("[DEBUG] mapped_slice.len() = {}", mapped_slice.len());
            eprintln!("[DEBUG] aligned_bytes_per_row = {}", aligned_bytes_per_row);
            eprintln!("[DEBUG] expected size = {}", aligned_bytes_per_row * height);
            
            // 检查大小
            if mapped_slice.len() < (aligned_bytes_per_row * height) as usize {
                eprintln!("[ERROR] Buffer too small: {} < {}", mapped_slice.len(), aligned_bytes_per_row * height);
                return Err(format!("Buffer too small: {} < {}", mapped_slice.len(), aligned_bytes_per_row * height));
            }
            
            // 逐行复制（去除 padding）
            for row in 0..height {
                let src_start = (row * aligned_bytes_per_row) as usize;
                let src_end = src_start + (width * 4) as usize;
                
                eprintln!("[DEBUG] row {}: src_start={}, src_end={}", row, src_start, src_end);
                
                // 检查边界
                if src_end > mapped_slice.len() {
                    eprintln!("[ERROR] Out of bounds: src_end={} > len={}", src_end, mapped_slice.len());
                    return Err(format!("Out of bounds: src_end={} > len={}", src_end, mapped_slice.len()));
                }
                
                data.extend_from_slice(&mapped_slice[src_start..src_end]);
            }
        }  // BufferView (mapped_range) 在这里被 drop
        
        // 7. 解除映射（必须在 BufferView drop 之后）
        staging_buffer.unmap();
        
        Ok(data)
    }
}

/// 测试函数：初始化 WebGPU 并渲染测试图案
#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_wgpu_init() {
        // ... (之前的测试代码)
    }
    
    #[test]
    fn test_wgpu_render() {
        let renderer = GpuRenderer::new();
        assert!(renderer.is_ok(), "Failed to initialize WebGPU");
        
        let renderer = renderer.unwrap();
        
        // 创建纹理
        let texture = renderer.create_texture(800, 600);
        assert!(texture.is_ok(), "Failed to create texture");
        
        let texture = texture.unwrap();
        
        // 生成测试波形数据点（正弦波）
        let point_count = 1000usize;
        let mut points = Vec::with_capacity(point_count * 2);
        for i in 0..point_count {
            let x = i as f32 / (point_count - 1) as f32;  // [0, 1]
            let y = (2.0 * std::f32::consts::PI * 5.0 * x).sin() * 0.5 + 0.5;  // sine wave in [0, 1]
            points.push(x);
            points.push(y);
        }
        
        // 渲染波形
        let result = renderer.render_waveform_to_texture(&texture, 800, 600, &points, point_count as u32, [1.0, 0.0, 0.0, 1.0]);
        assert!(result.is_ok(), "Failed to render waveform to texture: {:?}", result.err());
        
        // 读取纹理数据
        let data = renderer.read_texture_to_cpu(&texture, 800, 600);
        assert!(data.is_ok(), "Failed to read texture data");
        
        let data = data.unwrap();
        assert_eq!(data.len(), (800 * 600 * 4) as usize, "Texture data size mismatch");
        
        println!("[TEST] GPU waveform rendering test passed!");
    }
}
