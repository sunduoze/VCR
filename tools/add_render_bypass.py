#!/usr/bin/env python3
"""Add _renderBypass master kill-switch to plot_screen.dart"""
import sys

path = r'D:\AI\upper_computer_tools\VCR\lib\screens\plot_screen.dart'

with open(path, 'r', encoding='utf-8-sig') as f:
    content = f.read()

edits_applied = 0

# Edit 1: Add _renderBypass field after _pyramidDebugText
old = '\n  // Render mode: auto (threshold-based), trace (always raw polyline), envelope (always min-max band)\n  _RenderMode _renderMode = _RenderMode.auto;\n  String _pyramidDebugText = \'\';\n\n  // \u2500\u2500 Pipeline thread toggle \u2500\u2500'
new = '\n  // Render mode: auto (threshold-based), trace (always raw polyline), envelope (always min-max band)\n  _RenderMode _renderMode = _RenderMode.auto;\n  String _pyramidDebugText = \'\';\n\n  // \u2500\u2500 Render Bypass: master kill-switch for ALL envelope/pipeline/analog rendering \u2500\u2500\n  // When ON: skip pipeline thread, skip AnalogSegment, skip TimeBucketPyramid envelope,\n  // force pure trace rendering. Underlying _pipelineEnabled/_analogEnvelopeEnabled\n  // are NOT modified \u2014 toggling OFF restores previous state.\n  bool _renderBypass = false;\n\n  // \u2500\u2500 Pipeline thread toggle \u2500\u2500'
if old in content:
    content = content.replace(old, new)
    edits_applied += 1
else:
    print("ERROR: Edit 1 not found!")
    # Try to find what's there
    idx = content.find('_RenderMode _renderMode')
    if idx >= 0:
        print('  Context around match:', repr(content[max(0,idx-20):idx+200]))
    sys.exit(1)

# Edit 2: In _refreshViewportData, guard pipeline/analog envelope branches
old = '  void _refreshViewportData() {\n    if (_xMin == _xMax || _screenWidth <= 0) return;\n\n    // FIXED(P0)-4: Zero-copy envelope read (pre-computed by Rust pipeline thread).\n    // When pipeline is enabled, try envelope read first; fall back to pyramid query on failure.\n    if (_pipelineEnabled) {\n      if (_refreshViewportDataFromEnvelope()) return;\n      if (_refreshViewportFromAnalog()) return;\n    } else if (_analogEnvelopeEnabled) {\n      // AnalogSegment direct C-ABI path (works without pipeline thread).\n      if (_refreshViewportFromAnalog()) return;\n    }\n\n    // Fallback: per-channel pyramid query (always active)'
new = '  void _refreshViewportData() {\n    if (_xMin == _xMax || _screenWidth <= 0) return;\n\n    // RENDER_BYPASS: when bypass is ON, skip ALL envelope/pipeline/analog paths;\n    // go directly to the per-channel pyramid query (TimeBucketPyramid) fallback.\n    if (!_renderBypass) {\n      // FIXED(P0)-4: Zero-copy envelope read (pre-computed by Rust pipeline thread).\n      // When pipeline is enabled, try envelope read first; fall back to pyramid query on failure.\n      if (_pipelineEnabled) {\n        if (_refreshViewportDataFromEnvelope()) return;\n        if (_refreshViewportFromAnalog()) return;\n      } else if (_analogEnvelopeEnabled) {\n        // AnalogSegment direct C-ABI path (works without pipeline thread).\n        if (_refreshViewportFromAnalog()) return;\n      }\n    }\n\n    // Fallback: per-channel pyramid query (always active)'
if old in content:
    content = content.replace(old, new)
    edits_applied += 1
else:
    print("ERROR: Edit 2 not found!")
    idx = content.find('void _refreshViewportData()')
    if idx >= 0:
        print('  Context around match:', repr(content[idx:idx+500]))
    sys.exit(1)

# Edit 3: In _onTick real-data branch, skip _notifyPipelineViewport when bypass
old = '      if (_useRealData) {\n        if (_pipelineEnabled) _notifyPipelineViewport(); // Feed viewport BEFORE refresh \u2192 pipeline computes async'
new = '      if (_useRealData) {\n        if (_pipelineEnabled && !_renderBypass) _notifyPipelineViewport(); // Feed viewport BEFORE refresh \u2192 pipeline computes async'
if old in content:
    content = content.replace(old, new)
    edits_applied += 1
else:
    print("ERROR: Edit 3 not found!")
    idx = content.find('_pipelineEnabled) _notifyPipelineViewport')
    if idx >= 0:
        print('  Context around match:', repr(content[max(0,idx-50):idx+150]))
    sys.exit(1)

# Edit 4: In _onTick demo branch, skip _notifyPipelineViewport when bypass
old = '      } else {\n        if (_pipelineEnabled) _notifyPipelineViewport(); // Feed viewport BEFORE refresh'
new = '      } else {\n        if (_pipelineEnabled && !_renderBypass) _notifyPipelineViewport(); // Feed viewport BEFORE refresh'
if old in content:
    content = content.replace(old, new)
    edits_applied += 1
else:
    print("ERROR: Edit 4 not found!")
    idx = content.find('_pipelineEnabled) _notifyPipelineViewport(); // Feed viewport BEFORE refresh\n        if (!_scrollMode')
    if idx < 0:
        idx = content.find('_notifyPipelineViewport')
    if idx >= 0:
        print('  Context around match:', repr(content[max(0,idx-50):idx+150]))
    sys.exit(1)

# Edit 5: Insert _toggleRenderBypass method before _togglePipeline
old = '  void _togglePipeline() {'
new = '  /// Master kill-switch: disable ALL envelope/pipeline/analog rendering paths.\n  /// When enabled: stops pipeline thread, disables AnalogSegment envelope push,\n  /// forces pure trace rendering. Underlying flags are preserved for restore.\n  void _toggleRenderBypass() {\n    setState(() {\n      _renderBypass = !_renderBypass;\n      if (_renderBypass) {\n        // \u2500\u2500 Shutdown: stop pipeline, disable analog envelope \u2500\u2500\n        if (_pipelineEnabled) {\n          FfiBridge.instance.stopPipeline();\n        }\n        FfiBridge.instance.analogSetEnvelopeEnabled(false);\n      } else {\n        // \u2500\u2500 Restore: re-enable pipeline + analog envelope per saved state \u2500\u2500\n        FfiBridge.instance.analogSetEnvelopeEnabled(_analogEnvelopeEnabled);\n        if (_pipelineEnabled) {\n          FfiBridge.instance.startPipeline();\n          _ensureAnalogSegments();\n        }\n      }\n    });\n    _saveConfig();\n  }\n\n  void _togglePipeline() {'
if old in content:
    content = content.replace(old, new)
    edits_applied += 1
else:
    print("ERROR: Edit 5 not found!")
    idx = content.find('_togglePipeline()')
    if idx >= 0:
        print('  Context around match:', repr(content[max(0,idx-20):idx+60]))
    sys.exit(1)

# Edit 6: Add toolbar button after AnalogSegment envelope toggle button
needle = '            tooltip: _analogEnvelopeEnabled ? \'Analog Envelope ON (f32 pyramid)\' : \'Analog Envelope OFF (f64)\',\n          ),\n          // Pyramid Debug'
if needle in content:
    replacement = '            tooltip: _analogEnvelopeEnabled ? \'Analog Envelope ON (f32 pyramid)\' : \'Analog Envelope OFF (f64)\',\n          ),\n          // \u2500\u2500 Master Render Bypass \u2500\u2500 disables ALL envelope/pipeline/analog rendering\n          IconButton(\n            icon: Container(\n              padding: const EdgeInsets.all(4),\n              decoration: BoxDecoration(\n                color: _renderBypass ? Colors.red.withValues(alpha: 0.25) : AppTheme.surfaceVariant,\n                borderRadius: BorderRadius.circular(4),\n              ),\n              child: Icon(\n                _renderBypass ? Icons.block : Icons.block_outlined,\n                color: _renderBypass ? Colors.red : AppTheme.textSecondary,\n                size: 20,\n              ),\n            ),\n            onPressed: _toggleRenderBypass,\n            tooltip: _renderBypass ? \'BYPASS ON (all envelope/pipeline disabled)\' : \'Render Bypass OFF (normal)\',\n          ),\n          // Pyramid Debug'
    content = content.replace(needle, replacement)
    edits_applied += 1
else:
    print("ERROR: Edit 6 not found!")
    idx = content.find("Analog Envelope ON (f32 pyramid)")
    if idx >= 0:
        print('  Context around match:', repr(content[max(0,idx-100):idx+250]))
    sys.exit(1)

# Edit 7: Save renderBypass in config
old = "        'analogEnvelopeEnabled': _analogEnvelopeEnabled,"
new = "        'analogEnvelopeEnabled': _analogEnvelopeEnabled,\n        'renderBypass': _renderBypass,"
if old in content:
    content = content.replace(old, new)
    edits_applied += 1
else:
    print("ERROR: Edit 7 not found!")
    idx = content.find("'analogEnvelopeEnabled': _analogEnvelopeEnabled")
    if idx >= 0:
        print('  Context around match:', repr(content[max(0,idx-50):idx+100]))
    sys.exit(1)

# Edit 8: Load renderBypass from config
old = "        _analogEnvelopeEnabled = json['analogEnvelopeEnabled'] as bool? ?? true;"
new = "        _analogEnvelopeEnabled = json['analogEnvelopeEnabled'] as bool? ?? true;\n        _renderBypass = json['renderBypass'] as bool? ?? false;"
if old in content:
    content = content.replace(old, new)
    edits_applied += 1
else:
    print("ERROR: Edit 8 not found!")
    idx = content.find("analogEnvelopeEnabled'] as bool?")
    if idx >= 0:
        print('  Context around match:', repr(content[max(0,idx-50):idx+100]))
    sys.exit(1)

# Edit 9: On config load restore, handle bypass state
old = "        if (_analogEnvelopeEnabled) {\n          FfiBridge.instance.analogSetEnvelopeEnabled(true);\n          _ensureAnalogSegments();\n          // Auto-start pipeline if analog envelope needs it\n          if (!_pipelineEnabled) {\n            _pipelineEnabled = true;\n            FfiBridge.instance.startPipeline();\n          }\n        }\n      }"
new = "        if (_analogEnvelopeEnabled) {\n          FfiBridge.instance.analogSetEnvelopeEnabled(true);\n          _ensureAnalogSegments();\n          // Auto-start pipeline if analog envelope needs it\n          if (!_pipelineEnabled) {\n            _pipelineEnabled = true;\n            FfiBridge.instance.startPipeline();\n          }\n        }\n        // Restore render bypass state: if bypass was saved as ON, shut everything down\n        if (_renderBypass) {\n          if (_pipelineEnabled) {\n            FfiBridge.instance.stopPipeline();\n          }\n          FfiBridge.instance.analogSetEnvelopeEnabled(false);\n        }\n      }"
if old in content:
    content = content.replace(old, new)
    edits_applied += 1
else:
    print("ERROR: Edit 9 not found!")
    idx = content.find("_ensureAnalogSegments();")
    if idx >= 0:
        # find the containing block
        start = max(0, idx-300)
        print('  Context around match:', repr(content[start:idx+200]))
    sys.exit(1)

# Write back
with open(path, 'w', encoding='utf-8-sig', newline='\r\n') as f:
    f.write(content)

print(f'SUCCESS: {edits_applied}/9 edits applied')
