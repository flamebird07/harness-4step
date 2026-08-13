param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDir,
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
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

# Resolve codex: PATH first, then CODEX_HOME/.sandbox-bin/codex.exe (no hardcoded user paths).
$codexCmd = Get-Command codex -ErrorAction SilentlyContinue
$codexExe = if ($codexCmd) { $codexCmd.Source } else { "" }
if (-not $codexExe) {
    if (-not $env:CODEX_HOME) { $env:CODEX_HOME = Join-Path $env:USERPROFILE ".ccsc\codex-mimo" }
    $candidate = Join-Path $env:CODEX_HOME ".sandbox-bin\codex.exe"
    if (Test-Path -LiteralPath $candidate) { $codexExe = $candidate }
}
if (-not $codexExe) { Fail-Cli "codex.exe not found: check PATH or set CODEX_HOME" }
if (-not $env:CODEX_HOME) { $env:CODEX_HOME = Join-Path $env:USERPROFILE ".ccsc\codex-mimo" }
$prompt = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw
# 脚本注入 step4 只读前缀（对齐 Hermes run_cli.py STEP_PROMPT_PREFIXES["step4"]）：
# codex 沙箱为 danger-full-access，无系统级只读拦截，只读约束靠 prompt 落地 + 事后基线回退
$prompt = "IMPORTANT: This is a static read-only review. You may run read-only inspection commands (Get-Content, rg, git diff, git status) to verify code. Do NOT modify any file, do NOT run tests/builds/installs. Missing tools are not a failure.`n`n" + $prompt

$rawFile = Join-Path $OutDir "codex_raw.jsonl"
$msgFile = Join-Path $OutDir "step4-review.md"

$args = @(
    "exec",
    "--skip-git-repo-check",
    "--ephemeral",
    "--sandbox", "danger-full-access",
    "--json",
    "-C", "$WorkspaceDir"
)

$started = Get-Date
# Run in a background job so $TimeoutSeconds actually bounds the call;
# a synchronous "&" would block forever on a stuck CLI.
$job = Start-Job -ScriptBlock {
    param($Prompt, $Exe, $ArgsArr)
    $out = $Prompt | & $Exe @ArgsArr 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
} -ArgumentList $prompt, $codexExe, $args
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

$output | Out-File -LiteralPath $rawFile -Encoding utf8

$messages = @()
foreach ($line in $output | ForEach-Object { $_.ToString() }) {
    if (-not $line.Trim()) { continue }
    try {
        $obj = $line | ConvertFrom-Json
    } catch { continue }
    if ($obj.type -eq "item.completed" -and $obj.item.type -eq "agent_message") {
        $messages += $obj.item.text
    }
}

$finalMsg = if ($messages.Count -gt 0) { $messages[-1] } else { "" }

if ($finalMsg) {
    $out = "> codex CLI ($exitCode), {0:N1}s`n`n{1}" -f $elapsed, $finalMsg
} else {
    $out = "> codex CLI ($exitCode), {0:N1}s, NO agent_message in output`n`n{1}" -f $elapsed, ($output -join "`n")
}
$out | Out-File -LiteralPath $msgFile -Encoding utf8

Write-Output "EXIT_CODE=$exitCode"
Write-Output "ELAPSED=${elapsed}s"
Write-Output "RAW=$rawFile"
Write-Output "REVIEW=$msgFile"