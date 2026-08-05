import os, re

# ── Scan plot_screen.dart ──────────────────────
path = r'lib\screens\plot_screen.dart'
with open(path, 'r', encoding='utf-8-sig') as f:
    lines = f.readlines()

print(f'Total: {len(lines)} lines')

# Find method boundaries
for i, line in enumerate(lines):
    s = line.strip()
    if s.startswith('void _refreshViewportData') or s.startswith('bool _refreshViewportData'):
        print(f'  L{i+1} _refreshViewportData: {s[:80]}')
    if s.startswith('void _ensureAnalog') or s.startswith('bool _ensureAnalog'):
        print(f'  L{i+1} _ensureAnalog: {s[:80]}')
    if s.startswith('void _notifyPipeline'):
        print(f'  L{i+1} _notifyPipeline: {s[:80]}')
    if s.startswith('bool _refreshViewportDataFromEnvelope'):
        print(f'  L{i+1} _refreshViewportDataFromEnvelope: {s[:80]}')
    if s.startswith('bool _refreshViewportFromAnalog'):
        print(f'  L{i+1} _refreshViewportFromAnalog: {s[:80]}')
    if s.strip() == 'enum _RenderMode':
        print(f'  L{i+1} enum _RenderMode')

# Count refs
for pat in ['_pipelineEnabled', '_analogEnvelopeEnabled', '_renderBypass']:
    c = sum(1 for l in lines if pat in l)
    print(f'{pat}: {c} lines')
