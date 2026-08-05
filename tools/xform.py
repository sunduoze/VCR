"""
3-phase safe transform:
Phase A: Delete block A (L677 comment to _refreshViewportData opening brace)
Phase B: Replace _refreshViewportData (the region BETWEEN the two dead blocks) 
Phase C: Delete block B (L867 AnalogSegment comment to L970 return anyData)
Then cleanup fields + pushChannelBatch call.
"""
path = r"D:\AI\upper_computer_tools\VCR\lib\screens\plot_screen.dart"

with open(path, "r", encoding="utf-8-sig") as f:
    content = f.read()

# Phase A: Block1 = "/// Float64List view over" to the opening of _refreshViewportData
blk1_start = "/// Float64List view over the Rust Vec memory"
blk1_end = "\n  void _refreshViewportData() {"

p1 = content.find(blk1_start)
p2 = content.find(blk1_end)

assert p1 != -1 and p2 != -1, f"Block1 not found: start={p1}, end={p2}"
# Delete from p1 to just before _refreshViewportData
# (p2 points to the \n before void, we want to remove up to and including that newline)
content = content[:p1] + content[p2+1:]
print(f"Phase A: deleted block1 ({p2 - p1} bytes)")

# Phase B: Replace _refreshViewportData method body
# Now the old method starts at some position; find it
# Old: "  void _refreshViewportData() { ... long body ... \n  }\n\n  // ── AnalogSegment..."
# Replace the whole method

# Find start of old _refreshViewportData
vp_start_marker = "\n  void _refreshViewportData() {"
vp_pos = content.find(vp_start_marker)
assert vp_pos != -1, "_refreshViewportData not found"

# Find end: look for "\n  }\n\n  // ── AnalogSegment"
vp_end_marker = "\n  // ── AnalogSegment envelope read ──"
vp_end = content.find(vp_end_marker, vp_pos)
assert vp_end != -1, f"_refreshViewportData end not found (searched from {vp_pos})"

# But content[vp_pos] starts with \n, we want "  void _refreshViewportData..."
# The old body is content[vp_pos+1 : vp_end]
old_body = content[vp_pos+1:vp_end]
print(f"Phase B: old _refreshViewportData body = {len(old_body)} bytes")

new_body = """  void _refreshViewportData() {
    /// Min-Max pixel decimation: each screen pixel column gets the min+max
    /// of all data points in that column. Preserves peak detail (no spike loss)
    /// while reducing e.g. 250K points → ~4000 drawing primitives per channel.
    /// Runs entirely in Dart — zero FFI, zero pipeline, zero analog segment.
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

content = content[:vp_pos+1] + new_body + content[vp_end:]
print(f"Phase B: replaced with {len(new_body)} bytes")

# Phase C: Delete block C = "  // ── AnalogSegment envelope read ──" to "/// 分离的数据轮询"
blkC_start = "  // ── AnalogSegment envelope read ──"
blkC_end = "  /// 分离的数据轮询"

p3 = content.find(blkC_start)
p4 = content.find(blkC_end)

assert p3 != -1 and p4 != -1, f"BlockC not found: start={p3}, end={p4}"
content = content[:p3] + content[p4:]
print(f"Phase C: deleted blockC ({p4 - p3} bytes)")

# Phase D: Fix pushChannelBatch call
old_call = "bridge.pushChannelBatch(dk, i, batchPerChannel[i]);"
new_call = "bridge.pushChannelBatchDart(dk, i, batchPerChannel[i]);"
if old_call in content:
    content = content.replace(old_call, new_call)
    print("Phase D: pushChannelBatch -> pushChannelBatchDart")

# Phase E: Comment dead fields
field_patches = {
    "  Float64List? _queryBuffer;        // Reusable Float64List for _refreshViewportData\n":
        "  // REMOVED (Min-Max): Float64List? _queryBuffer;\n",
    "  Pointer<CDataPoint>? _queryNative; // Reusable native buffer for FFI queries\n":
        "  // REMOVED (Min-Max): Pointer<CDataPoint>? _queryNative;\n",
    "  int _queryNativeCap = 0;           // Current native buffer capacity (in CDataPoint elements)\n":
        "  // REMOVED (Min-Max): int _queryNativeCap = 0;\n",
}
for old, new in field_patches.items():
    if old in content:
        content = content.replace(old, new)
        print(f"Phase E: comment field")

with open(path, "w", encoding="utf-8-sig", newline="\r\n") as f:
    f.write(content)

print(f"\nFile: {content.count(chr(10))} lines")
print("Done.")
