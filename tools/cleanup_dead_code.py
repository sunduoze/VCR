"""Precise dead code removal from plot_screen.dart using known line numbers."""
import sys

path = r"D:\AI\upper_computer_tools\VCR\lib\screens\plot_screen.dart"
with open(path, "r", encoding="utf-8-sig") as f:
    lines = f.readlines()

original_count = len(lines)
print(f"Original: {original_count} lines")

# We confirmed line numbers via Select-String:
# L680: bool _refreshViewportDataFromEnvelope() {
# L972: return anyData; (end of _refreshViewportFromAnalogImpl)
# Using 0-indexed: L679-L971 = 293 lines

# Step 1: Delete the three dead methods (L679-L971, 0-indexed)
# But first, verify the content at those lines
start_idx = 679  # 0-indexed L679
end_idx = 971    # 0-indexed L971 (inclusive)

print(f"L{start_idx} (0-idx): {lines[start_idx].strip()[:80]}")
print(f"L{end_idx} (0-idx): {lines[end_idx].strip()[:80]}")

# Verify
if "bool _refreshViewportDataFromEnvelope" in lines[start_idx]:
    print("Start verified ✓")
else:
    print(f"START MISMATCH: {lines[start_idx].strip()[:100]}")
    
if "return anyData;" in lines[end_idx]:
    print("End verified ✓")
else:
    print(f"END MISMATCH: {lines[end_idx].strip()[:100]}")

# Delete
del lines[start_idx:end_idx+1]
removed = end_idx - start_idx + 1
print(f"Step 1: Removed {removed} lines (3 dead methods)")

# Step 2: Comment out dead fields
dead_fields = {
    "Float64List? _queryBuffer;": "// REMOVED: Float64List? _queryBuffer;",
    "Pointer<CDataPoint>? _queryNative;": "// REMOVED: Pointer<CDataPoint>? _queryNative;",
    "int _queryNativeCap = 0;": "// REMOVED: int _queryNativeCap = 0;",
}

for i, line in enumerate(lines):
    for old, new in dead_fields.items():
        if old in line:
            lines[i] = line.replace(old, new)
            print(f"Step 2: Commented field at L{i}")

# Step 3: Comment _pyramidDebugText
for i, line in enumerate(lines):
    if "_pyramidDebugText = '';" in line:
        lines[i] = line.replace("String _pyramidDebugText = '';", "// REMOVED: String _pyramidDebugText = '';")
        print(f"Step 3: Commented _pyramidDebugText at L{i}")
        break

# Step 4: Comment _renderMode
for i, line in enumerate(lines):
    if "_RenderMode _renderMode = _RenderMode.auto;" in line:
        lines[i] = line.replace("_RenderMode _renderMode = _RenderMode.auto;", "// REMOVED: _RenderMode _renderMode = _RenderMode.auto;")
        print(f"Step 4: Commented _renderMode at L{i}")
        break

print(f"Final: {len(lines)} lines (removed {original_count - len(lines)})")

with open(path, "w", encoding="utf-8-sig", newline="\r\n") as f:
    f.writelines(lines)
print("Done.")
