// gpu_test_screen.dart - GPU 渲染器测试页面

import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import '../src/rust/frb_generated.dart';

class GpuTestScreen extends StatefulWidget {
  const GpuTestScreen({Key? key}) : super(key: key);

  @override
  State<GpuTestScreen> createState() => _GpuTestScreenState();
}

class _GpuTestScreenState extends State<GpuTestScreen> {
  bool _gpuInitialized = false;
  ui.Image? _image;
  String _status = 'Not initialized';

  @override
  void initState() {
    super.initState();
    _initGpu();
  }

  Future<void> _initGpu() async {
    try {
      final result = RustLib.instance.api.crateApiGpuApiGpuInit();
      setState(() {
        _gpuInitialized = (result == 0);
        _status = _gpuInitialized ? 'GPU initialized' : 'GPU init failed';
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
    }
  }

  Future<void> _renderWaveform() async {
    if (!_gpuInitialized) {
      setState(() {
        _status = 'GPU not initialized';
      });
      return;
    }

    try {
      // 生成测试波形数据（正弦波）
      const pointCount = 1000;
      final points = Float32List(pointCount * 2);
      for (int i = 0; i < pointCount; i++) {
        final x = i / (pointCount - 1);  // [0, 1]
        final y = sin(2.0 * pi * 5.0 * x) * 0.5 + 0.5;  // sine wave in [0, 1]
        points[i * 2] = x;
        points[i * 2 + 1] = y;
      }

      // 调用 GPU 渲染
      final imageData = RustLib.instance.api.crateApiGpuApiGpuRenderWaveform(
        width: 800,
        height: 600,
        points: points,
        pointCount: pointCount,
        r: 255,
        g: 0,
        b: 0,
        a: 255,
      );

      // 将 RGBA 字节数据转换为 ui.Image 对象
      final image = await _createImageFromRgba(imageData, 800, 600);

      setState(() {
        _image = image;
        _status = 'Rendered ${imageData.length} bytes';
      });
    } catch (e) {
      setState(() {
        _status = 'Render error: $e';
      });
    }
  }

  /// 将 RGBA 字节数据转换为 ui.Image 对象
  Future<ui.Image> _createImageFromRgba(Uint8List rgbaBytes, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgbaBytes,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (image) => completer.complete(image),
    );
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GPU Renderer Test'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Status: $_status'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _renderWaveform,
              child: const Text('Render Waveform'),
            ),
            const SizedBox(height: 20),
            if (_image != null)
              Container(
                width: 800,
                height: 600,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                ),
                child: CustomPaint(
                  painter: _GpuImagePainter(_image!),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (_gpuInitialized) {
      RustLib.instance.api.crateApiGpuApiGpuCleanup();
    }
    super.dispose();
  }
}

class _GpuImagePainter extends CustomPainter {
  final ui.Image image;

  _GpuImagePainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}