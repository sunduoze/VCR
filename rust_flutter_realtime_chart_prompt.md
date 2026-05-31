# Rust + Flutter 超高数据量实时曲线绘制 —— 完整工程提示词文档

> **版本**: v1.0  
> **目标**: 20万点/秒持续吞吐 / 60fps稳定渲染 / 任意时间窗口缩放  
> **架构**: 四层零拷贝流水线（Rust实时层 → FFI桥 → Dart Isolate → Flutter渲染层）

---

## 使用说明

将本文档按**文件章节**拆分后分别提交给 AI 代码生成工具。每个章节包含独立的职责、接口、约束与性能契约。生成完成后，必须对照文末「全局一致性检查清单」验证跨文件接口对齐。

---

## 一、rust/Cargo.toml

### Role
Rust 系统构建专家

### Mission
生成 Rust 端 Cargo.toml，面向 20 万点/秒实时串口曲线系统。

### 硬性约束
- 使用 `edition = "2021"`
- 串口依赖：选择 `serialport`（同步阻塞版本，**非 tokio-serial**）
- 并发依赖：`crossbeam`（用于 channel，非缓冲本身）
- FFI 依赖：`libc`（用于 C 字符串与类型）
- 可选 GPU：`gl` + `glfw`（条件编译 `feature = "gpu_fallback"`）
- 性能特性：必须开启 `lto = "thin"`，`opt-level = 3`，`panic = "abort"`
- **禁止**任何 `tokio`、`async-std`、`futures` 运行时依赖

### 输出
完整的 Cargo.toml，含 `[profile.release]` 优化、features 定义、所有依赖版本锁定。

---

## 二、rust/src/main.rs

### Role
Rust 实时系统入口架构师

### Mission
生成程序入口与生命周期管理，负责启动实时串口线程、金字塔维护线程、FFI 暴露。

### 硬性约束
- 主函数仅在测试时编译（`#[cfg(test)]`），库模式无 main
- 提供 `init()` 函数，被 FFI 调用时启动：
  1. 串口读取线程（SCHED_FIFO 优先级）
  2. 金字塔聚合后台线程
  3. 初始化环形缓冲（1200 万点预分配）
- 使用 `std::thread::spawn` 创建 OS 线程，**禁止 tokio/async**
- 全局状态使用 `lazy_static` 或 `std::sync::OnceLock` 管理，**禁止 Mutex 包裹**
- 提供 `shutdown()` 安全停止所有线程

### 接口
```rust
pub fn init(port: &str, baud: u32) -> bool;
pub fn shutdown();
```

### 性能契约
- `init()` 必须在 100ms 内完成所有预分配
- 线程启动后串口线程永不休眠（阻塞在 read）

### 禁止事项
- 禁止在库模式下暴露 main 函数
- 禁止在初始化中做动态内存分配（除环形缓冲预分配外）

---

## 三、rust/src/serial.rs

### Role
Rust 嵌入式串口与零拷贝解析专家

### Mission
生成串口读取模块，实现实时优先级线程、栈上缓冲循环读取、零拷贝 DataPoint 解析。

### 硬性约束
- 线程函数签名：`fn serial_thread(port: String, baud: u32)`，通过 `std::thread::spawn` 启动
- 设置线程优先级：Linux 使用 `libc::pthread_setschedparam` 设置 `SCHED_FIFO`，优先级 80
- 栈上预分配：`let mut buf = [0u8; 65536];`，循环 `port.read(&mut buf)`
- 解析函数：`fn parse<'a>(buf: &'a [u8], len: usize) -> &'a [DataPoint]`，**必须返回原始缓冲区的子切片，禁止内部 Vec 分配**
- `DataPoint` 定义：`#[repr(C)] struct DataPoint { timestamp: f64, value: f64 }`
- 解析后通过无锁方式写入 ringbuffer（调用 `ringbuffer::push_batch`）

### 接口
```rust
pub fn start_serial_thread(port: &str, baud: u32);
pub fn stop_serial_thread();
```

### 性能契约
- `parse()` 时间复杂度 O(n)，n 为字节数，**零堆分配**
- 每帧数据（如 64 字节）解析耗时 < 1µs
- 串口线程 99.9% 时间阻塞在 `read()`，不消耗 CPU

### 禁止事项
- 禁止在解析中使用 `Vec::push` 或 `String`
- 禁止在串口线程中使用 `await`、tokio、async
- 禁止每解析一个点就调用 FFI 或跨线程通知

---

## 四、rust/src/ringbuffer.rs

### Role
Rust 无锁并发与缓存行优化专家

### Mission
生成无锁环形缓冲，支持单生产者多消费者，1200 万点预分配，读写索引缓存行分离。

### 硬性约束
- 容量：`12_000_000`（桌面端），通过 const 参数化
- 结构体必须缓存行对齐：
  ```rust
  #[repr(C, align(64))]
  pub struct LockFreeRingBuffer {
      buffer: Vec<DataPoint>,          // 预分配，永不 resize
      head: AtomicU64,                 // 写索引，独占缓存行
      _pad1: [u8; 64 - 8],
      tail: AtomicU64,                 // 读索引，独占缓存行
      _pad2: [u8; 64 - 8],
      generation: AtomicU64,           // 覆盖计数，用于 Flutter 失效检测
      _pad3: [u8; 64 - 8],
  }
  ```
- 写入：`push_batch(points: &[DataPoint])`，使用 `Ordering::Release` 写 head
- 读取：`read_batch(out: &mut [DataPoint], tail: u64) -> (usize, u64)`，使用 `Ordering::Acquire` 读 head
- 覆盖策略：head 追上 tail 时直接覆盖，generation 原子 +1

### 接口
```rust
pub fn new(capacity: usize) -> Self;
pub fn push_batch(&self, points: &[DataPoint]);
pub fn read_range(&self, start_idx: u64, end_idx: u64, out: &mut [DataPoint]) -> usize;
pub fn generation(&self) -> u64;
pub fn head(&self) -> u64;
```

### 性能契约
- `push_batch`: O(n)，无锁，无动态分配，单线程写安全
- `read_range`: O(n)，无锁，多线程读安全（读索引不修改）
- 伪共享防护：head/tail/generation 各距 64 字节

### 禁止事项
- 禁止使用 `Mutex`、`RwLock`、`parking_lot`
- 禁止 buffer resize
- 禁止在 `push_batch` 中做堆分配

---

## 五、rust/src/buckets.rs

### Role
Rust 时序数据聚合与降采样算法专家

### Mission
生成四级时间桶金字塔，支持异步聚合与 LTTB 降采样，保证任意窗口查询 < 500µs。

### 硬性约束
- 四级桶定义：
  ```rust
  struct Bucket {
      t_start: f64,
      min: f64,
      max: f64,
      first: f64,
      last: f64,
      count: u32,
  }
  ```
- 层级：L0=10ms, L1=100ms, L2=1s, L3=10s
- 后台线程每 10ms 从 ringbuffer 读取新数据，更新 L0，级联更新 L1/L2/L3
- 查询函数：`fn query(t_start: f64, t_end: f64, max_points: u32) -> Vec<Bucket>`，自动选择最优层级
- LTTB 实现：若选中层级桶数 > max_points，对该层桶运行 LTTB 降采样至 max_points

### 接口
```rust
pub fn start_bucket_thread();      // 启动后台聚合线程
pub fn query(t_start: f64, t_end: f64, max_points: u32) -> Vec<Bucket>;
pub fn stop_bucket_thread();
```

### 性能契约
- `query()` 时间：O(1) 层选择 + O(k) 桶读取 + O(max_points) LTTB，总耗时 < 500µs
- LTTB 输出严格 <= max_points
- 后台聚合线程每 10ms 唤醒一次，处理耗时 < 5ms

### 禁止事项
- 禁止在 query 中遍历原始数据（必须从金字塔读取）
- 禁止在 LTTB 中使用浮点除零或 NaN 传播
- 禁止后台线程阻塞在 ringbuffer 读（非阻塞轮询）

---

## 六、rust/src/query.rs

### Role
Rust FFI 数据出口与内存管理专家

### Mission
生成视口查询接口与 Triple Buffering 轮转，暴露 C 兼容结构体给 Dart。

### 硬性约束
- `PointsBuffer` 定义：
  ```rust
  #[repr(C)]
  pub struct PointsBuffer {
      pub ptr: *const f32,   // 交错 x,y,x,y...
      pub len: u32,
      pub generation: u64,   // ringbuffer 覆盖计数
  }
  ```
- 内部维护 3 个 `Vec<f32>`，容量固定为 `max_points * 2`，轮转复用
- 查询流程：
  1. 从 `buckets::query` 获取 Bucket 列表
  2. 若需 LTTB，执行降采样
  3. 将结果交错写入当前轮转 Vec（x,y,x,y...）
  4. 返回 `PointsBuffer` 指向该 Vec
- 提供 `set_viewport(t_start, t_end, max_points)` 缓存查询参数

### 接口
```rust
pub fn set_viewport(t_start: f64, t_end: f64, max_points: u32);
pub fn get_points() -> PointsBuffer;  // 同步，Dart 每 16ms 调用
pub fn get_generation() -> u64;
```

### 性能契约
- `get_points()` 零拷贝：返回指针指向预分配 Vec，不分配新内存
- 3 Vec 轮转：当前读 → 下一写 → 空闲，无读写竞争
- 内存安全：ptr 有效直到下一次 `get_points()` 调用

### 禁止事项
- 禁止在 `get_points()` 中使用 `Vec::new` 或 `to_vec`
- 禁止返回动态分配的小 Vec
- 禁止在 FFI 边界使用 Rust 复杂类型（仅 `repr(C)`）

---

## 七、rust/src/ffi.rs

### Role
Rust FFI 边界与 C ABI 专家

### Mission
生成所有 C 导出函数，暴露给 Dart `dart:ffi` 调用。

### 硬性约束
- 使用 `#[no_mangle]` 与 `pub extern "C"`
- 导出函数清单：
  ```rust
  pub extern "C" fn serial_init(port: *const c_char, baud: u32) -> bool;
  pub extern "C" fn serial_shutdown();
  pub extern "C" fn set_viewport(t_start: f64, t_end: f64, max_points: u32);
  pub extern "C" fn get_points() -> PointsBuffer;
  pub extern "C" fn get_latest_timestamp() -> f64;
  pub extern "C" fn get_generation() -> u64;
  pub extern "C" fn set_quality_level(level: u8);
  ```
- 字符串处理：port 参数为 C 字符串，内部转换为 Rust `&str`，禁止泄漏
- `PointsBuffer` 作为返回值直接传递（按值返回，非指针）

### 性能契约
- 所有函数执行时间 < 10µs（除 `serial_init` 外）
- 无锁、无动态分配

### 禁止事项
- 禁止使用 `flutter_rust_bridge` 宏
- 禁止返回 `String`/`Vec` 等 Rust 自有类型
- 禁止在 FFI 函数中做复杂计算

---

## 八、rust/src/gpu_fallback.rs

### Role
Rust OpenGL 与跨平台 GPU 渲染专家

### Mission
生成可选的 GPU Texture 渲染兜底，当 CPU 绘制瓶颈时由 Rust 直接渲染曲线到纹理。

### 硬性约束
- 条件编译：`#[cfg(feature = "gpu_fallback")]`
- 使用 OpenGL 3.3 Core / ES 3.0 兼容 API
- 创建共享纹理，Flutter 通过 Texture Widget 的 `textureId` 引用
- 渲染流程：
  1. 从 query 获取当前视口数据
  2. 上传顶点缓冲到 GPU（VBO）
  3. 简单 vertex shader 做坐标变换，fragment shader 画线
  4. 渲染到 FBO 绑定的纹理
- 提供 `fn render_to_texture()` 供 Flutter 帧回调触发

### 接口
```rust
pub fn init_gpu(width: u32, height: u32) -> i64; // 返回 textureId
pub fn render_to_texture(points: &PointsBuffer, view: &Viewport);
pub fn shutdown_gpu();
```

### 性能契约
- `render_to_texture`: GPU 侧耗时 < 5ms（百万级点）
- 纹理与 Flutter 共享，零拷贝

### 禁止事项
- 禁止在 GPU 回退路径中回读 CPU 内存
- 禁止每帧重新编译 shader
- 禁止在 GPU 路径中做 LTTB（仍由 CPU 预采样）

---

## 九、lib/ffi_bridge.dart

### Role
Dart FFI 绑定与零拷贝内存专家

### Mission
生成 `dart:ffi` 绑定，直接加载 Rust 动态库，零拷贝读取 PointsBuffer。

### 硬性约束
- 使用 `dart:ffi` 与 `ffi` package，**禁用 flutter_rust_bridge**
- 定义 C 结构体：
  ```dart
  final class PointsBuffer extends Struct {
    external Pointer<Float> ptr;
    @Uint32()
    external int len;
    @Uint64()
    external int generation;
  }
  ```
- 绑定函数：
  ```dart
  final serialInit = dylib.lookupFunction<...>('serial_init');
  final setViewport = dylib.lookupFunction<...>('set_viewport');
  final getPoints = dylib.lookupFunction<PointsBuffer Function(), PointsBuffer Function()>('get_points');
  final getGeneration = dylib.lookupFunction<...>('get_generation');
  ```
- 零拷贝读取：`final floatList = pointsBuffer.ptr.asTypedList(pointsBuffer.len * 2);`

### 性能契约
- `asTypedList` 零拷贝，O(1)
- FFI 调用开销 < 1µs

### 禁止事项
- 禁止在 FFI 层做 JSON 序列化
- 禁止将 `Float32List` 拷贝到 `List<double>`
- 禁止使用 `flutter_rust_bridge` 生成的代码

---

## 十、lib/chart_isolate.dart

### Role
Dart Isolate 与实时数据流水线专家

### Mission
生成 ChartIsolate，独立执行循环，每 16ms 轮询 Rust FFI，执行坐标变换，向 Main Isolate 投递顶点。

### 硬性约束
- 必须是**同步死循环**，禁止 await/异步：
  ```dart
  void chartIsolateEntry(SendPort sendPort) {
    final receivePort = ReceivePort();
    sendPort.send(receivePort.sendPort);
    // 初始化 FFI
    while (running) {
      final buffer = getPoints();
      final vertices = pool.acquire();
      // 坐标变换：数据坐标 → 屏幕像素
      for (...) { ... }
      sendPort.send(vertices);
      sleep(Duration(milliseconds: 16));
    }
  }
  ```
- 坐标变换矩阵：根据当前 Viewport（x 范围 + 画布尺寸）计算，使用 `Float32List` 存储结果
- 接收 Viewport 变更：通过 `ReceivePort` 接收新的 Viewport 对象，更新本地状态
- 对象池：使用 `typed_data_pool.dart` 的 `TypedDataPool`

### 接口
```dart
Future<SendPort> spawnChartIsolate();
void killChartIsolate();
```

### 性能契约
- 每轮循环总耗时 < 8ms（含 FFI + 变换）
- 向 Main Isolate 发送的数据为不可变 `Float32List`
- 零 setState、零 Widget 重建

### 禁止事项
- 禁止在 Isolate 中使用 `async`/`await`/`Future`
- 禁止在 Isolate 中创建 `List<double>` 或动态数组
- 禁止每轮循环分配新内存（对象池外）

---

## 十一、lib/typed_data_pool.dart

### Role
Dart 内存管理与对象池专家

### Mission
生成 `Float32List` 对象池，避免 Dart GC 抖动。

### 硬性约束
- 实现 `TypedDataPool<T extends TypedData>`：
  ```dart
  class TypedDataPool {
    final Queue<Float32List> _available = Queue();
    final int _capacity;      // 单个 buffer 容量（元素数）
    final int _initialSize;   // 初始池大小
  }
  ```
- 初始容量 4，按需增长，但每帧分配 ≤ 2 次
- `acquire()`: 从队列取出，若空则分配新 `Float32List(_capacity)`
- `release(Float32List data)`: 清空数据（可选）后放回队列
- 线程安全：Chart Isolate 单线程使用，无需锁

### 接口
```dart
Float32List acquire();
void release(Float32List data);
int get size;
```

### 性能契约
- `acquire`/`release`: O(1)
- 命中池时零分配
- 池空时分配一次，复用 N 次

### 禁止事项
- 禁止在池中存储不同容量的 `Float32List`
- 禁止在 `release` 中创建新对象

---

## 十二、lib/painter.dart

### Role
Flutter 高性能渲染与 Skia 专家

### Mission
生成 CustomPainter，实现零分配、Picture 预绘制、引用感知重绘。

### 硬性约束
- `ChartPainter` 定义：
  ```dart
  class ChartPainter extends CustomPainter {
    final Float32List points;      // 来自 Chart Isolate
    final Picture? staticPicture;  // 预绘制的网格/坐标轴
    final Viewport viewport;
  }
  ```
- `paint()` 只做：
  ```dart
  if (staticPicture != null) canvas.drawPicture(staticPicture!);
  canvas.drawPoints(PointMode.polygon, points, paint);
  ```
  或 `canvas.drawRawPoints`（若可用）
- `shouldRepaint`：
  ```dart
  bool shouldRepaint(covariant ChartPainter old) => 
    !identical(old.points, points) || old.viewport != viewport;
  ```
- `Paint` 对象预创建，`paint()` 中禁止 `Paint()` 新建
- 网格/坐标轴预绘制：Viewport 改变时生成 `Picture`，否则复用

### 接口
```dart
ChartPainter({required this.points, this.staticPicture, required this.viewport});
```

### 性能契约
- `paint()` 耗时 < 5ms（10 万点以下）
- `shouldRepaint` 判断 O(1)
- 无对象分配

### 禁止事项
- 禁止在 `paint()` 中创建 `Path`、`Offset`、`Paint`（每帧新建）
- 禁止在 `paint()` 中做坐标变换或浮点运算
- 禁止调用 `setState`

---

## 十三、lib/viewport.dart

### Role
Flutter 状态管理与手势交互专家

### Mission
生成 Viewport 模型与手势控制，实现无 setState 的视口更新。

### 硬性约束
- `Viewport` 定义：
  ```dart
  @immutable
  class Viewport {
    final double tStart;
    final double tEnd;
    final double minValue;
    final double maxValue;
    final Size canvasSize;
  }
  ```
- 使用 `ValueNotifier<Viewport>` 管理状态
- `GestureDetector`：
  - 水平拖动：平移时间窗口
  - 双指缩放：缩放时间范围
  - 垂直拖动：平移数值范围
- 视口变化时，通过 `SendPort` 通知 Chart Isolate，**绝不调用 setState**

### 接口
```dart
Viewport copyWith({...});
Matrix4 get transformMatrix; // 数据 → 屏幕变换矩阵
```

### 性能契约
- 手势处理耗时 < 1ms
- 通知 Chart Isolate 通过 SendPort，异步零阻塞

### 禁止事项
- 禁止在 Viewport 变更时调用 `setState`
- 禁止在手势回调中做浮点 heavy 计算

---

## 十四、lib/main.dart

### Role
Flutter 应用架构与性能集成专家

### Mission
生成最小 UI 骨架，集成 ChartIsolate、Texture Fallback、ValueNotifier 驱动。

### 硬性约束
- 结构：
  ```dart
  class MyApp extends StatelessWidget {
    final ValueNotifier<Viewport> viewportNotifier = ValueNotifier(initialViewport);
    final ValueNotifier<Float32List?> pointsNotifier = ValueNotifier(null);
    SendPort? chartIsolateSendPort;
    int? textureId; // GPU fallback 时非空
  }
  ```
- 启动流程：
  1. `initState`: 加载 FFI、初始化 Rust、`spawn ChartIsolate`
  2. ChartIsolate 通过 `ReceivePort` 发送 `Float32List` → 更新 `pointsNotifier`
  3. `ValueNotifier` 驱动 `AnimatedBuilder` / `CustomPaint`
- 渲染切换：
  - 默认：`CustomPaint(painter: ChartPainter(...))`
  - GPU 模式：`Texture(textureId: textureId)` + 叠加 `CustomPaint`（仅坐标轴）
- 手势：`GestureDetector` 包裹，更新 `viewportNotifier` → `SendPort` 通知 Isolate

### 性能契约
- Main Isolate 帧构建时间 < 5ms
- 零 `setState`（除初始加载外）

### 禁止事项
- 禁止在 `build()` 中做数据解析或坐标变换
- 禁止在 Main Isolate 中遍历 `Float32List` 做计算
- 禁止每帧创建新 Widget 树（使用 `const` 构造）

---

## 十五、ARCHITECTURE.md

### Role
技术文档与系统架构图专家

### Mission
生成架构文档，包含数据流时序图、内存布局图、模块交互说明。

### 内容要求
1. **数据流时序图**（Mermaid）：
   - 串口中断 → 栈上 buf → 零拷贝解析 → RingBuffer → 金字塔聚合 → FFI → Dart Isolate → Main Isolate → 屏幕
   - 标注每步耗时预算（如：解析 <1µs，查询 <500µs，变换 <8ms，渲染 <5ms）
2. **内存布局图**：
   - Rust 侧：RingBuffer 1200 万点内存占用、三级缓冲 Vec、四级金字塔
   - FFI 边界：PointsBuffer 指针传递、零拷贝
   - Dart 侧：对象池 Float32List、Picture 缓存
3. **模块交互矩阵**：哪个线程/Isolate 访问哪些数据，无锁/原子/发送端口策略
4. **性能调优清单**：如何验证 20 万点/秒、60fps、0ms 主线程预算

### 格式
Markdown，含 Mermaid 图表，可直接放入 GitHub/GitLab 渲染。

---

## 附录：全局一致性检查清单

分文件生成后，必须验证以下接口对齐。任一不对齐，整个架构零拷贝承诺即失效。

| 检查项 | Rust 侧 | Dart 侧 |
|--------|---------|---------|
| `PointsBuffer` 字段 | `ptr: *const f32, len: u32, generation: u64` | `Pointer<Float> ptr, int len, int generation` |
| `get_points` 签名 | `fn get_points() -> PointsBuffer` | `PointsBuffer Function()` |
| `set_viewport` 参数 | `(f64, f64, u32)` | `(double, double, int)` |
| 交错格式 | `x,y,x,y...` | `Float32List` 长度 = `len * 2` |
| `generation` 用途 | 覆盖计数 | 失效检测 |
| 容量参数 | `12_000_000` (桌面) / `2_000_000` (移动) | 与 Rust 对齐 |
| 对象池容量 | 3 Vec 轮转 | 初始 4 个 Float32List |
| 轮询周期 | N/A (被动查询) | 16ms 死循环 |

---

## 附录：绝对禁止清单（违反即架构失败）

1. **禁止**在 Dart 代码中使用 `List<double>` 或动态数组接收数据点 —— 必须使用 `Float32List` 或 `Pointer`。
2. **禁止**在串口线程中使用 `Mutex`、`RwLock` 或任何阻塞锁 —— 仅允许无锁原子操作。
3. **禁止**每收到一个数据点触发任何 FFI 调用 —— 必须批量缓冲，16ms 周期推送。
4. **禁止**在主 Isolate 进行坐标变换、浮点运算或数据解析 —— 主 Isolate 帧预算为 0ms。
5. **禁止**每帧分配新内存（对象池外） —— 每帧堆分配 ≤ 2 次。
6. **禁止**在 Chart Isolate 中使用 `await`、`Future` 或异步网络请求 —— 必须是同步死循环。
7. **禁止**在 `CustomPainter.paint()` 中创建 `Path`、`Paint`（每帧新建）或 `Offset` 对象 —— 必须预创建并复用。
8. **禁止**在图表数据路径中使用 JSON / Protobuf / 任何序列化 —— 全链路必须是原始内存指针传递。
9. **禁止**使用 `flutter_rust_bridge` —— 全 FFI 层使用纯 `dart:ffi`。
10. **禁止**在 Rust 中使用 `tokio`、`async-std` 或任何异步运行时 —— 串口与金字塔线程必须是裸 OS 线程。
