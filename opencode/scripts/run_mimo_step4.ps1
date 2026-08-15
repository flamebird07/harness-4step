param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDir,
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    [string]$Model = "xiaomi/mimo-v2.5-pro",
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Fail-Cli([string]$Message) {
    Write-Output "EXIT_CODE=-3"
    Write-Output ("ERROR=" + $Message)
    exit 1
}
if (-not (Test-Path -LiteralPath $PromptFile)) { Fail-Cli "Prompt file not found: $PromptFile" }
if (-not (Test-Path -LiteralPath $WorkspaceDir)) { Fail-Cli "Workspace not found: $WorkspaceDir" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# P-08 Layer B：step4 只读快照（复用 helper，不复制逻辑）
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "step4_readonly_guard.ps1")
Save-Step4Snapshot -WorkspaceDir $WorkspaceDir -OutDir $OutDir

$mimo = Get-Command mimo -ErrorAction SilentlyContinue
if (-not $mimo) { Fail-Cli "mimo CLI not found in PATH" }

$prompt = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw
$prompt = $prompt.Trim()
if (-not $prompt) { Fail-Cli "Prompt file is empty" }

# 对齐 Hermes run_cli.py apply_step_prompt_prefix：agent（mimo 防虚构）前缀在前，step4 只读前缀在后
$prefix = "【严格约束】不准虚构任何内容. 只能基于实际代码/文件内容输出. 如果不确定, 输出'我不确定'. 不准编造命令、参数、路径、降级路径.`n" +
          "IMPORTANT: This is a static read-only review. You may run read-only inspection commands (Get-Content, rg, git diff, git status, git diff --check) and, when the step3 validation status is blocked/not-run, read-only regression (syntax check, pytest) WITHOUT installing dependencies or modifying files. Do NOT modify any file. If a validation command is blocked by approval/permission, record it as blocked and do NOT claim verification passed. Missing tools are not a failure.`n`n"
$prompt = $prefix + $prompt
# prompt 经 -f 文件传入（对齐 Hermes run_cli.py prompt_mode="file"）：避免 Windows 8191 字符命令行截断；
# mimo 不吃 stdin，位置参数传长 prompt 会被截断，-f 无此问题
$promptPath = Join-Path $OutDir "prompt.txt"
$prompt | Out-File -LiteralPath $promptPath -Encoding utf8

$rawFile = Join-Path $OutDir "mimo_raw.txt"
$msgFile = Join-Path $OutDir "step4-review.md"

$started = Get-Date
$job = Start-Job -ScriptBlock {
    param($Exe, $Model, $WorkspaceDir, $PromptPath)
    $out = & $Exe run --print-logs -m $Model "--dir" $WorkspaceDir -f $PromptPath 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
} -ArgumentList $mimo.Source, $Model, $WorkspaceDir, $promptPath
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
    # 保留已产生的部分输出：用于诊断超时源于模型工作 / CLI 卡死 / prompt 需拆分（对齐 Hermes run_cli.py:343-351）
    try { $partial = Receive-Job $job } catch { $partial = $null }
    Stop-Job $job
    $exitCode = -2
    if ($null -ne $partial -and @($partial).Count -gt 0) { $output = @($partial) } else { $output = @("TIMEOUT after ${TimeoutSeconds}s") }
}
Remove-Job $job -Force
$elapsed = ((Get-Date) - $started).TotalSeconds
# P-08 Layer B：事后比对 → 越权写文件即回退 + 违规信号
$violated = @(Assert-Step4ReadOnly -WorkspaceDir $WorkspaceDir -OutDir $OutDir -Step4Agent "mimo CLI step4")
if ($violated.Count -gt 0) { $exitCode = "STEP4_WRITE_VIOLATION" }
Write-Output ("EXIT_CODE=" + $exitCode)
Write-Output ("ELAPSED=" + $elapsed + "s")

$output | Out-File -LiteralPath $rawFile -Encoding utf8

$lines = @($output | ForEach-Object { if ($null -eq $_) { "" } else { $_.ToString() } })
$usable = @($lines | Where-Object {
    $t = $_.Trim()
    ($t -ne "") -and
    (-not $_.StartsWith("mimo run")) -and
    (-not $_.StartsWith("node.exe")) -and
    (-not $_.StartsWith("CategoryInfo")) -and
    (-not $_.StartsWith("FullyQualifiedErrorId")) -and
    (-not $_.StartsWith("ROW/ID"))
})

$finalMsg = ($usable -join "`n").Trim()
if (-not $finalMsg) { $finalMsg = "(no textual output; see raw file)" }
if ($violated.Count -gt 0) {
    $finalMsg = "⚠ P-08 越权写文件拦截：step4 修改了目标文件，已从快照自动回退：" + ($violated -join ", ") + "`n`n" + $finalMsg
}

$out = "> mimo CLI (exit $exitCode), $([math]::Round($elapsed,1))s, model=$Model`n`n$finalMsg"
$out | Out-File -LiteralPath $msgFile -Encoding utf8

Write-Output ("RAW=" + $rawFile)
Write-Output ("REVIEW=" + $msgFile)