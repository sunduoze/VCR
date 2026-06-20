# VCR 一键重建并运行
# 用法: 双击 rebuild.bat / 右键 rebuild.bat 运行

param(
    [switch]$SkipRust,
    [switch]$SkipDart,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Continue'
$VCR_ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$RUST_DIR = Join-Path $VCR_ROOT 'rust'
$RELEASE_DIR = Join-Path $VCR_ROOT 'build\windows\x64\runner\Release'
$DLL_SRC = Join-Path $RUST_DIR 'target\release\vcr_lib.dll'
$DLL_DST = Join-Path $RELEASE_DIR 'vcr_lib.dll'
$EXE_PATH = Join-Path $RELEASE_DIR 'vcr.exe'

Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' VCR 重建脚本  (Ctrl+C 取消)' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''

# 0. 关闭已有进程
$running = Get-Process -Name 'vcr' -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 关闭已有 VCR 进程 ($($running.Id))..." -ForegroundColor Yellow
    Stop-Process -Name 'vcr' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}

# 1. 编译 Rust
if (-not $SkipRust) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 编译 Rust (cargo build --release)..." -ForegroundColor Yellow
    Push-Location $RUST_DIR
    cargo build --release 2>&1 | Where-Object { $_ -match 'error|warning:|Compiling|Finished' } | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "Rust 编译失败 (exit=$LASTEXITCODE)" -ForegroundColor Red; exit 1 }
    Pop-Location
    Write-Host '  -> Rust 编译完成' -ForegroundColor Green

    if (Test-Path $DLL_SRC) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 复制 vcr_lib.dll -> Release..." -ForegroundColor Yellow
        Copy-Item -Force $DLL_SRC $DLL_DST
    } else {
        Write-Host "DLL 不存在: $DLL_SRC" -ForegroundColor Red; exit 1
    }
} else {
    Write-Host '[SKIP] Rust 编译' -ForegroundColor DarkGray
}

# 2. 生成 Dart bindings
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 生成 Dart bindings..." -ForegroundColor Yellow
Push-Location $VCR_ROOT
flutter_rust_bridge_codegen generate 2>&1 | Where-Object { $_ -match 'Done|error|warning:' } | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "Codegen 失败" -ForegroundColor Red; exit 1 }
Pop-Location
Write-Host '  -> Dart bindings 生成完成' -ForegroundColor Green

# 3. 编译 Flutter
if (-not $SkipDart) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 编译 Flutter..." -ForegroundColor Yellow
    Push-Location $VCR_ROOT
    flutter build windows --release 2>&1 | Where-Object { $_ -match 'error:|Building|Built|Finished' } | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "Flutter 构建失败" -ForegroundColor Red; exit 1 }
    Pop-Location
    Write-Host '  -> Flutter 构建完成' -ForegroundColor Green
} else {
    Write-Host '[SKIP] Flutter 构建' -ForegroundColor DarkGray
}

# 4. 启动
if (-not $NoLaunch) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 启动 VCR..." -ForegroundColor Yellow
    if (-not (Test-Path $EXE_PATH)) { Write-Host "EXE 不存在: $EXE_PATH" -ForegroundColor Red; exit 1 }
    Start-Process $EXE_PATH -PassThru | ForEach-Object { Write-Host "  PID=$($_.Id) started" -ForegroundColor Green }
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' 完成!' -ForegroundColor Green
Write-Host '========================================' -ForegroundColor Cyan
