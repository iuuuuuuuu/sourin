<#
  源影（Sourin）安装/卸载助手：只关掉**这一个安装目录里的**那个进程。

  # 为什么不能用 taskkill /IM sourin_spike.exe

  那是**按进程名**杀 —— 会把机器上任何同名进程都杀掉，包括从别的目录起的
  调试实例。我们自己在实测时就踩过这个坑（探针脚本按名字杀，误伤了队友
  正在跑的实例，见 lesson #396）。安装器只该关掉**它自己要覆盖的那一份**，
  判据必须是路径。

  # 判据

  Win32_Process.ExecutablePath 与 -InstallDir 规范化后必须**完全相等**。
  用 [IO.Path]::GetFullPath 做规范化，这样 \\?\ 前缀、尾随反斜杠、
  大小写、短文件名（8.3）的差异都不会造成误判或漏判。

  # 行为

  ① 先发 CloseMainWindow（相当于点窗口的 X）—— 让它走自己的退出流程，
     有机会保存窗口几何 / 播放进度。
  ② 等最多 8 秒；还在就 Stop-Process -Force。
  ③ **绝不** 杀 -InstallDir 之外的任何进程。
  ④ 找不到就静默退出（exit 0）—— 安装器不关心"本来就没在跑"。

  # 退出码

  0 = 处理完毕（含"本来就没在跑"）
  1 = 参数不对
  2 = 有进程但关不掉（安装器会据此提示用户手动关）
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InstallDir
)

$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
  Write-Host "kill_sourin: -InstallDir 为空"
  exit 1
}

# ── 规范化目标路径 ─────────────────────────────────────────────────────
$targetExe = $null
try {
  $targetExe = [System.IO.Path]::GetFullPath((Join-Path $InstallDir 'sourin_spike.exe'))
} catch {
  Write-Host "kill_sourin: 路径不合法 - $InstallDir"
  exit 1
}

Write-Host "kill_sourin: 目标 = $targetExe"

# ── 找到**恰好**那一个 ─────────────────────────────────────────────────
$victims = @()
try {
  $procs = Get-CimInstance Win32_Process -Filter "Name = 'sourin_spike.exe'" -ErrorAction Stop
  foreach ($p in $procs) {
    $exe = $p.ExecutablePath
    if ([string]::IsNullOrEmpty($exe)) {
      # 权限不足时 ExecutablePath 会是空 —— 不能据此认定"就是它"，
      # 也不能据此认定"不是它"。报出来让人知道有这个东西存在。
      Write-Host "kill_sourin: PID $($p.ProcessId) 拿不到 ExecutablePath（权限不足？）—— 跳过"
      continue
    }
    $norm = $null
    try { $norm = [System.IO.Path]::GetFullPath($exe) } catch { continue }
    if ($norm -ieq $targetExe) { $victims += $p }
  }
} catch {
  # CIM 不可用（极少数被裁剪的系统）—— 退化成 .NET 进程查询。
  # ★ 同样按路径判，绝不按名字杀。
  Write-Host "kill_sourin: CIM 查询失败（$($_.Exception.Message)），退化成 .NET 查询"
  foreach ($p in [System.Diagnostics.Process]::GetProcessesByName('sourin_spike')) {
    try {
      $norm = [System.IO.Path]::GetFullPath($p.MainModule.FileName)
      if ($norm -ieq $targetExe) {
        $victims += [pscustomobject]@{ ProcessId = $p.Id; ExecutablePath = $norm }
      }
    } catch {
      Write-Host "kill_sourin: PID $($p.Id) 读 MainModule 失败 —— 跳过"
    }
  }
}

if ($victims.Count -eq 0) {
  Write-Host "kill_sourin: 该目录下没有正在运行的实例（无需处理）"
  exit 0
}

Write-Host "kill_sourin: 找到 $($victims.Count) 个正在运行的实例：$($victims.ProcessId -join ', ')"

# ── ① 先请它自己退出 ───────────────────────────────────────────────────
foreach ($v in $victims) {
  try {
    $proc = Get-Process -Id $v.ProcessId -ErrorAction Stop
    $null = $proc.CloseMainWindow()
    Write-Host "kill_sourin: PID $($v.ProcessId) 已发送关闭请求"
  } catch {
    Write-Host "kill_sourin: PID $($v.ProcessId) 发送关闭请求失败（$($_.Exception.Message)）"
  }
}

# 等最多 8 秒，每秒查一次
$deadline = (Get-Date).AddSeconds(8)
$left = @($victims)
while ((Get-Date) -lt $deadline -and $left.Count -gt 0) {
  Start-Sleep -Milliseconds 500
  $left = @($left | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
}

if ($left.Count -eq 0) {
  Write-Host "kill_sourin: 全部已正常退出"
  exit 0
}

# ── ② 还在就强杀（只杀已确认路径匹配的那些 PID）───────────────────────
foreach ($v in $left) {
  try {
    Stop-Process -Id $v.ProcessId -Force -ErrorAction Stop
    Write-Host "kill_sourin: PID $($v.ProcessId) 已强制结束"
  } catch {
    Write-Host "kill_sourin: PID $($v.ProcessId) 强制结束失败（$($_.Exception.Message)）"
  }
}

Start-Sleep -Milliseconds 800
$still = @($left | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
if ($still.Count -gt 0) {
  Write-Host "kill_sourin: 仍有 $($still.Count) 个实例在运行：$($still.ProcessId -join ', ')"
  exit 2
}

Write-Host "kill_sourin: 处理完毕"
exit 0
