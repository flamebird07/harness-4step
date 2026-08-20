# V10 轻量：本视觉 runner 同用 Start-Job + Wait-Job -Timeout 180 且末尾输出 EXIT_CODE；caller 侧同样需 timeout=300000 + Tee-Object，否则 -2 丢失（虽不直接触发 §6.1 拆分，但证据链断裂）
param(
    [Parameter(Mandatory = $true)]
    [string[]]$ImageFiles,
    [string]$Prompt = "",
    [string]$Model = "xiaomi/mimo-v2.5",
    [string]$WorkspaceDir = "",
    [string]$OutDir = "",
    [int]$TimeoutSeconds = 180
)

<#
.SYNOPSIS
DSH 独立视觉审查脚本（不属于四步法）。主模型（如 deepseek-v4-flash）无视觉时，
经本脚本调用 mimo CLI + 视觉模型（默认 xiaomi/mimo-v2.5）"看图"，返回结构化文本结论。

用法（DSH 主 agent 或 subagent 经 pwsh 调用）：
  run_vision_review.ps1 -ImageFiles "C:\shot\before.png","C:\shot\after.png" `
    -Prompt "对比这两张截图的前后视觉差异，重点看布局/颜色/溢出" `
    -WorkspaceDir "C:\repo" -OutDir "C:\repo\.harness\vision"

参数：
  -ImageFiles     要审查的图片路径（必填，至少 1 张；截图/渲染图等）
  -Prompt         审查指令（可选；不传则用默认视觉审查指令）
  -Model          视觉模型（默认 xiaomi/mimo-v2.5，可换 mimo-v2.5-pro 等）
  -WorkspaceDir   工作目录（可选；mimo --dir）
  -OutDir         产物目录（可选；写入 raw + review 文本）
  -TimeoutSeconds 超时（默认 180s）

退出码约定：0=成功（mimo 正常返回）；-3=脚本错误；-2=超时；其余=mimo 退出码。
#>

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Fail-Cli([string]$Message) {
    Write-Output "EXIT_CODE=-3"
    Write-Output ("ERROR=" + $Message)
    exit 1
}

# --- 校验输入 ---
if ($ImageFiles.Count -eq 0) { Fail-Cli "必须提供至少 1 张图片（-ImageFiles）" }
$existing = @()
foreach ($img in $ImageFiles) {
    if (-not (Test-Path -LiteralPath $img)) { Fail-Cli "图片不存在：$img" }
    $existing += $img
}
if (-not $WorkspaceDir) { $WorkspaceDir = Split-Path -Parent $existing[0] }
if (-not $OutDir) { $OutDir = Join-Path $WorkspaceDir ".harness\vision" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# --- 定位 mimo CLI ---
$mimo = Get-Command mimo -ErrorAction SilentlyContinue
if (-not $mimo) {
    $candidates = @("$env:APPDATA\npm\mimo.cmd", "$env:APPDATA\npm\mimo.ps1")
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { $mimo = $c; break } }
}
if (-not $mimo) { Fail-Cli "mimo CLI not found in PATH (参考 references/mimo-cli-login.md 安装与登录)" }

# --- 组装 prompt（默认视觉审查指令） ---
if (-not $Prompt) {
    $Prompt = "请逐张打开附带的图片，核对视觉呈现效果并输出结构化结论。对每张图给出：文件名、观察到的关键视觉要素（布局/对齐/颜色/溢出/间距/字体）、与预期效果的差异、存在的问题或通过结论。只基于图片实际内容判断，禁止虚构图中不存在的元素。"
}

# --- 用 mimo 视觉模型看图（mimo -f 为数组，可同时附 prompt 文件 + 多张图片） ---
$promptPath = Join-Path $OutDir "vision-prompt.txt"
$Prompt | Out-File -LiteralPath $promptPath -Encoding utf8

$rawFile = Join-Path $OutDir "vision_raw.txt"
$reviewFile = Join-Path $OutDir "vision-review.md"
$imgList = Join-Path $OutDir "vision-images.txt"
$existing | Out-File -LiteralPath $imgList -Encoding utf8

$started = Get-Date
$job = Start-Job -ScriptBlock {
    param($Exe, $Model, $WorkspaceDir, $PromptPath, $ImageFiles)
    # Start-Job 是新进程，不继承主进程编码设置：必须在此显式设 UTF-8，否则 mimo 中文输出会乱码
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    # 视觉审查：positional message（mimo 必需，不能只靠 -f）简短引导 + prompt 文件 + 所有图片都作为 --file 附加
    # （mimo -f 为数组，视觉模型据此"看图"；mimo 要求至少一个 positional message 才会执行）
    # 注意：不加 --print-logs —— 加了会把 INFO/WARN 日志全打出来污染输出；不加则只有模型答案 + > build 一行
    $message = "请查看附加的图片，并依据图片实际内容回答问题。"
    $fileArgs = @("-f", $PromptPath)
    foreach ($img in $ImageFiles) {
        if (Test-Path -LiteralPath $img) { $fileArgs += @("-f", $img) }
    }
    $out = & $Exe run -m $Model "--dir" $WorkspaceDir $message @fileArgs 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
} -ArgumentList $mimo.Source, $Model, $WorkspaceDir, $promptPath, @($existing)

if (Wait-Job $job -Timeout $TimeoutSeconds) {
    try { $result = Receive-Job $job } catch { $result = $null }
    if ($null -ne $result) {
        $exitCode = if ($null -ne $result.Exit) { [int]$result.Exit } else { -1 }
        $output = @($result.Out)
    } else {
        $exitCode = -1
        $output = @("Receive-Job failed (job unreadable)")
    }
} else {
    try { $partial = Receive-Job $job } catch { $partial = $null }
    Stop-Job $job
    $exitCode = -2
    if ($null -ne $partial -and @($partial).Count -gt 0) { $output = @($partial) } else { $output = @("TIMEOUT after ${TimeoutSeconds}s") }
}
Remove-Job $job -Force
$elapsed = ((Get-Date) - $started).TotalSeconds

$output | Out-File -LiteralPath $rawFile -Encoding utf8

$lines = @($output | ForEach-Object {
    $raw = $_.ToString()
    # 剥离 ANSI 转义序列（ESC[...m）与尾部回车，避免日志色码残留。
    # 注意：不用 `e 转义（部分 PowerShell 5.1 不支持），用 [char]27 显式构造 ESC。
    $esc = [char]27
    $raw = [regex]::Replace($raw, $esc + "\[[0-9;]*m", "")
    $raw = $raw.TrimEnd("`r").Trim()
    $raw
})
# 过滤 mimo --print-logs 的日志噪声（INFO/WARN/ERROR/service/snapshot 等），只保留模型实际回答
$usable = @($lines | Where-Object {
    $t = $_
    ($t -ne "") -and
    (-not $t.StartsWith("mimo run")) -and
    (-not $t.StartsWith("node.exe")) -and
    (-not $t.StartsWith("CategoryInfo")) -and
    (-not $t.StartsWith("FullyQualifiedErrorId")) -and
    (-not $t.StartsWith("ROW/ID")) -and
    (-not $t.StartsWith("INFO ")) -and
    (-not $t.StartsWith("WARN ")) -and
    (-not $t.StartsWith("ERROR")) -and
    (-not $t.StartsWith("service=")) -and
    (-not $t.StartsWith("fatal: pathspec")) -and
    (-not $t.StartsWith(" failed to add")) -and
    (-not $t.StartsWith("> build")) -and
    (-not $t.StartsWith("> "))
})
$finalMsg = ($usable -join "`n").Trim()
if (-not $finalMsg) { $finalMsg = "(no textual output; see raw file)" }

$out = "> 视觉审查 (mimo CLI, exit $exitCode, $([math]::Round($elapsed,1))s, model=$Model)`n> 图片：$($existing -join ', ')`n`n$finalMsg"
$out | Out-File -LiteralPath $reviewFile -Encoding utf8

Write-Output ("EXIT_CODE=" + $exitCode)
Write-Output ("ELAPSED=" + $elapsed + "s")
Write-Output ("RAW=" + $rawFile)
Write-Output ("REVIEW=" + $reviewFile)
Write-Output ("IMAGES=" + ($existing -join ","))
