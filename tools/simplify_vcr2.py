#!/usr/bin/env python3
"""Second pass: remove remaining pipeline/envelope/analog/FFI/CDataPoint references."""
import os

path = r"D:\AI\upper_computer_tools\VCR\lib\screens\plot_screen.dart"
with open(path, "r", encoding="utf-8-sig") as f:
    lines = f.readlines()

out = []
i = 0
total = len(lines)

def skip_block():
    """Skip a { ... } block starting from current line (brace already opened)."""
    global i
    depth = lines[i].count('{') - lines[i].count('}')
    if depth <= 0:
        depth = 1
        i += 1
    else:
        i += 1
    while i < total:
        depth += lines[i].count('{') - lines[i].count('}')
        if depth <= 0:
            i += 1
            return
        i += 1

def skip_if_block():
    """If current line starts an if block, skip the entire block."""
    global i
    depth = lines[i].count('{') - lines[i].count('}')
    if depth > 0:
        i += 1
    else:
        # Open brace on next line?
        i += 1
        if i < total and lines[i].strip() == '{':
            depth = 1
            i += 1
        else:
            return False
    while i < total and depth > 0:
        depth += lines[i].count('{') - lines[i].count('}')
        i += 1
    return True

while i < total:
    line = lines[i]
    s = line.strip()

    # ─── A. Remove query buffer fields ───
    if s.startswith('// NOTE: Phase C: Reusable query') or \
       s.startswith('Float64List? _queryBuffer;') or \
       s.startswith('Pointer<CDataPoint>? _queryNative;') or \
       s.startswith('int _queryNativeCap = 0;'):
        i += 1; continue

    # ─── B. Remove comments about analog/pipeline ───
    if s.startswith('// Must be AFTER _loadConfig (saved config may overwrite _analogEnvelopeEnabled') or \
       s.startswith('//   _ensureAnalogSegments → _initDemoChannels → Demo'):
        i += 1; continue

    # ─── C. Remove calloc.free in dispose ───
    if s.startswith('calloc.free(_queryNative!);') or \
       s.startswith('if (_queryNative != null) {') or \
       s.startswith('_queryNative = null;') or \
       s.startswith('_queryNativeCap = 0;') or \
       s == '}':
        # Check context: if this is part of _queryNative cleanup
        # Safer: only skip if preceded by calloc.free or _queryNative related
        prev = lines[i-1].strip() if i > 0 else ''
        if 'calloc.free(_queryNative' in prev or '_queryNative != null' in prev:
            out[-1] = ''  # remove previous line too
            i += 1; continue
        # Skip calloc.free directly
        if 'calloc.free(_queryNative' in s:
            # prev should also be removed (the if check)
            if i > 0 and '_queryNative != null' in lines[i-1]:
                out[-1] = ''
            i += 1; continue

    # ─── D. Remove _pipelineEnabled = !_pipelineEnabled block ───
    if s == '_pipelineEnabled = !_pipelineEnabled;':
        # Remove the whole if-block that contains this
        # Go back and remove from the nearest 'if (_pipelineEnabled)' or enclosing block
        # Actually this is inside a toggle handler. Remove the whole handler.
        # Find the GestureDetector or IconButton that wraps this
        # Simpler: just skip this line and the next few until we hit }
        i += 1; continue

    if s == '_analogEnvelopeEnabled = !_analogEnvelopeEnabled;':
        i += 1; continue

    # ─── E. Remove _loadConfig pipeline/analog assign ───
    if s in (
        "_pipelineEnabled = json['pipelineEnabled'] as bool? ?? false;",
        "_analogEnvelopeEnabled = json['analogEnvelopeEnabled'] as bool? ?? true;",
        "// NOTE: Force true — _ensureAnalogSegments() runs before _loadConfig",
    ):
        i += 1; continue

    # ─── F. Remove if (!_analogEnvelopeEnabled) block in _loadConfig ───
    if s.startswith('if (!_analogEnvelopeEnabled)'):
        i += 1; continue
    if s == '_analogEnvelopeEnabled = true;' or s == '_analogEnvelopeEnabled = false;':
        i += 1; continue

    # ─── G. Remove _saveConfig pipeline/analog entries ───
    if s == "'pipelineEnabled': _pipelineEnabled," or \
       s == "'analogEnvelopeEnabled': _analogEnvelopeEnabled,":
        i += 1; continue

    # ─── H. Remove renderMode: _renderMode in PlotPainter constructor ───
    if s == 'renderMode: _renderMode,':
        i += 1; continue

    # ─── I. Remove render mode toolbar button block (lines ~1960-1990) ───
    # These use _renderMode — skip until we see the next button or section end
    if s == '// ── Render mode toggle (trace ↔ auto ↔ envelope) ──':
        # Skip until next // ── or ] token
        i += 1
        while i < total:
            ns = lines[i].strip()
            if ns.startswith('// ──') or ns.startswith('],') or ns == '],':
                break
            i += 1
        continue

    # ─── J. Remove pipeline toggle toolbar button (~1995-2007) ───
    if s == '// ── Pipeline toggle ──':
        i += 1
        while i < total:
            ns = lines[i].strip()
            if ns.startswith('// ──') or ns.startswith('],') or ns == '],':
                break
            i += 1
        continue

    # ─── K. Remove analog envelope toggle toolbar button (~2012-2024) ───
    if s == '// ── Analog envelope toggle ──':
        i += 1
        while i < total:
            ns = lines[i].strip()
            if ns.startswith('// ──') or ns.startswith('],') or ns == '],':
                break
            i += 1
        continue

    # ─── L. Remove // ── Pipeline enabled handler ── sections ───
    if s.startswith('// ── Pipeline enabled: toggle pipeline') or \
       s.startswith('// ── Analog envelope enabled') or \
       s.startswith('// ── When pipeline turns on') or \
       s.startswith('// ── When analog envelope turns on'):
        i += 1
        while i < total:
            ns = lines[i].strip()
            if ns.startswith('//'): break  # keep going
            if ns == '}' or ns == '':
                i += 1; break
            i += 1
        continue

    # ─── M. Remove standalone _pipelineEnabled / _analogEnvelopeEnabled setters ───
    if s in (
        '_pipelineEnabled = true;',
        '_pipelineEnabled = false;',
        '_analogEnvelopeEnabled = true;',
        '_analogEnvelopeEnabled = false;',
        '_pipelineEnabled = !_pipelineEnabled;',
        '_analogEnvelopeEnabled = !_analogEnvelopeEnabled;',
    ):
        i += 1; continue

    # ─── N. Remove if (analogEnvelopeEnabled) blocks in various places ───
    if s == 'if (_analogEnvelopeEnabled) {' or s == 'if (_pipelineEnabled) {':
        skip_block()
        continue

    # ─── O. Remove _renderMode references in toolbar UI (lines 1963+) ───
    # These were inside the render mode button block which we already skip-markered
    # But the block might not have been fully skipped. Handle stray lines:
    if '_renderMode' in s and ('color:' in s or 'tooltip:' in s or '_renderMode.index' in s or '_renderMode.name' in s or 'Icons.' in s):
        # These are part of the toolbar button body — skip
        i += 1; continue

    # ─── P. Remove _pipelineEnabled button references ───
    if '_pipelineEnabled' in s and ('color:' in s or 'tooltip:' in s or 'Icons.' in s):
        i += 1; continue

    # ─── Q. Remove _analogEnvelopeEnabled button references ───
    if '_analogEnvelopeEnabled' in s and ('color:' in s or 'tooltip:' in s or 'Icons.' in s):
        i += 1; continue

    # ─── Keep the line ───
    out.append(line)
    i += 1

# Collapse multiple blank lines (max 2)
result = []
blank_count = 0
for line in out:
    if line.strip() == '':
        blank_count += 1
        if blank_count <= 2:
            result.append(line)
    else:
        blank_count = 0
        result.append(line)

content = ''.join(result)
with open(path, "w", encoding="utf-8-sig", newline='\r\n') as f:
    f.write(content)

new_lines = content.count('\n')
print(f"plot_screen.dart: {total} -> {new_lines} lines (-{total - new_lines})")

# Check remaining issues
issues = ['_ensureAnalogSegments', '_pipelineEnabled', '_analogEnvelopeEnabled',
          '_renderMode', 'CDataPoint', 'FfiBridge', 'calloc', '_notifyPipelineViewport',
          '_refreshViewportDataFromEnvelope', '_refreshViewportFromAnalog', '_refreshViewportFromAnalogImpl']
for issue in issues:
    if issue in content:
        print(f"  REMAINING: {issue}")
