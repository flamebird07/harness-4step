param(
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$WorkspaceDir,
    [Parameter(Mandatory = $true)][string]$OutDir,
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
$kimi = Get-Command kimi -ErrorAction SilentlyContinue
if (-not $kimi) { Fail-Cli "kimi CLI not found in PATH" }

$prompt = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw
$prompt = $prompt.Trim()
if (-not $prompt) { Fail-Cli "Prompt file is empty" }
# 只读前缀（F-03/P-03 裁决）：允许只读核对 + 验证状态非 passed 时的只读回归，禁止写文件/安装依赖
$prompt = "IMPORTANT: This is a static read-only review. You may run read-only inspection commands (Get-Content, rg, git diff, git status, git diff --check) and, when the step3 validation status is blocked/not-run, read-only regression (syntax check, pytest) WITHOUT installing dependencies or modifying files. Do NOT modify any file. If a validation command is blocked by approval/permission, record it as blocked and do NOT claim verification passed. Missing tools are not a failure.`n`n" + $prompt

$rawFile = Join-Path $OutDir "kimi_raw.txt"
$msgFile = Join-Path $OutDir "step4-review.md"
$started = Get-Date
$job = Start-Job -ScriptBlock {
    param($Prompt, $Exe, $WorkspaceDir)
    $OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $out = & $Exe -p $Prompt --add-dir $WorkspaceDir 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
} -ArgumentList $prompt, $kimi.Source, $WorkspaceDir
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
$lines = @($output | ForEach-Object { if ($null -eq $_) { "" } else { $_.ToString() } })
$usable = @($lines | Where-Object {
    $t = $_.Trim()
    ($t -ne "") -and (-not $_.StartsWith("node.exe")) -and (-not $_.StartsWith("CategoryInfo")) -and (-not $_.StartsWith("FullyQualifiedErrorId"))
})
$finalMsg = ($usable -join "`n").Trim()
if (-not $finalMsg) { $finalMsg = "(no textual output; see raw file)" }
# P-08 Layer B：事后比对 → 越权写文件即回退 + 违规信号
$violated = @(Assert-Step4ReadOnly -WorkspaceDir $WorkspaceDir -OutDir $OutDir -Step4Agent "kimi CLI step4")
if ($violated.Count -gt 0) {
    $exitCode = "STEP4_WRITE_VIOLATION"
    $finalMsg = "⚠ P-08 越权写文件拦截：step4 修改了目标文件，已从快照自动回退：" + ($violated -join ", ") + "`n`n" + $finalMsg
}
$out = "> kimi CLI (exit $exitCode), $([math]::Round($elapsed,1))s`n`n$finalMsg"
$out | Out-File -LiteralPath $msgFile -Encoding utf8
Write-Output ("EXIT_CODE=" + $exitCode)
Write-Output ("ELAPSED=" + $elapsed + "s")
Write-Output ("RAW=" + $rawFile)
Write-Output ("OUTPUT=" + $msgFile)