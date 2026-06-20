import re, sys

path = r'D:\AI\upper_computer_tools\VCR\lib\screens\plot_screen.dart'
with open(path, 'r', encoding='utf-8-sig') as f:
    content = f.read()

# ── P0-3: Remove _lastDemoUpdate (declaration + usage) ──
# Remove declaration
content = content.replace(
    '  // 帧率控制：防止setState调用过于频繁\n  DateTime _lastDemoUpdate = DateTime.now();\n  ',
    '  ')
# Remove usage in _startDemoData
content = content.replace(
    '      final shouldUpdateUI = now.difference(_lastDemoUpdate).inMilliseconds >= 50;\n'
    '      if (shouldUpdateUI) {\n'
    '        _refreshViewportData();\n'
    '        _lastDemoUpdate = now;\n'
    '        if (_autoScaleY) _fitYAxis();',
    '      _refreshViewportData();\n'
    '      if (_autoScaleY) _fitYAxis();')
content = content.replace(
    '      _lastDemoUpdate = now;\n        if (shouldUpdateUI) {\n          _refreshViewportData();\n        }',
    '      _refreshViewportData();')

# Remove shouldUpdateUI usage within startDemoData (simpler version)
for pattern in [
    ('      final shouldUpdateUI = now.difference(_lastDemoUpdate).inMilliseconds >= 50;\n        if (shouldUpdateUI) {\n          _refreshViewportData();\n          _lastDemoUpdate = now;\n        }',
     '      _refreshViewportData();'),
]:
    if pattern[0] in content:
        content = content.replace(pattern[0], pattern[1])

# ── P2-1: Remove _binarySearch ──
old_bs = '''  // Returns first index where data[i].x >= target.
  // If no such index, returns data.length.
  int _binarySearch(List<_DataPoint> data, double target) {
    int lo = 0, hi = data.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (data[mid].x < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

'''
content = content.replace(old_bs, '')

# ── P2-1: Replace fallback block with gap-only handler ──
old_fb_block = """      if (count == 0) {
        // 🚀 Phase C TODO: Remove fallback once per-channel pyramid is proven stable across all data sources.
        // Pyramid empty for this channel → fallback to raw data path
        if (_verbose) print('[FALLBACK] ${ch.channelName}: pyramid returned 0 points (tMin=$tMin tMax=$tMax ch.data.length=${ch.data.length} newestAbsX=$newestAbsX)');
        _debugLog('[VPD] ${ch.channelName}: pyramid empty, fallback to raw data');
        ch.viewportData = _fallbackViewportData(ch, newestAbsX, tMin, tMax, maxPts);
        ch.envelopeData = []; // No envelope in fallback mode
        continue;
      }"""

new_fb_block = """      if (count == 0) {
        // Pyramid empty for this channel — likely buffer just started or time range mismatch
        if (_verbose && _frameCount % 60 == 0) print('[GAP] ${ch.channelName}: pyramid returned 0 points (tMin=$tMin tMax=$tMax dataLen=${ch.data.length})');
        ch.viewportData.clear();
        ch.envelopeData.clear();
        continue;
      }"""
content = content.replace(old_fb_block, new_fb_block)

# ── P2-1: Remove _fallbackViewportData method ──
old_fallback = """  /// 🚀 Phase C TODO: Remove this fallback method once per-channel pyramid is proven stable.
  /// Fallback viewport extraction: binary search + step decimation on raw data.
  /// Used when per-channel pyramid has not been populated yet.
  List<_DataPoint> _fallbackViewportData(PlotChannel ch, double newestAbsX,
      double targetMin, double targetMax, int maxPts) {
    int startIdx = _binarySearch(ch.data, targetMin);
    int endIdx = _binarySearch(ch.data, targetMax) + 1;
    startIdx = startIdx.clamp(0, ch.data.length);
    endIdx = endIdx.clamp(startIdx, ch.data.length);
    if (startIdx >= endIdx) return [];

    final visible = ch.data.sublist(startIdx, endIdx);
    if (visible.isEmpty) return [];

    final plotWidth = _plotWidth();
    final density = visible.length / plotWidth;

    if (density > 0.5) {
      final targetPoints = plotWidth.round().clamp(100, 1000);
      final step = (visible.length / targetPoints).ceil().clamp(1, visible.length);
      return [for (int i = 0; i < visible.length; i += step)
        _DataPoint(visible[i].x - newestAbsX, visible[i].y)];
    } else {
      return visible.map((pt) => _DataPoint(pt.x - newestAbsX, pt.y)).toList();
    }
  }"""

content = content.replace(old_fallback, '')
if old_fallback in content:
    print('WARNING: _fallbackViewportData not found!')

# ── P0-3: Remove _updateRealDataUI and its helper fields ──
# First, find _updateRealDataUI and its vars
old_ui_pass = """  DateTime _lastUIUpdate = DateTime.now();
  DateTime _lastFetchEnd = DateTime.now(); // 🩺 Diagnostic: track _fetchRealData completion time

  void _updateRealDataUI() {
    if (!_useRealData || !mounted || !_isPlaying) return;

    // 策略 A: UI 节流，每 33ms（约 30fps）更新一次
    final now = DateTime.now();
    if (now.difference(_lastUIUpdate).inMilliseconds < 33) return;
    _lastUIUpdate = now;

    // 🩺 Diagnostic: measure time since last _fetchRealData call ended
    if (_frameCount % 60 == 0 && _useRealData) {
      final elapsed = now.difference(_lastFetchEnd).inMilliseconds;
      if (elapsed > 60) {
        if (_verbose) print('[DIAG-TIMER] _fetchRealData → _updateRealDataUI gap: ${elapsed}ms (frame $_frameCount)');
      }
    }

    // Update X axis range
    if (_scrollMode) {
      // Newest data at x=0, auto-track
      _xMax = 0.0;
      // For real data, limit scroll window to actual data length
      double effectiveWidth = _effectiveScrollWindowWidth;
      if (_useRealData && _channels.isNotEmpty) {
        final maxDataLen = _channels.map((c) => c.data.length).fold(0, (a, b) => a > b ? a : b);
        if (maxDataLen > 0 && maxDataLen < effectiveWidth) {
          effectiveWidth = maxDataLen.toDouble();
        }
      }
      _xMin = -effectiveWidth;
      _scrollMinTime = _xMin;
    }

    // Fetch ChartViewport data for visible channels FIRST
    // 统一使用 _refreshViewportData() 处理 Demo 和 Real 模式
    _refreshViewportData();

    // Fit Y axis AFTER refreshing viewport data (must use fresh data)
    if (_autoScaleY) {
      _fitYAxis();
    }
    if (!_scrollMode && _autoScaleX) {
      _fitXAxis();
    }

    // CPU 渲染路径
    setState(() {});
  }"""

content = content.replace(old_ui_pass, '')

# Remove _lastFetchEnd assignment in _fetchRealData
content = content.replace("    _lastFetchEnd = DateTime.now();\n", "")

# Remove _updateRealDataUI() calls from startRealData
content = content.replace("      _updateRealDataUI();\n", "")

# Remove the comment about _updateRealDataUI
content = content.replace("    // _updateRealDataUI 内部保留 33ms 节流，控制实际 UI 刷新率\n", "")

with open(path, 'w', encoding='utf-8-sig', newline='\r\n') as f:
    f.write(content)

print('All replacements applied!')
