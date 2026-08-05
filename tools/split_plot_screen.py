#!/usr/bin/env python3
"""Split plot_screen.dart into logical part files."""
import os

base = r'D:\AI\upper_computer_tools\VCR\lib\screens'
path = os.path.join(base, 'plot_screen.dart')

with open(path, 'r', encoding='utf-8-sig') as f:
    lines = f.readlines()

# ── Line ranges for each part file ──
# L1-L31:  imports + header comment + part directives
# L32-L378: state fields (up to the blank line before initState)
# L379-L439: initState (extends to just before _ensureAnalogSegments)

# Define split boundaries
# Part 1: plot_state.dart — fields L32-L378 + initState L379-L439
# Part 2: plot_lifecycle.dart — dispose + config + GPU (L1580-L1798)
#   Note: _ensureAnalogSegments (L440) through _onTick end (L1578) = data layer
# Part 3: plot_data.dart — data+timers+toggles+fit (L440-L1578 + L2073-L2153 channels + L1875-L2072 import/export + L2153-L2302 scroll + pyramid debug)
# Part 4: plot_ui.dart — build() + dialogs L2303-L3726
# Part 5: remaining methods not covered above but part of _PlotScreenState

# Let me be more careful. I'll define exact ranges.
# 
# plot_state.dart:    L32-L451   (fields 32-378, initState 379-439, _ensureAnalogSegments 440-451)
# plot_timers.dart:   L452-L632  (_initDemoChannels, _startDemoData, _debugLog, _notifyPipelineViewport + all data refresh methods)
# plot_data.dart:     L633-L1016 (_debugLog through _refreshViewportFromAnalogImpl)
# plot_dispatch.dart: L1017-L1578 (_fetchRealData, _startRealData, toggles, fit, _onTick)
# plot_lifecycle.dart: L1580-L1798 (dispose, _load/saveConfig, _setAALevel, _initGpu, _renderWaveformOnGpu)
# plot_io.dart:        L1875-L2302 (_clearData, _exportCsv, _importCsv, channels, groups, scroll, pyramid debug)
# plot_ui.dart:        L2303-L3726 (build + all dialogs)

# Actually, too many files is worse. Let me do a cleaner split:
# 
# plot_state.dart:     L32-L439   — fields + initState (the core state)
# plot_data_pipeline.dart: L440-L1578 — ALL data logic (analog segments, demo, real, refresh, toggles, fit, onTick)
# plot_config.dart:    L1580-L1798 — lifecycle (dispose, config load/save, AA, GPU)
# plot_actions.dart:   L1875-L2302 — clear/export/import, channels, groups, scroll, pyramid
# plot_ui.dart:        L2303-L3726 — build() + all dialogs
# plot_screen.dart:    ~120 lines skeleton — imports, class header, part directives

# However, some methods cross our boundaries (e.g. L440 _ensureAnalogSegments is tightly coupled with initState).
# Let me just do 4 part files: state, data, lifecycle, ui. That's clean enough.

# First, let's find the exact end of initState
init_end = None
for i in range(379, 460):
    if lines[i].strip() == '}' and not lines[i].strip().startswith('//'):
        # Check if this is the closing brace of initState
        indent = len(lines[i]) - len(lines[i].lstrip())
        if indent == 2:  # Two spaces = method-level closing
            init_end = i + 1
            break

if init_end is None:
    print("ERROR: Could not find end of initState")
    exit(1)
print(f"initState ends at L{init_end}: {lines[init_end-1].strip()}")

# Now let me find the structure:
# L32: class _PlotScreenState {
# ... fields ...
# L378: blank before initState
# L379: @override
# L380: void initState() {
# L439: } (end of initState)
# L440: void _ensureAnalogSegments()
# L451: } (end of _ensureAnalogSegments)
# L452: void _initDemoChannels()
# ...
# L1578: } (end of _onTick)
# L1579: blank
# L1580: @override
# L1581: void dispose()
# ...
# L1798: } (end of _renderWaveformOnGpu with try/catch)
# L1799-L1874: mixed (some fields, some methods)
# L1875: void _clearData()
# ...
# L2302: end of _showPyramidDebug
# L2303: // Build UI
# L2305: @override
# L2306: Widget build
# ...
# L3725-3726: closing of build, closing of class

# Let me check exact lines
print(f"\nChecking key line markers:")
for check_ln in [439, 451, 547, 1016, 1147, 1578, 1798, 1874, 2302, 3345, 3580, 3610, 3726]:
    if check_ln <= len(lines):
        print(f"  L{check_ln}: {lines[check_ln-1].rstrip()[:90]}")

# Check what L1799-L1874 contains
print("\nL1799-L1874 region:")
for i in range(1798, min(1875, len(lines))):
    s = lines[i].rstrip()
    if s.strip():
        print(f"  L{i+1}: {s[:100]}")

