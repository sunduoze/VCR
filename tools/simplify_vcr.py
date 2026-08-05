#!/usr/bin/env python3
"""
Precision patch for plot_screen.dart after Rust-side simplification.
Removes FfiBridge/CDataPoint/CEnvelopeSample/pipeline/analog/envelope/renderMode references,
replaces _refreshViewportData with Min-Max pixel decimation.
"""
import os, re

path = r"D:\AI\upper_computer_tools\VCR\lib\screens\plot_screen.dart"
with open(path, "r", encoding="utf-8-sig") as f:
    lines = f.readlines()

total_orig = len(lines)

# ─── Build output line by line ───
out = []
i = 0
def skip_to_end_of_braceblock():
    """Skip lines from current position to end of a {}-delimited block"""
    global i
    depth = 1
    i += 1
    while i < len(lines):
        depth += lines[i].count('{') - lines[i].count('}')
        if depth <= 0:
            i += 1
            return
        i += 1

def at_line(s):
    return lines[i].strip() == s

def strip_start(text):
    return lines[i].strip().startswith(text)

while i < total_orig:
    li = lines[i]
    s = li.strip()

    # ── 1. Remove ffi_bridge import ──
    if s == "import '../core/ffi_bridge.dart';":
        i += 1; continue

    # ── 2. Remove package:ffi import (calloc) ──
    if s == "import 'package:ffi/ffi.dart' show calloc;":
        i += 1; continue

    # ── 3. Remove _RenderMode enum ──
    if s == 'enum _RenderMode {':
        skip_to_end_of_braceblock()
        continue

    # ── 4. Remove fields ──
    skip_fields = [
        '_RenderMode _renderMode = _RenderMode.auto;',
        "String _pyramidDebugText = '';",
        '// Render mode: auto (threshold-based), trace (always raw polyline), envelope (always min-max band)',
        '// ── Pipeline thread toggle ──',
        '// Delegated to _activeDevice',
        'bool get _pipelineEnabled => _activeDevice.pipelineEnabled;',
        'set _pipelineEnabled(bool v) => _activeDevice.pipelineEnabled = v;',
        '// ── AnalogSegment envelope toggle ──',
        'bool get _analogEnvelopeEnabled => _activeDevice.analogEnvelopeEnabled;',
        'set _analogEnvelopeEnabled(bool v) => _activeDevice.analogEnvelopeEnabled = v;',
        '// NOTE: Phase C: Reusable query buffers (allocated once, resized lazily)',
        'Float64List? _queryBuffer;        // Reusable Float64List for _refreshViewportData',
        'Pointer<CDataPoint>? _queryNative; // Reusable native buffer for FFI queries',
        'int _queryNativeCap = 0;           // Current native buffer capacity (in CDataPoint elements)',
    ]
    if s in skip_fields:
        i += 1; continue

    # ── 5. Remove comment blocks ──
    if s.startswith('// Must be AFTER _loadConfig (saved config may overwrite _analogEnvelopeEnabled=false)') or \
       s.startswith('//   _ensureAnalogSegments → _initDemoChannels') or \
       s.startswith('// NOTE: Clear BOTH pyramid data stores on data reset.') or \
       s.startswith('// - FFI_CH_PYRAMIDS (TimeBucketPyramid):') or \
       s.startswith('// - FFI_CH_ANALOG (AnalogSegment):') or \
       s.startswith('// Without clearing both, _refreshViewportFromAnalogImpl picks up stale') or \
       s.startswith('// AnalogSegment data (old 250K sample indices) in the new [-1000,0] viewport.') or \
       s.startswith('// The old absolute indices don') or \
       s.startswith('// → waveform appears compressed'):
        i += 1; continue

    # ── 6. Remove standalone calls ──
    if s == '_ensureAnalogSegments();' or s == '_notifyPipelineViewport();':
        i += 1; continue
    if s == 'if (_pipelineEnabled) _notifyPipelineViewport();  // Feed viewport BEFORE refresh → pipeline computes' or \
       s == 'if (_pipelineEnabled) _notifyPipelineViewport(); // Feed viewport BEFORE refresh':
        i += 1; continue

    # ── 7. Remove FfiBridge/CDataPoint/CEnvelopeSample references ──
    if 'FfiBridge' in li:
        i += 1; continue
    if 'CDataPoint' in li or 'CEnvelopeSample' in li:
        i += 1; continue
    if s.startswith('bridge.analog') or s.startswith('bridge.envelope') or s.startswith('bridge.query'):
        i += 1; continue

    # ── 8. Remove _pipelineEnabled / _analogEnvelopeEnabled assignment lines ──
    if s in (
        '_pipelineEnabled = true;', '_pipelineEnabled = false;',
        '_analogEnvelopeEnabled = true;', '_analogEnvelopeEnabled = false;',
        "_pipelineEnabled = json['pipelineEnabled'] as bool? ?? false;",
        "_analogEnvelopeEnabled = json['analogEnvelopeEnabled'] as bool? ?? true;",
        "// NOTE: Force true — _ensureAnalogSegments() runs before _loadConfig",
        "'pipelineEnabled': _pipelineEnabled,",
        "'analogEnvelopeEnabled': _analogEnvelopeEnabled,",
        '_pipelineEnabled = !_pipelineEnabled;',
        '_analogEnvelopeEnabled = !_analogEnvelopeEnabled;',
        'renderMode: _renderMode,',
    ):
        i += 1; continue

    # ── 9. Remove methods ──
    if strip_start('void _ensureAnalogSegments()') or \
       strip_start('void _notifyPipelineViewport()') or \
       strip_start('bool _refreshViewportDataFromEnvelope()') or \
       strip_start('bool _refreshViewportFromAnalog()') or \
       strip_start('bool _refreshViewportFromAnalogImpl()'):
        skip_to_end_of_braceblock()
        continue

    # ── 10. Remove // ── AnalogSegment ... comment lines ──
    if s.startswith('// ── AnalogSegment envelope read') or \
       s.startswith('// Called when _analogEnvelopeEnabled') or \
       s.startswith('// Reads per-channel envelope from AnalogSegment') or \
       s.startswith('// When samplesPerPixel') or \
       s.startswith('/// Query AnalogSegment per-channel') or \
       s.startswith('/// Iterates _channels directly') or \
       s.startswith('// FIXED(P0)-4: Zero-copy envelope read') or \
       s.startswith('// When pipeline is enabled, try envelope') or \
       s.startswith('// AnalogSegment direct C-ABI path') or \
       s.startswith('// Fallback: per-channel pyramid query') or \
       s.startswith('// NOTE: Reusable Float64List buffer') or \
       s.startswith('// NOTE: Phase C: Reuse native CDataPoint'):
        i += 1; continue

    # ── 11. Skip if (_pipelineEnabled) / if (_analogEnvelopeEnabled) blocks ──
    if s == 'if (_pipelineEnabled) {' or s == 'if (_analogEnvelopeEnabled) {' or \
       s == 'if (!_analogEnvelopeEnabled) {' or s == 'if (!_pipelineEnabled) {':
        skip_to_end_of_braceblock()
        continue

    # ── 12. Skip toolbar button blocks ──
    if s in (
        '// Render mode toggle (Auto → Trace → Envelope)',
        '// ── Render mode toggle (trace ↔ auto ↔ envelope) ──',
        '// Pipeline toggle (pre-computed envelope)',
        '// ── Pipeline toggle ──',
        '// AnalogSegment envelope toggle (f32 10-level 16^n pyramid)',
        '// ── Analog envelope toggle ──',
    ):
        i += 1
        # skip until next // ── or ] or empty
        while i < len(lines):
            ns = lines[i].strip()
            if ns.startswith('// ──') or ns.startswith('],') or ns == '],':
                break
            i += 1
        continue

    # ── 13. Skip calloc.free / _queryNative cleanup in dispose ──
    if s in (
        'calloc.free(_queryNative!);',
        'if (_queryNative != null) {',
        '_queryNative = null;',
        '_queryNativeCap = 0;',
    ):
        i += 1; continue

    # ── 14. Remove standalone calloc references ──
    if 'calloc<' in li:
        i += 1; continue

    # ── 15. Skip individual toolbar button refs ──
    if '_renderMode' in s and ('Icons.' in s or 'tooltip' in s or '_renderMode.index' in s or '_renderMode.name' in s or '_renderMode.values' in s):
        i += 1; continue
    if '_pipelineEnabled' in s and ('Icons.' in s or 'tooltip' in s or 'AppTheme.' in s):
        i += 1; continue
    if '_analogEnvelopeEnabled' in s and ('Icons.' in s or 'tooltip' in s or 'AppTheme.' in s):
        i += 1; continue

    # ── 16. Replace _refreshViewportData ──
    if strip_start('void _refreshViewportData()'):
        # Skip the entire old method
        skip_to_end_of_braceblock()
        # Insert new version
        new_impl = [
            '  /// Min-Max pixel decimation: each screen pixel column gets the min+max\n',
            '  /// of all data points in that column. Preserves peak detail (no spike loss)\n',
            '  /// while reducing 1M points → ~4000 drawing primitives per channel.\n',
            '  void _refreshViewportData() {\n',
            '    if (_xMin == _xMax || _screenWidth <= 0) return;\n',
            '\n',
            '    final w = _screenWidth.round().clamp(1, 4096);\n',
            '\n',
            '    for (int ci = 0; ci < _channels.length; ci++) {\n',
            '      final ch = _channels[ci];\n',
            '      if (!ch.visible || ch.data.isEmpty) {\n',
            '        ch.viewportData.clear();\n',
            '        ch.envelopeData.clear();\n',
            '        continue;\n',
            '      }\n',
            '\n',
            '      final total = ch.data.length;\n',
            '      final step = (total / w).ceil().clamp(1, total);\n',
            '      final newestAbsX = ch.data.last.x;\n',
            '\n',
            '      ch.viewportData.clear();\n',
            '      ch.envelopeData.clear();\n',
            '\n',
            '      for (int x = 0; x < w; x++) {\n',
            '        final start = x * step;\n',
            '        final end = (start + step).clamp(0, total);\n',
            '        if (start >= total) break;\n',
            '\n',
            '        double curMin = ch.data[start].y;\n',
            '        double curMax = ch.data[start].y;\n',
            '        for (int i2 = start + 1; i2 < end; i2++) {\n',
            '          final v = ch.data[i2].y;\n',
            '          if (v < curMin) curMin = v;\n',
            '          if (v > curMax) curMax = v;\n',
            '        }\n',
            '\n',
            '        final xRel = ch.data[end - 1].x - newestAbsX;\n',
            '        ch.viewportData.add(xRel, (curMin + curMax) * 0.5);\n',
            '        ch.envelopeData.add(xRel, curMin);\n',
            '        ch.envelopeData.add(xRel, curMax);\n',
            '      }\n',
            '    }\n',
            '    _viewportRefreshCount++;\n',
            '  }\n',
        ]
        out.extend(new_impl)
        continue

    # ── Default: keep ──
    out.append(li)
    i += 1

# Collapse runs of >2 blank lines
result = []
blank_run = 0
for line in out:
    if line.strip() == '':
        blank_run += 1
        if blank_run <= 2:
            result.append(line)
    else:
        blank_run = 0
        result.append(line)

content = ''.join(result)
with open(path, "w", encoding="utf-8-sig", newline='\r\n') as f:
    f.write(content)

new_total = content.count('\n')
print(f"Lines: {total_orig} -> {new_total} (-{total_orig - new_total})")

# Sanity checks
checks = ['FfiBridge', 'CDataPoint', 'CEnvelopeSample', '_ensureAnalogSegments',
          '_pipelineEnabled', '_analogEnvelopeEnabled', '_renderMode',
          '_notifyPipelineViewport', '_refreshViewportDataFromEnvelope', '_refreshViewportFromAnalog',
          'calloc', "import 'package:ffi/ffi.dart'", "import '../core/ffi_bridge.dart'"]
for c in checks:
    if c in content:
        print(f"  ⚠ REMAINING: {c}")
if '_refreshViewportData' not in content:
    print(f"  ❌ MISSING: _refreshViewportData")
else:
    print(f"  ✅ _refreshViewportData present")
