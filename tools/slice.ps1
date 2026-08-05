$ErrorActionPreference = "Stop"
$path = "D:\AI\upper_computer_tools\VCR\lib\screens\plot_screen.dart"

# Read all lines preserving encoding
$lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
Write-Host "Total lines: $($lines.Length)"

# Line numbers are 1-indexed in display, 0-indexed in array
# Keep: [0..675]  (L1-L676)
# Replace: [676..1011] (L677-L1012) with new _refreshViewportData
# Keep: [1012..]  (L1013+)

$keep1 = $lines[0..675]

$newMethod = @'
  void _refreshViewportData() {
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

'@ -split '\r?\n'

$keep2 = $lines[1012..3690]

Write-Host "Phase A: ${$keep1.Length} lines"
Write-Host "Phase B: ${$newMethod.Length} lines (new method)"
Write-Host "Phase C: ${$keep2.Length} lines"

$result = $keep1 + $newMethod + @("") + $keep2
Write-Host "Result: $($result.Length) lines"

# Write with UTF-8 BOM + CRLF
$enc = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllLines($path, $result, $enc)

Write-Host "Done."
