# VCR P0-P1 优化实施记录 (2026-06-21)

## P0-1: 接收循环直推管道 ✅
- receive_loop 调用 pipeline::push_sample_batch_with_x() 直推 FFI_CH_PYRAMIDS
- X值同步：Dart 改用 timestampMs（非自增计数器）
- main.dart 启动 FfiBridge.startPipeline()
- 消除 Dart↔Rust↔Dart 往返

## P0-2: Ticker 渲染解耦 ✅
- Timer(100ms) 只做 fetchRealData → 仅填充 ch.data
- Ticker(vsync) 做渲染 → _renderTickReal() / _renderTickDemo()
- _onTick 新增：FPS计数 + _tickBusy 防护 + dispatch 到 real/demo 渲染
- _renderTickReal(): X轴更新 + _refreshViewportData() + _fitYAxis() + setState()
- _renderTickDemo(): 同上但demoa模式
- 帧率理论从 ~20fps → 60fps

## P0-3: Dead Code 清理 ✅
- 删除 _updateRealDataUI() 方法（~45行）
- 删除 _lastDemoUpdate 变量
- 删除 _lastUIUpdate 变量
- 删除 _lastFetchEnd 变量及赋值

## P1: 全局异常捕获 ✅
- FlutterError.onError → _logCrashToFile('FlutterError', ...)
- PlatformDispatcher.instance.onError → _logCrashToFile('PlatformError', ...)
- 崩溃日志写入 %EXE_DIR%\crash_logs\crash_{timestamp}.txt
- import dart:ui (for PlatformDispatcher)

## P1: Release DLL 路径 ✅ (已有)
- rebuild.ps1 已在 02_cmd 步骤复制 vcr_lib.dll → build\windows\x64\runner\Release\

## 待实施
- P2: 删除 _fallbackViewportData（需真实设备运行稳定后）
- P2: gap marker 渲染、Isolate 视口计算
- P3: LFRB 零拷贝接入
