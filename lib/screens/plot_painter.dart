// Plot painters — part of plot_screen.dart
part of 'plot_screen.dart';

class _MinimapPainter extends CustomPainter {
  final List<PlotChannel> channels;
  final double dataXMin, dataXMax;
  final bool shareYAxis;
  final double globalYMin, globalYMax;
  final int viewportRefreshCount;

  _MinimapPainter({
    required this.channels,
    required this.dataXMin,
    required this.dataXMax,
    required this.shareYAxis,
    required this.globalYMin,
    required this.globalYMax,
    required this.viewportRefreshCount,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rangeX = dataXMax - dataXMin;
    if (rangeX <= 0) return;

    for (final ch in channels) {
      if (!ch.visible) continue;

      // P0-2: Prefer GC-free viewportData, fallback to ch.data
      final int ptCount;
      final double Function(int) getX, getY;
      if (ch.viewportData.isNotEmpty) {
        ptCount = ch.viewportData.length;
        getX = (i) => ch.viewportData.x(i);
        getY = (i) => ch.viewportData.y(i);
      } else if (ch.data.isNotEmpty) {
        ptCount = ch.data.length;
        getX = (i) => ch.data[i].x;
        getY = (i) => ch.data[i].y;
      } else {
        continue;
      }
      // Each channel uses its own Y range so all are visible in the minimap
      final chYMin = ch.autoScaleY ? ch.yMin : ch.yMinManual;
      final chYMax = ch.autoScaleY ? ch.yMax : ch.yMaxManual;
      final rangeY = chYMax - chYMin;
      if (rangeY <= 0) continue;

      final paint = Paint()
        ..color = ch.color.withAlpha(150)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;

      final path = Path();
      var started = false;
      for (int i = 0; i < ptCount; i++) {
        final x = ((getX(i) - dataXMin) / rangeX) * size.width;
        final y = size.height - ((getY(i) - chYMin) / rangeY) * size.height;
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter old) {
    return dataXMin != old.dataXMin ||
        dataXMax != old.dataXMax ||
        shareYAxis != old.shareYAxis ||
        globalYMin != old.globalYMin ||
        globalYMax != old.globalYMax ||
        viewportRefreshCount != old.viewportRefreshCount;
  }
}

class _PlotPainter extends CustomPainter {
  // ═══ Per-frame reusable Float32List buffers for drawRawPoints ═══
  Float32List? _lineBuf;
  Float32List? _envBuf;
  Float32List? _minMaxBuf;  // P1-2: vertical min-max line segments

  // ═══ Static cached paint objects (zero allocation on paint path) ═══
  static final _gpuImagePaint = Paint()..filterQuality = FilterQuality.high;
  static final _gridPaint = Paint()
    ..color = const Color(0xFF4A5A70)
    ..strokeWidth = 0.5;
  static final _zeroPaint = Paint()
    ..color = const Color(0xFF4A5A70)
    ..strokeWidth = 1.0;
  static final _gridTextStyle = TextStyle(
    color: const Color(0xFF8B949E),
    fontSize: 15,
    fontFamily: 'DS-Digital',
  );
  static final _miniBgPaint = Paint()..color = const Color(0xDD161B22);
  static final _aaDownsamplePaint = Paint()
    ..filterQuality = FilterQuality.medium
    ..blendMode = BlendMode.srcOver;
  // FIXED(P1): Reusable per-channel Paint + Path objects (zero per-frame allocation)
  static final _linePaint = Paint()..style = PaintingStyle.stroke;
  static final _envelopeFillPaint = Paint()
    ..style = PaintingStyle.fill;
  // P1-2: Min-max vertical line paint — oscilloscope-style per-bucket density bar
  static final _minMaxLinePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.5
    ..strokeCap = StrokeCap.round;
  // P4: Gap marker paints — shaded column + edge lines at data discontinuities
  static final _gapMarkerPaint = Paint()
    ..style = PaintingStyle.fill;
  static final _gapEdgePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  // Dot line style: cached paint + path
  static final _dotLinePaint = Paint()..style = PaintingStyle.stroke;
  static final _dotPointPaint = Paint();
  // Reusable TextPainters (one per frame use case, avoid per-frame allocation)
  static final _overlayTp = TextPainter(textDirection: TextDirection.ltr);
  static final _crosshairTp = TextPainter(textDirection: TextDirection.ltr);

  // ═══ Dark theme paints ═══
  static final _dkBg = Paint()..color = const Color(0xFF0A0E14);
  static final _dkPlotBg = Paint()..color = const Color(0xFF0D1117);
  static final _dkBorder = Paint()
    ..color = const Color(0xFF30363D)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0;
  // Legacy aliases for GPU waveform path (always dark)
  static final _bgPaint = Paint()..color = const Color(0xFF0A0E14);
  static final _plotBgPaint = Paint()..color = const Color(0xFF0D1117);
  static final _borderPaint = Paint()
    ..color = const Color(0xFF30363D)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0;
  static final _dkCursor = Paint()
    ..color = const Color(0x4058A6FF)
    ..strokeWidth = 0.5;
  static final _dkTooltipBg = Paint()..color = const Color(0xCC0D1117);
  static final _dkOverlayStyle = TextStyle(
    color: const Color(0xFF58A6FF),
    fontSize: 17,
    fontFamily: 'DS-Digital',
  );
  static final _dkCoordStyle = TextStyle(
    color: const Color(0xFFC9D1D9),
    fontSize: 17,
    fontFamily: 'DS-Digital',
  );
  static final _dkInfoStyle = TextStyle(
    color: const Color(0xFFB0B8C4),
    fontSize: 16,
    fontFamily: 'DS-Digital',
  );

  // ═══ Light theme paints ═══
  static final _ltBg = Paint()..color = const Color(0xFFF6F8FA);
  static final _ltPlotBg = Paint()..color = const Color(0xFFFFFFFF);
  static final _ltBorder = Paint()
    ..color = const Color(0xFFD0D7DE)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0;
  static final _ltCursor = Paint()
    ..color = const Color(0x400960DA)
    ..strokeWidth = 0.5;
  static final _ltTooltipBg = Paint()..color = const Color(0xDDF6F8FA);
  static final _ltOverlayStyle = TextStyle(
    color: const Color(0xFF0969DA),
    fontSize: 17,
    fontFamily: 'DS-Digital',
  );
  static final _ltCoordStyle = TextStyle(
    color: const Color(0xFF24292F),
    fontSize: 17,
    fontFamily: 'DS-Digital',
  );
  static final _ltInfoStyle = TextStyle(
    color: const Color(0xFF57606A),
    fontSize: 16,
    fontFamily: 'DS-Digital',
  );
  static final _miniBgLightPaint = Paint()..color = const Color(0xDDFFFFFF);

  /// Draw a dashed line between [start] and [end].
  static void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint,
      {double dash = 4.0, double gap = 4.0}) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final length = (end - start).distance;
    if (length == 0) return;
    final invLen = 1.0 / length;
    double pos = 0;
    bool draw = true;
    while (pos < length) {
      final segLen = draw ? dash : gap;
      if (draw) {
        final t1 = pos * invLen;
        final t2 = (pos + segLen).clamp(0, length) * invLen;
        canvas.drawLine(
          Offset(start.dx + dx * t1, start.dy + dy * t1),
          Offset(start.dx + dx * t2, start.dy + dy * t2),
          paint,
        );
      }
      pos += segLen;
      draw = !draw;
    }
  }

  // ── Instance fields ──────────────────────────────────────────
  final List<PlotChannel> channels;
  final double xMin, xMax, yMin, yMax;
  final Offset? mousePosition;
  final int fps;
  final int totalPoints;
  final double aaScale;
  final int globalDecimals;
  final bool shareYAxis;
  final ui.Image? gpuWaveformImage;
  final double deltaTime;
  final int viewportRefreshCount;
  final bool isDarkTheme;
  final _RenderMode renderMode;

  // P2-2: Static layer cache (background/grid/axes — rebuild only on layout/theme change)
  static ui.Picture? _staticPicture;
  static int _staticVersion = 0;

  /// Release static GPU resources. Call from PlotScreen.dispose() or on theme switch.
  static void disposeStaticCache() {
    _staticPicture?.dispose();
    _staticPicture = null;
    _staticVersion = 0;
  }

  ui.Picture? _cachedPicture;
  int _cacheVersion = 0;

  _PlotPainter({
    required this.channels,
    required this.xMin, required this.xMax,
    required this.yMin, required this.yMax,
    this.mousePosition,
    required this.fps,
    required this.totalPoints,
    this.aaScale = 1.0,
    this.globalDecimals = 3,
    this.shareYAxis = false,
    this.isDarkTheme = true,
    this.gpuWaveformImage,
    this.deltaTime = 1.0,
    required this.viewportRefreshCount,
    this.renderMode = _RenderMode.auto,
  });

  double _xToScreen(double x, double w) {
    if (xMax == xMin) return w / 2;
    return (x - xMin) / (xMax - xMin) * w;
  }

  double _yToScreen(double y, double h, double yMinCh, double yMaxCh) {
    if (yMaxCh == yMinCh) return h / 2;
    return h - (y - yMinCh) / (yMaxCh - yMinCh) * h;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // ── GPU-accelerated rendering path ──
    // If we have a GPU-rendered waveform texture, use it directly
    if (gpuWaveformImage != null) {
      // Draw background first (matches _paintInternal)
      canvas.drawRect(Rect.fromLTWH(0, 0, w, h), _bgPaint);
      
      // Calculate plot area margins (must match _paintInternal)
      final yAxisChannels = channels.where((ch) => ch.visible && ch.showYAxis).toList();
      final leftYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 0).length;
      final rightYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 1).length;
      final plotLeft = 50.0 + leftYAxes * 45.0;
      final plotBottom = 40.0;
      final plotRight = 10.0 + rightYAxes * 45.0;
      final plotTop = 10.0;
      final plotW = w - plotLeft - plotRight;
      final plotH = h - plotTop - plotBottom;

      // Draw plot area background
      canvas.drawRect(Rect.fromLTWH(plotLeft, plotTop, plotW, plotH), _plotBgPaint);

      // Draw GPU waveform image (it already contains grid, waveforms, and axes)
      final srcRect = Rect.fromLTWH(0, 0, gpuWaveformImage!.width.toDouble(), gpuWaveformImage!.height.toDouble());
      final dstRect = Rect.fromLTWH(plotLeft, plotTop, plotW, plotH);
      canvas.drawImageRect(gpuWaveformImage!, srcRect, dstRect, _gpuImagePaint);

      // Draw border
      canvas.drawRect(Rect.fromLTWH(plotLeft, plotTop, plotW, plotH), _borderPaint);

      // Draw FPS and point count overlay
      _drawOverlay(canvas, w, h, fps, totalPoints);

      // Draw crosshair if mouse is in plot area
      if (mousePosition != null) {
        final mx = mousePosition!.dx;
        final my = mousePosition!.dy;
        if (mx >= plotLeft && mx <= plotLeft + plotW &&
            my >= plotTop && my <= plotTop + plotH) {
          _drawCrosshair(canvas, mx, my, plotLeft, plotTop, plotW, plotH, w, h);
        }
      }
      return; // Skip CPU rendering
    }

    // ── Anti-aliasing via supersampling ──
    if (aaScale > 1.0) {
      final recorder = ui.PictureRecorder();
      final ssCanvas = Canvas(recorder);
      // Scale up: draw logical coordinates at aaScale× resolution.
      // Pass aaScale as the scale factor so stroke widths / dot radii
      // are compensated (divided) here — they will look right after
      // the logical-size downsample below.
      ssCanvas.scale(aaScale, aaScale);
      _paintInternal(ssCanvas, w, h, aaScale);
      final picture = recorder.endRecording();
      try {
        final image = picture.toImageSync(
          (w * aaScale).round(),
          (h * aaScale).round(),
        );
        // Scale back to logical size WITHOUT stretching — just downsample.
        final srcRect = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
        final dstRect = Rect.fromLTWH(0, 0, w, h);
        canvas.drawImageRect(image, srcRect, dstRect, _aaDownsamplePaint);
        image.dispose();
      } catch (e) {
        // Fallback: draw directly without supersampling
        _paintInternal(canvas, w, h, 1.0);
      }
      picture.dispose();
    } else {
      // FIXED(P1)-A 优化：PictureRecorder 缓存
      // Content-based hash: tracks actual viewport data shape, not frame counter.
      // The counter changes every frame in real-time mode → cache was always invalid.
      int contentHash = Object.hash(xMin, xMax, yMin, yMax);
      for (final ch in channels) {
        if (ch.visible) {
          final vd = ch.viewportData;
          contentHash = Object.hash(contentHash, vd.length, ch.envelopeData.length);
          if (vd.isNotEmpty) {
            // Sample first/mid/last points (X + Y) to detect real data changes
            final mid = vd.length ~/ 2;
            contentHash = Object.hash(contentHash,
                vd.firstX, vd.firstY, vd.x(mid), vd.y(mid), vd.lastX, vd.lastY);
          }
        }
      }
      bool cacheValid = (_cachedPicture != null && _cacheVersion == contentHash);
      
      if (cacheValid) {
        canvas.drawPicture(_cachedPicture!);
      } else {
        final recorder = ui.PictureRecorder();
        final cacheCanvas = Canvas(recorder);
        _paintInternal(cacheCanvas, w, h, 1.0);
        _cachedPicture = recorder.endRecording();
        _cacheVersion = contentHash;
        canvas.drawPicture(_cachedPicture!);
      }
    }

    // ── Crosshair overlay (drawn AFTER cached/AA picture — never cached) ──
    _drawCrosshairOverlay(canvas, w, h);
  }

  void _paintInternal(Canvas canvas, double w, double h, double scale) {
    // Calculate dynamic margins based on number of Y axes
    final yAxisChannels = channels.where((ch) => ch.visible && ch.showYAxis).toList();
    final leftYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 0).length;
    final rightYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 1).length;

    final plotLeft = 50.0 + leftYAxes * 45.0;
    final plotBottom = 40.0;
    final plotRight = 10.0 + rightYAxes * 45.0;
    final plotTop = 10.0;
    final plotW = w - plotLeft - plotRight;
    final plotH = h - plotTop - plotBottom;

    if (plotW <= 0 || plotH <= 0) return;

    // P2-2: Static layer cache — rebuild only on layout/theme/axis-range change
    // Hash includes: layout geometry + theme + visible Y-axis channels state + axis ranges
    // P3-3: Added shareYAxis to hash (toggling shareYAxis changes grid rendering)
    // Memory-leak fix: round float values to 4 significant digits so that tiny
    // auto-scale fluctuations (<0.01% of range) don't invalidate the cache every frame.
    double _hashRound(double v) {
      if (v == 0.0) return 0.0;
      final abs = v.abs();
      final scale = abs < 1e-6 ? 1e12 : abs > 1e6 ? 1 : 1e6 / abs;
      return (v * scale).roundToDouble() / scale;
    }
    int staticHash = Object.hash(
      isDarkTheme,
      plotLeft, plotTop, plotW, plotH,
      _hashRound(xMin), _hashRound(xMax), _hashRound(yMin), _hashRound(yMax),
      deltaTime, globalDecimals,
      shareYAxis,
      yAxisChannels.length,
    );
    for (int ci = 0; ci < yAxisChannels.length; ci++) {
      final ch = yAxisChannels[ci];
      staticHash = Object.hash(staticHash,
        ch.visible, ch.showYAxis, ch.decimals, ch.color.toARGB32(),
        ch.autoScaleY, _hashRound(ch.yMin), _hashRound(ch.yMax),
        _hashRound(ch.yMinManual), _hashRound(ch.yMaxManual),
        ci % 2, // left/right side
      );
    }

    if (_staticPicture == null || _staticVersion != staticHash) {
      // DIAG: Memory leak fix: dispose old Picture before creating new one.
      // Skia Picture wraps native GPU resources; without explicit dispose(),
      // the old picture's resources leak until Dart GC runs (which may take
      // minutes → multi-GB accumulation). Root cause of the ~9.5GB issue.
      _staticPicture?.dispose();
      _staticPicture = null;
      final recorder = ui.PictureRecorder();
      final staticCanvas = Canvas(recorder);
      _drawStaticLayer(staticCanvas, w, h, scale,
          plotLeft, plotTop, plotW, plotH, plotRight, plotBottom);
      _staticPicture = recorder.endRecording();
      _staticVersion = staticHash;
    }

    // Draw cached static layer (background, grid, axes, labels, border)
    canvas.drawPicture(_staticPicture!);

    // ── FPS / point count overlay (dynamic, changes every frame) ──
    final infoStyle = isDarkTheme ? _dkInfoStyle : _ltInfoStyle;
    final infoTp = TextPainter(
      text: TextSpan(text: 'FPS: $fps  Pts: $totalPoints', style: infoStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    infoTp.paint(canvas, Offset(plotLeft + plotW - infoTp.width - 4, plotTop + 4));

    // ── Waveform clipping (dynamic layer) ──
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(plotLeft, plotTop, plotW, plotH));

    for (final ch in channels) {
      if (!ch.visible || ch.data.isEmpty) continue;

      final double chYMin;
      final double chYMax;
      if (shareYAxis) {
        chYMin = yMin;
        chYMax = yMax;
      } else {
        chYMin = ch.autoScaleY ? ch.yMin : ch.yMinManual;
        chYMax = ch.autoScaleY ? ch.yMax : ch.yMaxManual;
      }

      _drawChannel(canvas, ch, plotLeft, plotTop, plotW, plotH, chYMin, chYMax, scale);
    }

    canvas.restore();
  }

  /// Draws crosshair, tooltip, and per-channel values ON TOP of cached content.
  /// Called from paint() after PictureCache/AA draw — never cached.
  void _drawCrosshairOverlay(Canvas canvas, double w, double h) {
    if (mousePosition == null) return;

    // Calculate plot bounds (same as _paintInternal)
    final yAxisChannels = channels.where((ch) => ch.visible && ch.showYAxis).toList();
    final leftYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 0).length;
    final rightYAxes = yAxisChannels.where((ch) => yAxisChannels.indexOf(ch) % 2 == 1).length;
    final plotLeft = 50.0 + leftYAxes * 45.0;
    final plotBottom = 40.0;
    final plotRight = 10.0 + rightYAxes * 45.0;
    final plotTop = 10.0;
    final plotW = w - plotLeft - plotRight;
    final plotH = h - plotTop - plotBottom;
    if (plotW <= 0 || plotH <= 0) return;

    final mx = mousePosition!.dx;
    final my = mousePosition!.dy;
    if (mx < plotLeft || mx > plotLeft + plotW ||
        my < plotTop || my > plotTop + plotH) return;

    // ── Cursor lines ──
    final cursorPaint = isDarkTheme ? _dkCursor : _ltCursor;
    canvas.drawLine(Offset(mx, plotTop), Offset(mx, plotTop + plotH), cursorPaint);
    canvas.drawLine(Offset(plotLeft, my), Offset(plotLeft + plotW, my), cursorPaint);

    // ── Coordinate tooltip ──
    final dataX = xMin + (mx - plotLeft) / plotW * (xMax - xMin);
    final dataY = yMax - (my - plotTop) / plotH * (yMax - yMin);
    int maxDecimals = 3;
    for (final ch in channels) {
      if (ch.visible && ch.decimals > maxDecimals) maxDecimals = ch.decimals;
    }
    final coordText = 'X: ${dataX.toStringAsFixed(maxDecimals)}  Y: ${dataY.toStringAsFixed(maxDecimals)}';
    final tp = _crosshairTp
      ..text = TextSpan(text: coordText, style: isDarkTheme ? _dkCoordStyle : _ltCoordStyle)
      ..layout();
    var tx = mx + 12;
    var ty = my - tp.height - 8;
    if (tx + tp.width > plotLeft + plotW) tx = mx - tp.width - 8;
    if (ty < plotTop) ty = my + 8;
    canvas.drawRect(
      Rect.fromLTWH(tx - 2, ty - 1, tp.width + 4, tp.height + 2),
      isDarkTheme ? _miniBgPaint : _miniBgLightPaint,
    );
    tp.paint(canvas, Offset(tx, ty));

    // ── Per-channel values at cursor X ──
    double yOffset = ty + tp.height + 4;
    for (final ch in channels) {
      if (!ch.visible || ch.data.isEmpty) continue;
      final val = _getValueAtX(ch, dataX);
      if (val != null) {
        final chText = '${ch.channelName}: ${val.toStringAsFixed(ch.decimals)}';
        final ctp = TextPainter(
          text: TextSpan(text: chText, style: TextStyle(
            color: ch.color,
            fontSize: 16,
            fontFamily: 'DS-Digital',
          )),
          textDirection: TextDirection.ltr,
        )..layout();
        if (yOffset + ctp.height > plotTop + plotH) break;
        ctp.paint(canvas, Offset(tx, yOffset));
        yOffset += ctp.height + 2;
      }
    }
  }

  /// Draws the static (non-waveform) layer: background, grid, axes, labels, border, info.
  /// Cached via _staticPicture / _staticVersion since these only change on zoom/pan/theme.
  void _drawStaticLayer(Canvas canvas, double w, double h, double scale,
      double plotLeft, double plotTop, double plotW, double plotH,
      double plotRight, double plotBottom) {
    // ── Background ──
    final bg = isDarkTheme ? _dkBg : _ltBg;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), bg);

    // ── Plot area background ──
    final plotBg = isDarkTheme ? _dkPlotBg : _ltPlotBg;
    canvas.drawRect(Rect.fromLTWH(plotLeft, plotTop, plotW, plotH), plotBg);

    // ── Grid lines (dashed) ──
    final xTicks = _niceTicks(xMin, xMax, 10);
    for (final tick in xTicks) {
      final sx = _xToScreen(tick, plotW) + plotLeft;
      if (sx < plotLeft || sx > plotLeft + plotW) continue;
      _drawDashedLine(canvas, Offset(sx, plotTop), Offset(sx, plotTop + plotH), _gridPaint);
    }

    final yTicks = _niceTicks(yMin, yMax, 8);
    for (final tick in yTicks) {
      final sy = _yToScreen(tick, plotH, yMin, yMax) + plotTop;
      if (sy < plotTop || sy > plotTop + plotH) continue;
      _drawDashedLine(canvas, Offset(plotLeft, sy), Offset(plotLeft + plotW, sy), _gridPaint);
    }

    // Zero line
    final zeroY = _yToScreen(0, plotH, yMin, yMax) + plotTop;
    if (zeroY >= plotTop && zeroY <= plotTop + plotH) {
      canvas.drawLine(Offset(plotLeft, zeroY), Offset(plotLeft + plotW, zeroY), _zeroPaint);
    }

    // ── X axis labels ──
    final labelStyle = TextStyle(
      color: const Color(0xFF8B949E),
      fontSize: 16,
      fontFamily: 'DS-Digital',
    );
    for (final tick in xTicks) {
      final sx = _xToScreen(tick, plotW) + plotLeft;
      if (sx < plotLeft || sx > plotLeft + plotW) continue;
      final tp = TextPainter(
        text: TextSpan(text: _formatXTick(tick, deltaTime), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(sx - tp.width / 2, h - plotBottom + 4));
    }

    // ── Per-channel Y axis labels ──
    final yAxisChannels = channels.where((ch) => ch.visible && ch.showYAxis).toList();
    if (yAxisChannels.isEmpty) {
      for (final tick in yTicks) {
        final sy = _yToScreen(tick, plotH, yMin, yMax) + plotTop;
        if (sy < plotTop || sy > plotTop + plotH) continue;
        final tp = TextPainter(
          text: TextSpan(text: _formatTick(tick, globalDecimals), style: _gridTextStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(plotLeft - tp.width - 4, sy - tp.height / 2));
      }
    } else if (yAxisChannels.length == 1) {
      for (final tick in yTicks) {
        final sy = _yToScreen(tick, plotH, yMin, yMax) + plotTop;
        if (sy < plotTop || sy > plotTop + plotH) continue;
        final tp = TextPainter(
          text: TextSpan(text: tick.toStringAsFixed(yAxisChannels.first.decimals), style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(plotLeft - tp.width - 4, sy - tp.height / 2));
      }
    } else {
      for (int ci = 0; ci < yAxisChannels.length; ci++) {
        final ch = yAxisChannels[ci];
        final chYMin = ch.autoScaleY ? ch.yMin : ch.yMinManual;
        final chYMax = ch.autoScaleY ? ch.yMax : ch.yMaxManual;
        final chTicks = _niceTicks(chYMin, chYMax, 6);
        final chLabelStyle = TextStyle(
          color: ch.color,
          fontSize: 15,
          fontFamily: 'DS-Digital',
        );
        final isLeft = ci % 2 == 0;
        final leftIdx = (ci ~/ 2);
        final rightIdx = (ci ~/ 2);
        for (final tick in chTicks) {
          final sy = _yToScreen(tick, plotH, chYMin, chYMax) + plotTop;
          if (sy < plotTop || sy > plotTop + plotH) continue;
          final tickText = tick.toStringAsFixed(ch.decimals);
          final tp = TextPainter(
            text: TextSpan(text: tickText, style: chLabelStyle),
            textDirection: TextDirection.ltr,
          )..layout();
          if (isLeft) {
            final xOffset = plotLeft - tp.width - 4 - leftIdx * 45;
            tp.paint(canvas, Offset(xOffset.clamp(2, double.maxFinite), sy - tp.height / 2));
          } else {
            final xOffset = plotLeft + plotW + 4 + rightIdx * 45;
            tp.paint(canvas, Offset(xOffset, sy - tp.height / 2));
          }
        }
        final axisPaint = Paint()
          ..color = ch.color.withValues(alpha: 0.5)
          ..strokeWidth = 1.0;
        if (isLeft) {
          final x = plotLeft - leftIdx * 45 - 2;
          canvas.drawLine(Offset(x, plotTop), Offset(x, plotTop + plotH), axisPaint);
        } else {
          final x = plotLeft + plotW + rightIdx * 45 + 2;
          canvas.drawLine(Offset(x, plotTop), Offset(x, plotTop + plotH), axisPaint);
        }
      }
    }

    // ── Border ──
    final borderPaint = isDarkTheme ? _dkBorder : _ltBorder;
    canvas.drawRect(Rect.fromLTWH(plotLeft, plotTop, plotW, plotH), borderPaint);

  }
  void _drawChannel(Canvas canvas, PlotChannel ch, double ox, double oy, double w, double h, double chYMin, double chYMax, double scale) {
    // P0-2: Use GC-free _DataBuf (viewportData is always populated by envelope read)
    final data = ch.viewportData;
    if (data.isEmpty) return;

    // Use per-channel Y transform
    double yTransform(double y) {
      if (chYMax == chYMin) return h / 2;
      return h - (y - chYMin) / (chYMax - chYMin) * h;
    }

    // ── Trace mode: raw polyline, no envelope ──
    // When zoomed in deeply (few samples covering many pixels), envelope bands
    // produce ugly wide vertical bars. A simple polyline is cleaner.
    final samplesPerPixel = data.length / w;
    final useTrace = renderMode == _RenderMode.trace ||
        (renderMode == _RenderMode.auto && samplesPerPixel < ENVELOPE_THRESHOLD);
    if (useTrace) {
      _drawTrace(canvas, ch, data, ox, oy, w, h, yTransform);
      return;
    }

    // NOTE: Phase B: Render envelope fill (semi-transparent min-max band) before foreground line
    final envData = ch.envelopeData;
    if (envData.isNotEmpty && envData.length >= 2) {
      _drawEnvelope(canvas, ch, envData, ox, oy, w, h, yTransform);
      _drawMinMaxLines(canvas, ch, envData, ox, oy, w, h, yTransform);
    }

    // P4: Gap markers — shaded regions at temporal discontinuities
    _drawGapMarkers(canvas, ch, data, ox, oy, w, h, yTransform);

    switch (ch.lineStyle) {
      case LineStyle.dot:
        _drawDots(canvas, ch, data, ox, oy, w, h, yTransform, scale);
        break;
      case LineStyle.dotLine:
        _drawDotLine(canvas, ch, data, ox, oy, w, h, yTransform, scale);
        break;
      case LineStyle.line:
        _drawLine(canvas, ch, data, ox, oy, w, h, yTransform, scale);
        break;
      case LineStyle.filled:
        _drawFilled(canvas, ch, data, ox, oy, w, h, yTransform, scale, chYMin, chYMax);
        break;
    }
  }

  // 数据抽取：将大量数据点减少到适合屏幕显示的密度
  // NOTE: 性能优化：每个像素bucket只保留1个最有代表性的点
void _drawDots(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale) {
    if (data.isEmpty) return;
    
    // NOTE: 性能优化：使用Path批量绘制，减少draw call次数
    final paint = Paint()
      ..color = ch.color
      ..strokeWidth = ch.lineWidth
      ..strokeCap = StrokeCap.round;
    
    // FIXED(P1)-B 优化：批量绘制（替代 250K 次 drawCircle 调用）
    // drawRawPoints 需要扁平的 Float32List: [x1,y1, x2,y2, ...]
    // FIX: P0: reuse _lineBuf (same format), guarded with sublistView
    final n = data.length;
    if (_lineBuf == null || _lineBuf!.length < n * 2) {
      _lineBuf = Float32List(n * 2);
    }
    final buf = _lineBuf!;
    for (int i = 0; i < n; i++) {
      buf[i * 2] = _xToScreen(data.x(i), w) + ox;
      buf[i * 2 + 1] = yTransform(data.y(i)) + oy;
    }
    canvas.drawRawPoints(ui.PointMode.points, Float32List.sublistView(buf, 0, n * 2), paint);
  }

  // NOTE: Phase B: Render envelope fill background (semi-transparent min-max band)
  void _drawEnvelope(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform) {
    if (data.length < 4) return; // need ≥2 buckets (4 points: min0,max0,min1,max1)

    // Envelope data format: [x0,ymin0], [x0,ymax0], [x1,ymin1], [x1,ymax1], ...
    // Build polygon: top edge (ymax) forward, bottom edge (ymin) reverse
    // drawRawPoints(PointMode.polygon) auto-closes → no explicit close needed
    final n = data.length;
    if (_envBuf == null || _envBuf!.length < n * 2) {
      _envBuf = Float32List(n * 2);
    }
    final buf = _envBuf!;
    int pi = 0;
    // Top edge: yMax values (odd indices: 1, 3, 5, ...)
    for (int i = 1; i < n; i += 2) {
      buf[pi++] = _xToScreen(data.x(i), w) + ox;
      buf[pi++] = yTransform(data.y(i)) + oy;
    }
    // Bottom edge reverse: yMin values (even indices: ..., 4, 2, 0)
    for (int i = n - 2; i >= 0; i -= 2) {
      buf[pi++] = _xToScreen(data.x(i), w) + ox;
      buf[pi++] = yTransform(data.y(i)) + oy;
    }

    _envelopeFillPaint.color = ch.color.withValues(alpha: 0.25);
    final envView = Float32List.sublistView(buf, 0, pi);
    canvas.drawRawPoints(ui.PointMode.polygon, envView, _envelopeFillPaint);
  }

  // FIXED(P1)-2: Oscilloscope-style min-max vertical lines per bucket.
  // Draws a thin vertical line from yMin to yMax for each downsampled time bucket.
  // Combined with envelope fill, this gives the classic oscilloscope density view:
  //   envelope fill → wide band (25% alpha)
  //   min-max lines → sharp vertical bars (40% alpha, provides structure)
  //   avg line     → foreground trace (100% alpha, signal path)
  void _drawMinMaxLines(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform) {
    if (data.length < 2) return;

    // PointMode.lines: each 2 points = 1 line segment
    // data format: [x0,ymin0, x0,ymax0, x1,ymin1, x1,ymax1, ...]
    // For each bucket (even i = min, odd i+1 = max, same x):
    //   draw line (x, yMin) → (x, yMax)
    final nSegs = data.length ~/ 2;  // one segment per bucket
    final reqLen = nSegs * 4;        // 4 floats per segment (start.xy + end.xy)
    if (_minMaxBuf == null || _minMaxBuf!.length < reqLen) {
      _minMaxBuf = Float32List(reqLen);
    }
    final buf = _minMaxBuf!;
    int pi = 0;
    for (int i = 0; i < data.length; i += 2) {
      if (i + 1 >= data.length) break;
      final sx = _xToScreen(data.x(i), w) + ox;  // x same for min and max
      final syMin = yTransform(data.y(i)) + oy;
      final syMax = yTransform(data.y(i + 1)) + oy;
      buf[pi++] = sx;
      buf[pi++] = syMin;
      buf[pi++] = sx;
      buf[pi++] = syMax;
    }

    _minMaxLinePaint.color = ch.color.withValues(alpha: 0.40);
    final mmView = Float32List.sublistView(buf, 0, pi);
    canvas.drawRawPoints(ui.PointMode.lines, mmView, _minMaxLinePaint);
  }

  /// P4: Draw gap markers where data has temporal discontinuities.
  /// Gaps are detected when the time interval between consecutive viewport points
  /// exceeds 3× the expected bucket interval. Markers appear as thin shaded columns.
  void _drawGapMarkers(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform) {
    if (data.length < 2) return;

    final expectedInterval = (data.lastX - data.firstX) / (data.length - 1);
    if (expectedInterval <= 0) return;

    final gapThreshold = expectedInterval * 3.0;

    // Reuse static paint, update color per channel
    _gapMarkerPaint.color = ch.color.withValues(alpha: 0.18);
    _gapMarkerPaint.strokeWidth = 2.5;

    for (int i = 1; i < data.length; i++) {
      final dt = data.x(i) - data.x(i - 1);
      if (dt > gapThreshold) {
        // Gap detected between i-1 and i: draw shaded column between the two X positions
        final x1 = _xToScreen(data.x(i - 1), w) + ox;
        final x2 = _xToScreen(data.x(i), w) + ox;
        if (x2 - x1 < 4) continue; // too narrow to see

        canvas.drawRect(
          Rect.fromLTWH(x1 + 1, oy, x2 - x1 - 2, h),
          _gapMarkerPaint,
        );

        // Draw vertical dashed edges at gap boundaries
        final edgeW = 1.0;
        _gapEdgePaint.color = ch.color.withValues(alpha: 0.35);
        _gapEdgePaint.strokeWidth = edgeW;
        canvas.drawLine(Offset(x1, oy), Offset(x1, oy + h), _gapEdgePaint);
        canvas.drawLine(Offset(x2, oy), Offset(x2, oy + h), _gapEdgePaint);
      }
    }
  }

  void _drawDotLine(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale) {
    if (data.isEmpty) return;

    // FIX: P0: Use Path (non-closing polyline) to avoid PointMode.polygon
    // auto-close diagonal artifact. Also avoids stale buffer pollution.
    _polylinePath.reset();
    final sx = _xToScreen(data.x(0), w) + ox;
    final sy = yTransform(data.y(0)) + oy;
    _polylinePath.moveTo(sx, sy);
    for (int i = 1; i < data.length; i++) {
      _polylinePath.lineTo(_xToScreen(data.x(i), w) + ox, yTransform(data.y(i)) + oy);
    }
    // Semi-transparent line
    _dotLinePaint.color = ch.color.withValues(alpha: 0.5);
    _dotLinePaint.strokeWidth = ch.lineWidth;
    canvas.drawPath(_polylinePath, _dotLinePaint);

    // Dots on top (reuse _lineBuf for drawRawPoints)
    final n = data.length;
    if (_lineBuf == null || _lineBuf!.length < n * 2) {
      _lineBuf = Float32List(n * 2);
    }
    final buf = _lineBuf!;
    for (int i = 0; i < n; i++) {
      buf[i * 2] = _xToScreen(data.x(i), w) + ox;
      buf[i * 2 + 1] = yTransform(data.y(i)) + oy;
    }
    _dotPointPaint.color = ch.color;
    _dotPointPaint.strokeWidth = 2.5;
    _dotPointPaint.strokeCap = StrokeCap.round;
    canvas.drawRawPoints(ui.PointMode.points, Float32List.sublistView(buf, 0, n * 2), _dotPointPaint);
  }

  // FIX: P0: Reusable Path for non-closing polyline drawing.
  // drawRawPoints(PointMode.polygon) auto-closes last→first → diagonal artifact.
  // drawRawPoints(PointMode.lines) treats every pair as independent — breaks continuity.
  // Path with moveTo+lineTo is the correct non-closing polyline primitive.
  static final _polylinePath = Path();

  void _drawLine(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale) {
    if (data.isEmpty) return;

    _linePaint.color = ch.color;
    _linePaint.strokeWidth = ch.lineWidth;

    // FIX: P0: Use Path (non-closing polyline) to avoid PointMode.polygon auto-close
    // diagonal artifact AND avoid stale Float32List buffer pollution.
    _polylinePath.reset();
    final sx = _xToScreen(data.x(0), w) + ox;
    final sy = yTransform(data.y(0)) + oy;
    _polylinePath.moveTo(sx, sy);
    for (int i = 1; i < data.length; i++) {
      _polylinePath.lineTo(_xToScreen(data.x(i), w) + ox, yTransform(data.y(i)) + oy);
    }
    canvas.drawPath(_polylinePath, _linePaint);
  }

  // ── Trace mode: raw sample polyline (no envelope, no downsampling) ──
  // Used when samplesPerPixel < ENVELOPE_THRESHOLD (zoomed in).
  void _drawTrace(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform) {
    if (data.isEmpty) return;

    _linePaint.color = ch.color;
    _linePaint.strokeWidth = ch.lineWidth;

    // FIX: P0: Reuse static _polylinePath (same as _drawLine).
    // Avoid per-frame Path allocation.
    _polylinePath.reset();
    final sx = _xToScreen(data.x(0), w) + ox;
    final sy = yTransform(data.y(0)) + oy;
    _polylinePath.moveTo(sx, sy);
    for (int i = 1; i < data.length; i++) {
      _polylinePath.lineTo(_xToScreen(data.x(i), w) + ox, yTransform(data.y(i)) + oy);
    }
    canvas.drawPath(_polylinePath, _linePaint);
  }

  void _drawFilled(Canvas canvas, PlotChannel ch, _DataBuf data, double ox, double oy, double w, double h, double Function(double) yTransform, double scale, double chYMin, double chYMax) {
    if (data.length < 2) return;

    // Zero line position for this channel's Y range
    final zeroY = yTransform(0) + oy;

    // Calculate fill bounds
    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (int i = 0; i < data.length; i++) {
      final sy = yTransform(data.y(i)) + oy;
      if (sy < minY) minY = sy;
      if (sy > maxY) maxY = sy;
    }
    final fillTop = min(minY, zeroY);
    final fillBottom = max(maxY, zeroY);

    // Gradient from waveform (opaque) to zero (transparent)
    final rect = Rect.fromLTWH(ox, fillTop, w, fillBottom - fillTop);
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        ch.color.withValues(alpha: 0.4),
        ch.color.withValues(alpha: 0.05),
        ch.color.withValues(alpha: 0.4),
      ],
      stops: const [0.0, 0.5, 1.0],
    );

    final fillPaint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.fill;

    // Build fill path: along waveform then back along zero
    final path = Path();
    path.moveTo(_xToScreen(data.x(0), w) + ox, zeroY);
    for (int i = 0; i < data.length; i++) {
      final sx = _xToScreen(data.x(i), w) + ox;
      final sy = yTransform(data.y(i)) + oy;
      path.lineTo(sx, sy);
    }
    path.lineTo(_xToScreen(data.lastX, w) + ox, zeroY);
    path.close();
    canvas.drawPath(path, fillPaint);

    // Also draw the line on top
    _drawLine(canvas, ch, data, ox, oy, w, h, yTransform, scale);
  }

  double? _getValueAtX(PlotChannel ch, double targetX) {
    if (ch.data.isEmpty) return null;
    int lo = 0, hi = ch.data.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (ch.data[mid].x < targetX) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0 && (ch.data[lo].x - targetX).abs() > (ch.data[lo - 1].x - targetX).abs()) {
      lo--;
    }
    return ch.data[lo].y;
  }

  List<double> _niceTicks(double min, double max, int targetCount) {
    if (min == max) return [min];
    final range = max - min;
    final rawStep = range / targetCount;
    final magnitude = pow(10, (log(rawStep) / ln10).floor()).toDouble();
    final normalized = rawStep / magnitude;

    double niceStep;
    if (normalized <= 1.5) niceStep = magnitude;
    else if (normalized <= 3.5) niceStep = 2 * magnitude;
    else if (normalized <= 7.5) niceStep = 5 * magnitude;
    else niceStep = 10 * magnitude;

    // Guard: niceStep should never be 0, but handle numerically
    if (niceStep <= 0) return [min, max];

    final ticks = <double>[];
    var tick = (min / niceStep).ceil() * niceStep;
    while (tick <= max) {
      ticks.add(tick);
      tick += niceStep;
    }
    return ticks;
  }

  /// X轴刻度格式化：显示整数点号
  String _formatXTick(double val, [double deltaTime = 1.0]) {
    // X values are sample indices, multiply by Δt to show time in ms
    final timeMs = val * (deltaTime > 0 ? deltaTime : 1.0);
    if (timeMs.abs() >= 1000) {
      return '${(timeMs / 1000).toStringAsFixed(2)}s';
    } else if (timeMs.abs() >= 1) {
      return '${timeMs.toStringAsFixed(1)}ms';
    } else {
      return '${timeMs.toStringAsFixed(3)}ms';
    }
  }

  String _formatTick(double val, [int decimals = 3]) {
    if (val.abs() >= 1000) return val.toStringAsFixed(0);
    if (val.abs() >= 1) return val.toStringAsFixed(decimals.clamp(0, 4));
    if (val.abs() >= 0.01) return val.toStringAsFixed(decimals.clamp(2, 6));
    return val.toStringAsExponential(2);
  }

  @override
  bool shouldRepaint(covariant _PlotPainter oldDelegate) {
    // NOTE: Mouse/cursor moved? Always repaint (instant crosshair feedback)
    if (mousePosition != oldDelegate.mousePosition) return true;

    // NOTE: Render mode changed? Repaint needed
    if (renderMode != oldDelegate.renderMode) return true;

    // NOTE: Channel config changed (decimals, showYAxis, etc)? Repaint needed
    if (channels.length != oldDelegate.channels.length) return true;
    for (int i = 0; i < channels.length; i++) {
      final a = channels[i];
      final b = oldDelegate.channels[i];
      if (a.visible != b.visible ||
          a.color != b.color ||
          a.lineStyle != b.lineStyle ||
          a.decimals != b.decimals ||
          a.showYAxis != b.showYAxis) {
        return true;
      }
    }

    // FIX: P3-B revisited: viewportRefreshCount is incremented whenever
    // _refreshViewportData() runs → new viewportData is available → MUST repaint.
    // Previously this was a negative check (return false when equal but skip when
    // different), which meant xMin/xMax/yMin/yMax changes were sometimes missed.
    if (viewportRefreshCount != oldDelegate.viewportRefreshCount) {
      return true; // Viewport data was refreshed — always repaint
    }
    
    // NOTE: If viewport counter hasn't changed, check whether coordinates moved
    // (scrollbar drag / pan / zoom can change coordinates without refreshing viewport data).
    if (xMin != oldDelegate.xMin || xMax != oldDelegate.xMax ||
        yMin != oldDelegate.yMin || yMax != oldDelegate.yMax) {
      return true;
    }
    
    // GPU texture changed?
    if (gpuWaveformImage != oldDelegate.gpuWaveformImage) return true;
    
    // Only repaint when something actually changed (rare fallback)
    if (mousePosition != oldDelegate.mousePosition ||
        fps != oldDelegate.fps ||
        totalPoints != oldDelegate.totalPoints ||
        aaScale != oldDelegate.aaScale ||
        globalDecimals != oldDelegate.globalDecimals ||
        shareYAxis != oldDelegate.shareYAxis ||
        isDarkTheme != oldDelegate.isDarkTheme) {
      return true;
    }
    return false;
  }

  void _drawOverlay(Canvas canvas, double w, double h, int fps, int totalPoints) {
    final tp = _overlayTp
      ..text = TextSpan(text: 'FPS: $fps | Points: $totalPoints', style: isDarkTheme ? _dkOverlayStyle : _ltOverlayStyle)
      ..layout();
    tp.paint(canvas, Offset(w - tp.width - 8, 8));
  }

  void _drawCrosshair(Canvas canvas, double mx, double my,
      double plotLeft, double plotTop, double plotW, double plotH, double w, double h) {
    final cursorPaint = isDarkTheme ? _dkCursor : _ltCursor;
    canvas.drawLine(Offset(mx, plotTop), Offset(mx, plotTop + plotH), cursorPaint);
    canvas.drawLine(Offset(plotLeft, my), Offset(plotLeft + plotW, my), cursorPaint);

    // Show coordinates
    final dataX = xMin + (mx - plotLeft) / plotW * (xMax - xMin);
    final dataY = yMax - (my - plotTop) / plotH * (yMax - yMin);

    // Find max decimals across channels for alignment
    int maxDecimals = 3;
    for (final ch in channels) {
      if (ch.visible && ch.decimals > maxDecimals) maxDecimals = ch.decimals;
    }

    final coordText = 'X: ${dataX.toStringAsFixed(maxDecimals)}  Y: ${dataY.toStringAsFixed(maxDecimals)}';
    final tp = _crosshairTp
      ..text = TextSpan(text: coordText, style: isDarkTheme ? _dkCoordStyle : _ltCoordStyle)
      ..layout();

    // Position tooltip near cursor but avoid clipping
    double tx = mx + 10;
    double ty = my - 20;
    if (tx + tp.width > w - 10) tx = mx - tp.width - 10;
    if (ty < 10) ty = my + 20;

    // Background for tooltip
    canvas.drawRect(
      Rect.fromLTWH(tx - 4, ty - 2, tp.width + 8, tp.height + 4),
      isDarkTheme ? _dkTooltipBg : _ltTooltipBg,
    );
    tp.paint(canvas, Offset(tx, ty));
  }
}
