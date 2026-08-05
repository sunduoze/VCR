"""Remove dead _refreshViewportDataFromEnvelope + analog methods from plot_screen.dart."""
path = r"D:\AI\upper_computer_tools\VCR\lib\screens\plot_screen.dart"

with open(path, "r", encoding="utf-8-sig") as f:
    content = f.read()

old_len = len(content)

# Delete from "/// Float64List view over the Rust Vec memory" 
# to the blank line after "return anyData;\n  }\n"
start_marker = "/// Float64List view over the Rust Vec memory"
end_marker = "  /// 分离的数据轮询"

start = content.find(start_marker)
end = content.find(end_marker)

if start == -1:
    print("ERROR: start marker not found")
    exit(1)
if end == -1:
    print("ERROR: end marker not found")
    exit(1)

# Keep the _fetchRealData comment
content = content[:start] + content[end:]
print(f"Removed {old_len - len(content)} bytes")

# Also clean up dead fields
field_patches = [
    ("  Float64List? _queryBuffer;        // Reusable Float64List for _refreshViewportData\n",
     "  // REMOVED (Min-Max): Float64List? _queryBuffer;\n"),
    ("  Pointer<CDataPoint>? _queryNative; // Reusable native buffer for FFI queries\n",
     "  // REMOVED (Min-Max): Pointer<CDataPoint>? _queryNative;\n"),
    ("  int _queryNativeCap = 0;           // Current native buffer capacity (in CDataPoint elements)\n",
     "  // REMOVED (Min-Max): int _queryNativeCap = 0;\n"),
]

for old, new in field_patches:
    if old in content:
        content = content.replace(old, new)
        print(f"Cleaned: {old.strip()}")

with open(path, "w", encoding="utf-8-sig", newline="\r\n") as f:
    f.write(content)

# Verify
with open(path, "r", encoding="utf-8-sig") as f:
    lines = f.readlines()
print(f"Final: {len(lines)} lines")
