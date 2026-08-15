param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDir,
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    [int]$TimeoutSeconds = 300,
    # P-09 Layer A：可选覆盖 sandbox 模式。默认 "danger-full-access"（本机可用的普通访问模式，
    # 不依赖只读沙箱辅助程序，保证 codex 可启动）。传 "read-only"/"workspace-write" 表示用户
    # 想尝试沙箱加固；若本机不支持，脚本在启动前自动回退 "danger-full-access" 并输出 WARN。
    # 只读的机械保障一律由 Layer B（step4_readonly_guard.ps1）承担，不依赖沙箱。
    [string]$Sandbox = "danger-full-access"
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

# P-09 Layer A：启动前检测只读沙箱是否可用；不可用立即回退普通访问模式，避免 codex 启动失败。
# danger-full-access 无需沙箱辅助程序，天然可用；其余沙箱模式依赖本机安装的沙箱辅助程序。
function Test-CodexSandboxSupport([string]$Mode) {
    if ($Mode -eq "danger-full-access") { return $true }
    $binDir = Join-Path $env:CODEX_HOME ".sandbox-bin"
    # 本机实际安装的沙箱辅助程序为 codex-command-runner-*.exe（多个版本并存，用通配匹配取其一）。
    $helper = Get-ChildItem -LiteralPath $binDir -Filter "codex-command-runner-*.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    return ($null -ne $helper)
}
$effectiveSandbox = $Sandbox
if ($Sandbox -ne "danger-full-access" -and -not (Test-CodexSandboxSupport -Mode $Sandbox)) {
    Write-Output ("WARN=SANDBOX_UNAVAILABLE_FALLBACK: requested '{0}' not supported, falling back to danger-full-access" -f $Sandbox)
    $effectiveSandbox = "danger-full-access"
}

$prompt = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw
# 脚本注入 step4 只读前缀（对齐 Hermes run_cli.py STEP_PROMPT_PREFIXES["step4"]，P-03 裁决）：
# 只读白名单见 opencode/SKILL.md#codex-CLI-调用规范。step3 验证状态为 blocked/not-run 时允许补跑只读回归；
# 回归被批准门拦截时必须如实记 blocked，不得判通过。只读的机械保障由 step4_readonly_guard.ps1（P-08）提供。
$prompt = "IMPORTANT: This is a static read-only review. You may run read-only inspection commands (Get-Content, rg, git diff, git status, git diff --check) and, when the step3 validation status is blocked/not-run, read-only regression (syntax check, pytest) WITHOUT installing dependencies or modifying files. Do NOT modify any file. If a validation command is blocked by approval/permission, record it as blocked and do NOT claim verification passed. Missing tools are not a failure.`n`n" + $prompt

$rawFile = Join-Path $OutDir "codex_raw.jsonl"
$msgFile = Join-Path $OutDir "step4-review.md"

$args = @(
    "exec",
    "--skip-git-repo-check",
    "--ephemeral",
    "--sandbox", $effectiveSandbox,   # P-09 Layer A：默认普通访问模式；仅当显式请求且本机支持时才用沙箱；Layer B 快照比对始终兜底
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

# P-08 Layer B：事后比对 → 越权写文件即回退 + 违规信号
$violated = @(Assert-Step4ReadOnly -WorkspaceDir $WorkspaceDir -OutDir $OutDir -Step4Agent "codex CLI step4")
if ($violated.Count -gt 0) {
    $exitCode = "STEP4_WRITE_VIOLATION"
    $finalMsg = "⚠ P-08 越权写文件拦截：step4 修改了目标文件，已从快照自动回退：" + ($violated -join ", ") + "`n`n" + $finalMsg
}

if ($finalMsg) {
    $out = "> codex CLI ($exitCode), {0:N1}s`n`n{1}" -f $elapsed, $finalMsg
} else {
    $out = "> codex CLI ($exitCode), {0:N1}s, NO agent_message in output`n`n{1}" -f $elapsed, ($output -join "`n")
}
$out | Out-File -LiteralPath $msgFile -Encoding utf8

# P-09 Layer A：二次兜底——即便启动前检测通过，运行时仍可能报沙箱错误，此时如实 WARN，Layer B 快照比对始终兜底。
# 默认 danger-full-access 无沙箱，跳过此检查，避免误报。
if ($effectiveSandbox -ne "danger-full-access") {
    $sandboxErr = @($output | ForEach-Object { $_.ToString() } | Where-Object { $_ -match "sandbox" -and ($_ -match "not support|unsupported|invalid|unknown|Error") })
    if ($sandboxErr.Count -gt 0) { Write-Output "WARN=SANDBOX_READONLY_UNAVAILABLE" }
}

Write-Output "EXIT_CODE=$exitCode"
Write-Output "ELAPSED=${elapsed}s"
Write-Output "RAW=$rawFile"
Write-Output "REVIEW=$msgFile"