"""VCR cleanup: replace _refreshViewportData + delete 3 dead methods, in ONE safe pass."""
import re

path = r"D:\AI\upper_computer_tools\VCR\lib\screens\plot_screen.dart"
with open(path, "r", encoding="utf-8-sig") as f:
    text = f.read()
original_len = len(text)

# Target range to delete (verified line numbers):
# L676: comment "Float64List view over the Rust Vec memory"
# L679-L864: _refreshViewportDataFromEnvelope (L679-L777) 
# L781-L865: _refreshViewportData (old version)
# L867-L1010: _refreshViewportFromAnalog + _refreshViewportFromAnalogImpl
# L1012: blank
# Total: L676-L1012

# Strategy: replace the whole block from _refreshViewportDataFromEnvelope's comment 
# through the blank after return anyData; with JUST the new Min-Max method

# Find the markers in raw text
marker_start = "/// Float64List view over the Rust Vec memory"
marker_end = "return anyData;"

start_pos = text.find(marker_start)
end_pos = text.find(marker_end)

if start_pos == -1:
    print(f"ERROR: start marker not found")
    exit(1)
if end_pos == -1:
    print(f"ERROR: end marker not found")
    exit(1)

# Find the next newline after "return anyData;" to include it
end_nl = text.find("\n", end_pos)
# Also consume trailing blank line
next_non_blank = text.find("\n", end_nl + 1)
# Check if it's a blank line
if text[end_nl+1:next_non_blank].strip() == "":
    end_nl = next_non_blank

print(f"Deleting from byte {start_pos} to {end_nl}")

new_method = """/// Min-Max pixel decimation: replaces the old pipeline/analog/pyramid FFI path.
/// Each screen pixel column gets the min+max of all data points in that column.
/// Preserves peak detail (no spike loss) while reducing 1M points → ~4000 primitives/channel.
/// Runs entirely in Dart — zero FFI, zero pipeline, zero analog segment.
  void _refreshViewportData() {
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

"""

text = text[:start_pos] + new_method + text[end_nl+1:]

# Also clean up field references that will now be dead
# Comment them out rather than delete (safer)
replacements = [
    ("Float64List? _queryBuffer;        // Reusable Float64List for _refreshViewportData\n",
     "// REMOVED (Min-Max): Float64List? _queryBuffer;\n"),
    ("Pointer<CDataPoint>? _queryNative; // Reusable native buffer for FFI queries\n",
     "// REMOVED (Min-Max): Pointer<CDataPoint>? _queryNative;\n"),
    ("int _queryNativeCap = 0;           // Current native buffer capacity (in CDataPoint elements)\n",
     "// REMOVED (Min-Max): int _queryNativeCap = 0;\n"),
    ("String _pyramidDebugText = '';\n",
     "// REMOVED (Min-Max): String _pyramidDebugText = '';\n"),
    ("_RenderMode _renderMode = _RenderMode.auto;\n",
     "// REMOVED (Min-Max): _RenderMode _renderMode = _RenderMode.auto;\n"),
]

for old, new in replacements:
    if old in text:
        text = text.replace(old, new)
        print(f"Replaced: {old.strip()}")
    else:
        print(f"NOT FOUND: {old.strip()}")

# Count lines
new_len = len(text)
line_count = text.count('\n')
print(f"Removed {original_len - new_len} bytes, {3690 - line_count} lines")
print(f"Final: {line_count} lines")

with open(path, "w", encoding="utf-8-sig", newline="\r\n") as f:
    f.write(text)
print("Done.")
