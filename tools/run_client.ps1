# ═══════════════════════════════════════════════════════════════════════
#  源影 · 一键启动客户端（Windows）
# ═══════════════════════════════════════════════════════════════════════
#
# # 为什么要有这个脚本（2026-10-09 真实事故）
#
# ```text
# README:216 写的是  flutter build windows --release -t lib/shell.dart
# README:222 专门警告「-t lib/shell.dart 不能漏 —— lib/main.dart 是早期的
#            HEVC 验收 spike，不是产品入口。漏了 -t 会编出一个 spike
#            而不是客户端」，README:283 又补了一句「编错了不报错」。
#
# ★ 2026-10-09 我（lead）就是漏了 -t 直接跑 `flutter build windows --release`：
#   · 构建**成功退出**（BUILD_EXIT=0），一个字都没报错；
#   · 产物 `sourin_spike.exe` 覆盖掉 Release 树里**正确的**产品 exe；
#   · 双击起来是「media_kit + HEVC 验收 spike」那个白底调试页；
#   · 判据只有一条：`data/app.so` 的大小（产品 10.8 MB / spike ~4 MB）。
# ```
#
# ⇒ 这个脚本把那条判据**变成硬闸**：编完立刻量 app.so，不达标就报错退出，
#   绝不让你拿到一个「看起来编好了」的 spike。
#
# # 用法
#
# ```powershell
# .\tools\run_client.ps1              # 编 + 跑（默认 Release）
# .\tools\run_client.ps1 -NoBuild     # 只跑，不编（改过 Flutter 才需要编）
# .\tools\run_client.ps1 -Rust        # 先 cargo build --release 再编再跑
# .\tools\run_client.ps1 -Dev         # 开发模式：flutter run + 隔离数据目录（热重载）
# .\tools\run_client.ps1 -Dev -DataDir D:\tmp\sourin-dev
# .\tools\run_client.ps1 -BuildOnly   # 只编，不启动
# ```
#
# # ⚠️ 关于数据目录（用户铁律）
#
# ```text
# `-Dev` 默认把数据目录指到 `$env:TEMP\sourin-dev` —— **绝不碰**
# `%APPDATA%\app.sourin.player`（那里是用户真实的收藏/进度/片头片尾）。
# 非 -Dev 的 Release 启动**会**用真实数据目录，这是产品正常行为，
# 但脚本只启动、不做任何写入型探针。
# ```

[CmdletBinding()]
param(
    [switch]$Rust,       # 先编 Rust 核心
    [switch]$NoBuild,    # 跳过 flutter build，直接跑已有的产物
    [switch]$Dev,        # 开发模式（flutter run + 热重载 + 隔离数据目录）
    [switch]$BuildOnly,  # 只编不跑
    [string]$DataDir     # -Dev 时的数据目录（缺省 $env:TEMP\sourin-dev）
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$flutter = "C:\Users\iuuuuuuuu\flutter\bin\flutter.bat"
if (-not (Test-Path $flutter)) {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "找不到 flutter（既不在 $flutter，也不在 PATH）" }
    $flutter = $cmd.Source
}

function Step($n, $msg) { Write-Host ""; Write-Host "=== [$n] $msg ===" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Bad($msg)  { Write-Host "  ✗ $msg" -ForegroundColor Red }

# ── ① 改过 Rust 才需要（README:212 的「编 Flutter」之前那步）──
if ($Rust) {
    Step 1 "cargo build --release（Rust 核心）"
    $cargo = "$env:USERPROFILE\.cargo\bin\cargo.exe"
    if (-not (Test-Path $cargo)) { $cargo = "cargo" }
    Push-Location "$root\rust\sourin_core"
    try { & $cargo build --release } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "cargo build 失败（exit $LASTEXITCODE）" }
    Ok "Rust 核心已重编"
}

# ── ② 开发模式：flutter run（热重载）+ 隔离数据目录 ──
if ($Dev) {
    if (-not $DataDir) { $DataDir = Join-Path $env:TEMP "sourin-dev" }
    Step 2 "开发模式：flutter run（数据目录 = $DataDir）"
    Write-Host "  ⚠️ README:857-865 —— 默认数据目录里是你的真实收藏/进度，已隔离。" -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    & $flutter run -t lib/shell.dart "--dart-define=DATA_DIR_OVERRIDE=$DataDir"
    exit $LASTEXITCODE
}

# ── ③ 编（**-t lib/shell.dart 是硬编码的，改不了**）──
if (-not $NoBuild) {
    Step 3 "flutter build windows --release -t lib/shell.dart"
    & $flutter build windows --release -t lib/shell.dart
    $rc = $LASTEXITCODE
    # ★ 构建失败就到此为止：绝不在失败的构建上动 bundle ——
    #   否则会往客户端里塞一颗没有对应产物的核心。
    if ($rc -ne 0) { throw "flutter build 失败（exit $rc）" }

    # ── 把 Rust 核心装进 bundle（2026-10-10，CR-02）──
    # 这里**只往一个方向**拷：cargo 的输出 -> Release。
    #
    # 旧逻辑（已删）：构建**前**备份 Release 里那颗，构建后按大小比
    # 不一致就盖回去。那等于把刚编出来的新核心换成构建前的旧核心，
    # 注释却写着相反的话；而且它想解决的问题并不存在 ——
    # windows/CMakeLists.txt:122-135 用的是 install(FILES ...)，
    # 没有「按时间戳决定要不要拷」这种行为（README:208-211 的说法
    # 在本仓 CMake 里没有对应实现）。
    #
    # 显式拷 + 比对 sha，是为了让「bundle 里跑的是哪颗核心」这件事
    # 不再取决于构建系统的隐式行为。
    $srcCore = "$root\rust\sourin_core\target\release\sourin_core.dll"
    $dstCore = "$root\build\windows\x64\runner\Release\sourin_core.dll"
    if (Test-Path $srcCore) {
        Copy-Item -LiteralPath $srcCore -Destination $dstCore -Force
        $srcSha = (Get-FileHash -LiteralPath $srcCore -Algorithm SHA256).Hash
        $dstSha = (Get-FileHash -LiteralPath $dstCore -Algorithm SHA256).Hash
        if ($srcSha -eq $dstSha) {
            Ok "sourin_core.dll 已装进 Release（sha=$($srcSha.Substring(0,16))… 与 target\release 一致）"
        } else {
            Bad "装进 Release 的 sourin_core.dll 与 target\release 对不上（$($srcSha.Substring(0,16))… vs $($dstSha.Substring(0,16))…）"
            exit 1
        }
    } else {
        Write-Host "  ⚠️ rust\sourin_core\target\release 里没有 sourin_core.dll —— 没跑过 cargo build --release，bundle 里不会有核心" -ForegroundColor Yellow
    }
} else {
    Step 3 "跳过构建（-NoBuild）"
}

# ── ④ ★★★ 硬闸：app.so 的大小决定编出来的是产品还是 spike ──
Step 4 "校验产物（README:283 的判据）"
$rel  = "$root\build\windows\x64\runner\Release"
$exe  = "$rel\sourin_spike.exe"
$appso = "$rel\data\app.so"
if (-not (Test-Path $exe))   { throw "产物不存在：$exe（先去掉 -NoBuild 编一次）" }
if (-not (Test-Path $appso)) { throw "data\app.so 不存在 ⇒ 这棵树不是完整构建，先编一次" }

$soMb = (Get-Item $appso).Length / 1MB
$exeT = (Get-Item $exe).LastWriteTime
Write-Host ("  exe     = {0}  ({1})" -f (Split-Path $exe -Leaf), $exeT)
Write-Host ("  app.so  = {0:N2} MB" -f $soMb)

# 实测：产品入口 app.so = 10.81 MB；spike 入口 = 约 4 MB。判据取 README:283 的 5 MB。
if ($soMb -lt 5) {
    Bad "app.so 只有 $([math]::Round($soMb,2)) MB（产品应 > 5 MB）"
    Write-Host ""
    Write-Host "  ★ 这几乎肯定意味着构建漏了 -t lib/shell.dart ⇒ 编出来的是" -ForegroundColor Red
    Write-Host "    lib/main.dart 那个 HEVC 验收 spike，不是客户端。" -ForegroundColor Red
    Write-Host "    README:222-223 专门警告过这个坑，而且**编错了不报错**。" -ForegroundColor Red
    Write-Host ""
    Write-Host "    修：本脚本已经硬编码了 -t，请用 .\tools\run_client.ps1 重新编。" -ForegroundColor Yellow
    exit 1
}
Ok "app.so = $([math]::Round($soMb,2)) MB（> 5 MB）⇒ 入口是 lib/shell.dart，是客户端"

$dll = "$rel\sourin_core.dll"
if (Test-Path $dll) {
    $di = Get-Item $dll
    Ok "sourin_core.dll = $($di.Length) B  $($di.LastWriteTime)  sha=$((Get-FileHash $dll -Algorithm SHA256).Hash.Substring(0,16))…"
    $srcDll = "$root\rust\sourin_core\target\release\sourin_core.dll"
    if (Test-Path $srcDll) {
        $s = Get-Item $srcDll
        if ($s.Length -ne $di.Length) {
            Write-Host "  ⚠️ 与 rust\...\target\release 那颗不一致（$($s.Length) B）—— 跑的是旧核心，要 -Rust 重编" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  ⚠️ Release 树里没有 sourin_core.dll ⇒ 客户端会起不来（README 的「核心启动失败」）" -ForegroundColor Yellow
}

if ($BuildOnly) { Ok "只编不跑（-BuildOnly）"; exit 0 }

# ── ⑤ 启动 ──
Step 5 "启动客户端"
Get-Process sourin_spike -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  关掉已在跑的 pid=$($_.Id)"
    $_.CloseMainWindow() | Out-Null; Start-Sleep -Milliseconds 700
    if (-not $_.HasExited) { $_.Kill() }
}
$p = Start-Process -FilePath $exe -WorkingDirectory $rel -PassThru
Start-Sleep -Seconds 6
$p.Refresh()
if ($p.HasExited) { throw "客户端起来后立刻退出了（exit $($p.ExitCode)）—— 看 %APPDATA%\app.sourin.player\logs\ 最新那份" }
Ok "pid=$($p.Id)  标题=[$($p.MainWindowTitle)]  工作集=$([math]::Round($p.WorkingSet64/1MB,1)) MB"
Write-Host ""
Write-Host "  数据目录 = $env:APPDATA\app.sourin.player（产品正常行为；-Dev 才会隔离）" -ForegroundColor DarkGray