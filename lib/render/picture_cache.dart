// PictureCache — Phase 3: Pre-render static plot elements
// Static elements (grid lines, axis labels, borders) don't change frame-to-frame.
// Drawing them once into a Picture and replaying avoids 60+% of draw operations.

import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Cache key — when any of these change, the picture needs to be re-rendered
class PictureCacheKey {
  final double width;    // canvas pixel width
  final double height;   // canvas pixel height
  final double xMin;     // data X min
  final double xMax;     // data X max
  final double yMin;     // data Y min
  final double yMax;     // data Y max
  final Color gridColor;
  final Color textColor;
  final double fontSize;
  final int gridDivisionsX;
  final int gridDivisionsY;

  const PictureCacheKey({
    required this.width,
    required this.height,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
    this.gridColor = const Color(0x30FFFFFF),
    this.textColor = const Color(0x80FFFFFF),
    this.fontSize = 10.0,
    this.gridDivisionsX = 10,
    this.gridDivisionsY = 8,
  });

  /// Fuzzy match to avoid re-rendering on sub-pixel changes
  bool matches(PictureCacheKey other) {
    return (other.width - width).abs() < 1.0 &&
           (other.height - height).abs() < 1.0 &&
           (other.xMin - xMin).abs() < 0.001 &&
           (other.xMax - xMax).abs() < 0.001 &&
           (other.yMin - yMin).abs() < 0.001 &&
           (other.yMax - yMax).abs() < 0.001 &&
           other.gridColor == gridColor &&
           other.textColor == textColor &&
           other.fontSize == fontSize &&
           other.gridDivisionsX == gridDivisionsX &&
           other.gridDivisionsY == gridDivisionsY;
  }
}

/// Caches pre-rendered Picture of static plot elements.
///
/// Usage:
/// ```dart
/// final _cache = PictureCache();
///
/// // In paint():
/// _cache.render(canvas, size, key, (canvas, size, key) {
///   // Draw grid lines, axes, labels
/// });
/// ```
class PictureCache {
  ui.Picture? _cachedPicture;
  PictureCacheKey? _cachedKey;

  /// Maximum cached pictures (for multi-channel plots)
  // ignore: unused_field
  static const int _maxCacheSize = 4;

  /// Render static elements using cache.
  ///
  /// If the cache key matches (within tolerance), replays the cached Picture.
  /// Otherwise, records a new Picture via [builder].
  void render(
    Canvas canvas,
    Size size,
    PictureCacheKey key,
    void Function(Canvas canvas, Size size, PictureCacheKey key) builder,
  ) {
    if (_cachedPicture != null && _cachedKey != null && _cachedKey!.matches(key)) {
      // Replay cached picture — zero draw operations, just a single command
      canvas.drawPicture(_cachedPicture!);
      return;
    }

    // Record a new picture
    final recorder = ui.PictureRecorder();
    final recordCanvas = Canvas(recorder, Rect.fromLTWH(0, 0, size.width, size.height));

    builder(recordCanvas, size, key);

    // Dispose old picture before replacing
    _cachedPicture?.dispose();
    _cachedPicture = recorder.endRecording();
    _cachedKey = key;

    // Draw the newly recorded picture
    canvas.drawPicture(_cachedPicture!);
  }

  /// Invalidate the cache (forces re-render next time)
  void invalidate() {
    _cachedPicture?.dispose();
    _cachedPicture = null;
    _cachedKey = null;
  }

  /// Check if a key matches the current cache
  bool isCached(PictureCacheKey key) {
    return _cachedPicture != null && _cachedKey != null && _cachedKey!.matches(key);
  }

  void dispose() {
    _cachedPicture?.dispose();
    _cachedPicture = null;
    _cachedKey = null;
  }
}

/// Helper to draw grid lines and axes for oscilloscope-style plots
class PlotGridPainter {
  /// Draw grid lines, axis labels, and border.
  ///
  /// [canvas] - the canvas to draw on
  /// [size] - available drawing area
  /// [padding] - plot area padding (left/bottom for axis labels)
  /// [appendToRecorder] - if non-null, draws to a PictureRecorder instead
  static void draw({
    required Canvas canvas,
    required Size size,
    required EdgeInsets padding,
    required PictureCacheKey key,
  }) {
    final plotLeft = padding.left;
    final plotTop = padding.top;
    final plotRight = size.width - padding.right;
    final plotBottom = size.height - padding.bottom;
    final plotWidth = plotRight - plotLeft;
    final plotHeight = plotBottom - plotTop;

    final gridPaint = Paint()
      ..color = key.gridColor
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    final borderPaint = Paint()
      ..color = key.gridColor.withAlpha(60)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Draw grid lines (vertical)
    for (int i = 0; i <= key.gridDivisionsX; i++) {
      final x = plotLeft + (plotWidth * i / key.gridDivisionsX);
      canvas.drawLine(Offset(x, plotTop), Offset(x, plotBottom), gridPaint);
    }

    // Draw grid lines (horizontal)
    for (int i = 0; i <= key.gridDivisionsY; i++) {
      final y = plotTop + (plotHeight * i / key.gridDivisionsY);
      canvas.drawLine(Offset(plotLeft, y), Offset(plotRight, y), gridPaint);
    }

    // Draw border
    canvas.drawRect(
      Rect.fromLTRB(plotLeft, plotTop, plotRight, plotBottom),
      borderPaint,
    );

    // Draw axis labels (using Paragraph for text)
    // Y-axis labels
    final labelTextStyle = ui.TextStyle(
      color: key.textColor,
      fontSize: key.fontSize,
    );

    for (int i = 0; i <= key.gridDivisionsY; i++) {
      final yValue = key.yMax - (key.yMax - key.yMin) * i / key.gridDivisionsY;
      final label = _formatAxisLabel(yValue);
      final paragraphBuilder = ui.ParagraphBuilder(ui.ParagraphStyle(
        textDirection: TextDirection.ltr,
        fontSize: key.fontSize,
      ))
        ..pushStyle(labelTextStyle)
        ..addText(label);
      final paragraph = paragraphBuilder.build()
        ..layout(ui.ParagraphConstraints(width: padding.left - 4));

      final y = plotBottom - (plotHeight * i / key.gridDivisionsY) - 5;
      canvas.drawParagraph(paragraph, Offset(0, y));
    }

    // X-axis labels
    for (int i = 0; i <= key.gridDivisionsX; i++) {
      final xValue = key.xMin + (key.xMax - key.xMin) * i / key.gridDivisionsX;
      final label = _formatAxisLabel(xValue);
      final paragraphBuilder = ui.ParagraphBuilder(ui.ParagraphStyle(
        textDirection: TextDirection.ltr,
        fontSize: key.fontSize,
      ))
        ..pushStyle(labelTextStyle)
        ..addText(label);
      final paragraph = paragraphBuilder.build()
        ..layout(ui.ParagraphConstraints(width: 60));

      final x = plotLeft + (plotWidth * i / key.gridDivisionsX) - 30;
      canvas.drawParagraph(paragraph, Offset(x, plotBottom + 2));
    }
  }

  /// Format a value for axis display
  static String _formatAxisLabel(double value) {
    if (value.abs() < 0.001) return '0';
    if (value.abs() >= 1000) return '${value.toStringAsFixed(0)}';
    if (value.abs() >= 100) return '${value.toStringAsFixed(1)}';
    if (value.abs() >= 10) return '${value.toStringAsFixed(2)}';
    if (value.abs() >= 1) return '${value.toStringAsFixed(3)}';
    return '${value.toStringAsFixed(4)}';
  }
}