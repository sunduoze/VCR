// CustomPainter - 仅做 drawPoints（性能关键点）
// 性能关键点：
// 1. shouldRepaint() 根据接收到的顶点数组引用是否改变决定
// 2. paint() 仅调用 canvas.drawRawPoints(PointMode.lines, vertices, paint)
// 3. 坐标轴/网格使用 Picture 预绘制并 canvas.drawPicture 复用
// 4. 禁止在 paint() 中进行坐标变换或浮点运算

import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// 高性能波形绘制器
/// 仅负责将顶点数组绘制到 Canvas（无坐标变换、无计算）
class WaveformPainter extends CustomPainter {
  /// 顶点数组（屏幕像素坐标，交错 x,y）
  /// 由 ChartIsolate 通过 SendPort 发送而来
  final Float32List? vertices;
  
  /// 顶点数量（点数）
  final int vertexCount;
  
  /// 画笔（可配置颜色、线宽、抗锯齿）
  final Paint waveformPaint;
  
  /// 坐标轴/网格的预绘制 Picture（复用）
  ui.Picture? axisPicture;
  
  /// 是否需要重绘坐标轴（仅在尺寸变化时重新生成 axisPicture）
  final bool shouldRepaintAxis;
  
  /// 绘图区域尺寸（用于生成坐标轴 Picture）
  final double plotWidth;
  final double plotHeight;
  
  WaveformPainter({
    required this.vertices,
    required this.vertexCount,
    required this.waveformPaint,
    this.axisPicture,
    this.shouldRepaintAxis = false,
    this.plotWidth = 800.0,
    this.plotHeight = 600.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. 绘制坐标轴/网格（使用预绘制的 Picture）
    if (axisPicture != null) {
      canvas.drawPicture(axisPicture!);
    } else if (shouldRepaintAxis) {
      // 首次绘制或尺寸变化时，生成坐标轴 Picture
      final recorder = ui.PictureRecorder();
      final axisCanvas = Canvas(recorder);
      _drawAxis(axisCanvas, size);
      axisPicture = recorder.endRecording();
      canvas.drawPicture(axisPicture!);
    }
    
    // 2. 绘制波形（仅 drawRawPoints，无坐标变换）
    if (vertices != null && vertexCount > 0) {
      // 性能关键点：直接使用 Float32List，避免复制
      canvas.drawRawPoints(
        ui.PointMode.lines, // 连接相邻点（折线图）
        vertices!, // 交错 x,y 数组
        waveformPaint,
      );
    }
    
    // 3. 绘制 FPS 和调试信息（可选）
    _drawOverlay(canvas, size);
  }
  
  /// 绘制坐标轴/网格（仅在 shouldRepaintAxis 为 true 时调用）
  void _drawAxis(Canvas canvas, Size size) {
    final axisPaint = Paint()
      ..color = const Color(0xFF30363D)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    
    final gridPaint = Paint()
      ..color = const Color(0xFF21262D)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    
    // 绘制外框
    canvas.drawRect(
      Rect.fromLTWH(0, 0, plotWidth, plotHeight),
      axisPaint,
    );
    
    // 绘制网格线（示例：5x5 网格）
    const gridCount = 5;
    for (int i = 1; i < gridCount; i++) {
      final x = plotWidth * i / gridCount;
      final y = plotHeight * i / gridCount;
      
      // 垂直线
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, plotHeight),
        gridPaint,
      );
      
      // 水平线
      canvas.drawLine(
        Offset(0, y),
        Offset(plotWidth, y),
        gridPaint,
      );
    }
  }
  
  /// 绘制 FPS 和调试信息（可选）
  void _drawOverlay(Canvas canvas, Size size) {
    // 示例：绘制 FPS（实际 FPS 计算需要在 ChartIsolate 或主 Isolate 中进行）
    final textPainter = TextPainter(
      text: const TextSpan(
        text: '60 FPS', // 占位符（实际应从 ChartIsolate 接收）
        style: TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 12,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    
    textPainter.layout();
    textPainter.paint(canvas, const Offset(10, 10));
  }
  
  @override
  bool shouldRepaint(WaveformPainter oldDelegate) {
    // 性能关键点：仅根据顶点数组引用是否改变决定
    // 如果顶点数组引用相同（即 ChartIsolate 未发送新数据），则跳过重绘
    if (identical(vertices, oldDelegate.vertices)) {
      return false; // 顶点数组未变化，跳过重绘
    }
    
    // 顶点数组引用变化，需要重绘
    return true;
  }
}
