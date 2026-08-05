"""Replace _refreshViewportData + delete dead methods, all in one pass."""
import sys

path = r"D:\AI\upper_computer_tools\VCR\lib\screens\plot_screen.dart"
with open(path, "r", encoding="utf-8-sig") as f:
    lines = f.readlines()

original_count = len(lines)
print(f"Original: {original_count} lines")

# Verify key lines
for i, line in enumerate(lines):
    s = line.strip()
    if "bool _refreshViewportDataFromEnvelope" in s:
        print(f"  _refreshViewportDataFromEnvelope starts at L{i} (0-idx)")
    if "_refreshViewportFromAnalogImpl" in s and "bool" in s:
        print(f"  _refreshViewportFromAnalogImpl starts at L{i} (0-idx)")
    if s.startswith("return anyData;") and i > 800:
        print(f"  return anyData; at L{i} (0-idx)")
    if "void _refreshViewportData() {" in s:
        print(f"  _refreshViewportData starts at L{i} (0-idx)")

# Step 1: Find _refreshViewportData boundaries
# It starts with "void _refreshViewportData() {" and ends just before "bool _refreshViewportDataFromEnvelope"
vp_start = None
vp_end = None
for i, line in enumerate(lines):
    if "void _refreshViewportData() {" in line and "///" not in line:
        vp_start = i
    if vp_start is not None and "bool _refreshViewportDataFromEnvelope" in line:
        # The line before the dead method should be the last line of _refreshViewportData
        # Scan backwards for the closing brace
        for j in range(i-1, vp_start, -1):
            if lines[j].strip() == "}" or lines[j].strip().startswith("}"):
                # This could be a nested close. Find the actual method end
                # The method ends with "_viewportRefreshCount++;" then "}"
                if "_viewportRefreshCount++" in lines[j-1]:
                    vp_end = j  # include the closing }
                    break
        break

if vp_start is not None and vp_end is not None:
    # Replace _refreshViewportData with new Min-Max version
    new_method = '''  void _refreshViewportData() {
    /// Min-Max pixel decimation: each screen pixel column gets the min+max
    /// of all data points in that column. Preserves peak detail (no spike loss)
    /// while reducing 1M points → ~4000 drawing primitives per channel.
    /// Runs entirely in Dart — no FFI, no pipeline, no analog segment.
    if (_xMin == _xMax || _screenWidth <= 0) return;

    final w = _screenWidth.round().clamp(1, 4096);

    for (int ci = 0; ci < _channels.length; ci++) {
      final ch = _channels[ci];
      if (!ch.visible || ch.data.isEmpty) {
        ch.viewportData.clear();
        ch.envelopeData.clear();
        continue;
      }

      final total = ch.data.length;
      final step = (total / w).ceil().clamp(1, total);
      final newestAbsX = ch.data.last.x;

      ch.viewportData.clear();
      ch.envelopeData.clear();

      for (int x = 0; x < w; x++) {
        final start = x * step;
        final end = (start + step).clamp(0, total);
        if (start >= total) break;

        double curMin = ch.data[start].y;
        double curMax = ch.data[start].y;
        for (int i2 = start + 1; i2 < end; i2++) {
          final v = ch.data[i2].y;
          if (v < curMin) curMin = v;
          if (v > curMax) curMax = v;
        }

        final xRel = ch.data[end - 1].x - newestAbsX;
        ch.viewportData.add(xRel, (curMin + curMax) * 0.5);
        ch.envelopeData.add(xRel, curMin);
        ch.envelopeData.add(xRel, curMax);
      }
    }
    _viewportRefreshCount++;
  }
'''
    new_lines = new_method.split('\n')
    old_end_idx = vp_end + 1
    print(f"Replacing L{vp_start}-L{vp_end} ({vp_end - vp_start + 1} lines) with new Min-Max ({len(new_lines)} lines)")
    lines[vp_start:old_end_idx] = [l + '\n' if not l.endswith('\n') else l for l in new_lines]

# Step 2: Now find and delete the three dead methods
# They start at "/// Float64List view over the Rust Vec memory" and end at "return anyData;"
del_start = None
del_end = None
for i, line in enumerate(lines):
    if "Float64List view over the Rust Vec memory" in line and del_start is None:
        del_start = i
        print(f"Dead methods start at L{i}")
    if del_start is not None and line.strip() == "return anyData;":
        del_end = i
        print(f"Dead methods end at L{i}")
        break

if del_start is not None and del_end is not None:
    # Also remove the "// ── AnalogSegment" comment that precedes the dead methods
    # Look backwards from del_start for comment lines that are part of this block
    comment_start = del_start
    for j in range(del_start-1, max(del_start-20, 0), -1):
        if lines[j].strip().startswith("///") or "AnalogSegment" in lines[j] or lines[j].strip() == "//":
            comment_start = j
        else:
            break
    
    # Also include any trailing blank line
    extend_end = del_end
    # Check if next line after return anyData; is blank
    if del_end + 1 < len(lines) and lines[del_end + 1].strip() == "":
        extend_end = del_end + 1
    
    actual_del_start = min(comment_start, del_start)
    removed = extend_end - actual_del_start + 1
    print(f"Deleting L{actual_del_start}-L{extend_end} ({removed} lines)")
    del lines[actual_del_start:extend_end + 1]
    print(f"Deleted {removed} lines of dead methods")

# Step 3: Clean up fields (comment them, don't delete, to avoid breaking other references)
field_map = {
    "Float64List? _queryBuffer;": "// REMOVED: Float64List? _queryBuffer;",
    "Pointer<CDataPoint>? _queryNative;": "// REMOVED: Pointer<CDataPoint>? _queryNative;",
    "int _queryNativeCap = 0;": "// REMOVED: int _queryNativeCap = 0;",
    "String _pyramidDebugText = '';": "// REMOVED: String _pyramidDebugText = '';",
    "_RenderMode _renderMode = _RenderMode.auto;": "// REMOVED: _RenderMode _renderMode = _RenderMode.auto;",
}
for i, line in enumerate(lines):
    for old, new in field_map.items():
        if old in line:
            lines[i] = line.replace(old, new)
            print(f"Commented at L{i}: {old.strip()}")

print(f"Final: {len(lines)} lines (was {original_count})")

with open(path, "w", encoding="utf-8-sig", newline="\r\n") as f:
    f.writelines(lines)
print("Done.")
