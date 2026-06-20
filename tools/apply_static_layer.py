import sys

path = r'D:\AI\upper_computer_tools\VCR\lib\screens\plot_screen.dart'
with open(path, 'r', encoding='utf-8-sig') as f:
    content = f.read()

paint_internal = '  void _paintInternal(Canvas canvas, double w, double h, double scale) {'
overlay_marker = '  void _drawOverlay(Canvas canvas, double w, double h, int fps, int totalPoints) {'
idx_start = content.index(paint_internal)
idx_end = content.index(overlay_marker)

# Get the old block
old_block = content[idx_start:idx_end]

new_block = '''  void _paintInternal(Canvas canvas, double w, double h, double scale) {
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

    // 🚀 P2: Static layer cache — bg, grid, axes regenerate only on zoom/pan/theme/resize.
    // Hash excludes viewportData (which changes every frame); only includes geometry + config.
    final staticVersion = Object.hash(
      xMin, xMax, yMin, yMax, deltaTime,
      plotLeft, plotTop, plotW, plotH,
      shareYAxis, isDarkTheme, globalDecimals,
      yAxisChannels.length,
      for (final ch in yAxisChannels)
        Object.hash(ch.autoScaleY, ch.yMin, ch.yMax, ch.yMinManual, ch.yMaxManual, ch.decimals, ch.color.toARGB32()),
    );

    if (_staticPicture == null || _staticVersion != staticVersion) {
      final recorder = ui.PictureRecorder();
      final staticCanvas = Canvas(recorder);
      _drawStaticLayer(staticCanvas, w, h, plotLeft, plotTop, plotW, plotH, plotBottom, yAxisChannels);
      _staticPicture = recorder.endRecording();
      _staticVersion = staticVersion;
    }
    canvas.drawPicture(_staticPicture!);

    // ── Waveform clipping ──
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(plotLeft, plotTop, plotW, plotH));

    for (final ch in channels) {
      if (!ch.visible || ch.data.isEmpty) continue;
      final double chYMin;
      final double chYMax;
      if (shareYAxis) {
        chYMin = yMin; chYMax = yMax;
      } else {
        chYMin = ch.autoScaleY ? ch.yMin : ch.yMinManual;
        chYMax = ch.autoScaleY ? ch.yMax : ch.yMaxManual;
      }
      _drawChannel(canvas, ch, plotLeft, plotTop, plotW, plotH, chYMin, chYMax, scale);
    }
    canvas.restore();

    // ── Overlay ──
    final infoStyle = isDarkTheme ? _dkInfoStyle : _ltInfoStyle;
    final infoTp = TextPainter(
      text: TextSpan(text: 'FPS: $fps  Pts: $totalPoints', style: infoStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    infoTp.paint(canvas, Offset(plotLeft + plotW - infoTp.width - 4, plotTop + 4));
  }

  /// 🚀 P2: Draw static layer (background, grid, axes, labels, border).
  /// This is cached and only regenerated on zoom/pan/theme/resize changes.
  void _drawStaticLayer(Canvas canvas, double w, double h,
      double plotLeft, double plotTop, double plotW, double plotH,
      double plotBottom, List<PlotChannel> yAxisChannels) {
    // ── Background ──
    final bg = isDarkTheme ? _dkBg : _ltBg;
    final plotBg = isDarkTheme ? _dkPlotBg : _ltPlotBg;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), bg);
    canvas.drawRect(Rect.fromLTWH(plotLeft, plotTop, plotW, plotH), plotBg);

    // ── Grid lines ──
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
    final labelStyle = TextStyle(color: const Color(0xFF8B949E), fontSize: 16, fontFamily: 'DS-Digital');
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
        final chLabelStyle = TextStyle(color: ch.color, fontSize: 15, fontFamily: 'DS-Digital');
        final isLeft = ci % 2 == 0;
        final leftIdx = (ci / 2).floor();
        final rightIdx = (ci / 2).floor();
        for (final tick in chTicks) {
          final sy = _yToScreen(tick, plotH, chYMin, chYMax) + plotTop;
          if (sy < plotTop || sy > plotTop + plotH) continue;
          final tp = TextPainter(
            text: TextSpan(text: tick.toStringAsFixed(ch.decimals), style: chLabelStyle),
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

'''

# Apply
content = content[:idx_start] + new_block + content[idx_end:]

with open(path, 'w', encoding='utf-8-sig', newline='\r\n') as f:
    f.write(content)

print('Done!')
