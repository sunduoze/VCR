import os

path = r"lib\screens\plot_screen.dart"
with open(path, "r", encoding="utf-8-sig") as f:
    lines = f.readlines()

targets = [(451, "_ensureAnalogSegments"), (660, "_notifyPipelineViewport"),
    (679, "_refreshViewportDataFromEnvelope"), (781, "_refreshViewportData"),
    (871, "_refreshViewportFromAnalog"), (882, "_refreshViewportFromAnalogImpl")]

for start_ln, name in targets:
    depth = 0
    started = False
    end_ln = start_ln
    for i in range(start_ln - 1, len(lines)):
        line = lines[i]
        if not started:
            if "{" in line:
                started = True
                depth = line.count("{") - line.count("}")
            continue
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            end_ln = i + 1
            break
    size = end_ln - start_ln + 1
    print(f"{name}: L{start_ln}-L{end_ln} ({size} lines)")

# Find _RenderMode enum
for i, line in enumerate(lines):
    s = line.strip()
    if s == "enum _RenderMode {" or s.startswith("enum _RenderMode"):
        print(f"enum _RenderMode: L{i+1}")
        for j in range(i + 1, len(lines)):
            if lines[j].strip() == "}":
                print(f"  closes L{j+1}")
                break
        break

# Find _ensureAnalogSegments body
for i, line in enumerate(lines):
    s = line.strip()
    if s.startswith("void _ensureAnalogSegments"):
        print(f"\n_ensureAnalogSegments: L{i+1}")
        for k in range(i, min(i + 50, len(lines))):
            print(f"  L{k+1}: {lines[k].rstrip()}")
        break

# Count pipeline/analog/envelope/ffi imports  
for i, line in enumerate(lines):
    if "ffi_bridge" in line.lower():
        print(f"\nffi_bridge import: L{i+1}: {line.strip()}")
    if "analog" in line and ("import" in line or "part" in line):
        print(f"analog import: L{i+1}: {line.strip()}")
