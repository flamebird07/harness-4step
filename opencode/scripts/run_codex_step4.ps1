# V10 强制：本 runner 用 Start-Job + Wait-Job 且末尾输出 EXIT_CODE/ELAPSED/RAW；bash 默认 120s 将截断，调用必须 timeout=300000 + | Tee-Object -FilePath <OutDir>/run.log
param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDir,
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    [int]$TimeoutSeconds = 300,
    [string]$Step = "step4",
    [string]$Model,
    [ValidateSet("default","read_only","bypassPermissions","read-only","workspace-write","danger-full-access")]
    [string]$Permissions = "read_only"
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $PromptFile)) { throw "Prompt file not found: $PromptFile" }
if (-not (Test-Path -LiteralPath $WorkspaceDir)) { throw "Workspace not found: $WorkspaceDir" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# Resolve codex: PATH first, then CODEX_HOME/.sandbox-bin/codex.exe (no hardcoded user paths).
$codexCmd = Get-Command codex -ErrorAction SilentlyContinue
$codexExe = if ($codexCmd) { $codexCmd.Source } else { "" }
if (-not $codexExe) {
    if (-not $env:CODEX_HOME) { $env:CODEX_HOME = Join-Path $env:USERPROFILE ".ccsc\codex-mimo" }
    $candidate = Join-Path $env:CODEX_HOME ".sandbox-bin\codex.exe"
    if (Test-Path -LiteralPath $candidate) { $codexExe = $candidate }
}
if (-not $codexExe) { throw "codex.exe not found: check PATH or set CODEX_HOME" }
if (-not $env:CODEX_HOME) { $env:CODEX_HOME = Join-Path $env:USERPROFILE ".ccsc\codex-mimo" }
$prompt = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw

$rawFile = Join-Path $OutDir "codex_raw.jsonl"
if ($Step -eq "step4") {
    $msgFile = Join-Path $OutDir "step4-review.md"
} else {
    $msgFile = Join-Path $OutDir "$Step-output.md"
}

# 映射 Permissions -> sandbox；step4 强制 read-only
$sandbox = "read-only"
if ($Step -eq "step4") {
    $sandbox = "read-only"
} else {
    switch ($Permissions) {
        "read_only" { $sandbox = "read-only" }
        "read-only" { $sandbox = "read-only" }
        "default" { $sandbox = "workspace-write" }
        "bypassPermissions" { $sandbox = "danger-full-access" }
        "workspace-write" { $sandbox = "workspace-write" }
        "danger-full-access" { $sandbox = "danger-full-access" }
        default { $sandbox = "workspace-write" }
    }
}

$args = @(
    "exec",
    "--skip-git-repo-check",
    "--ephemeral",
    "--sandbox", $sandbox,
    "--json",
    "-C", $WorkspaceDir
)
if ($sandbox -eq "read-only") {
    $args += '-c'
    $args += 'sandbox_permissions=["disk-full-read-access"]'
}
if ($Model) {
    $args += "-m"
    $args += $Model
}

# Windows read-only sandbox needs codex-windows-sandbox-setup.exe resolvable
# from PATH (codex launches it via CreateProcess). The helper ships under the
# Codex install bin dir, which is normally not on PATH. Discover it and extend
# PATH so the sandbox helper is found; otherwise read-only sandbox fails with
# "program not found" and the reviewer cannot even Read files.
$sandboxHelper = Get-ChildItem -Path "$env:LOCALAPPDATA\OpenAI\Codex\bin" -Recurse -Filter "codex-windows-sandbox-setup.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty DirectoryName
if (-not $sandboxHelper) {
    $sandboxHelper = Get-ChildItem -Path "$env:USERPROFILE\.ccsc" -Recurse -Filter "codex-windows-sandbox-setup.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty DirectoryName
}
if ($sandboxHelper) {
    $env:PATH = "$sandboxHelper;$env:PATH"
}

$started = Get-Date
# Run in a background job so $TimeoutSeconds actually bounds the call;
# a synchronous "&" would block forever on a stuck CLI.
$job = Start-Job -ScriptBlock {
    param($Prompt, $Exe, $ArgsArr, $HelperDir)
    if ($HelperDir) { $env:PATH = "$HelperDir;$env:PATH" }
    $out = $Prompt | & $Exe @ArgsArr 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
} -ArgumentList $prompt, $codexExe, $args, $sandboxHelper
if (Wait-Job $job -Timeout $TimeoutSeconds) {
    $result = Receive-Job $job
    $exitCode = if ($null -ne $result.Exit) { [int]$result.Exit } else { -1 }
    $output = @($result.Out)
} else {
    Stop-Job $job
    $exitCode = -2
    $output = @("TIMEOUT after ${TimeoutSeconds}s")
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
    $out = "> codex CLI ($exitCode), {0:N1}s, model={1}, sandbox={2}`n`n{3}" -f $elapsed, $(if($Model){"$Model"}else{"default"}), $sandbox, $finalMsg
} else {
    $out = "> codex CLI ($exitCode), {0:N1}s, model={1}, sandbox={2}, NO agent_message in output`n`n{3}" -f $elapsed, $(if($Model){"$Model"}else{"default"}), $sandbox, ($output -join "`n")
}
$out | Out-File -LiteralPath $msgFile -Encoding utf8

# evidence.json (advisory, machine-checkable) — does not replace step output / console lines.
$evidence = [ordered]@{
    schema_version   = 1
    task_id          = (Split-Path -Leaf $WorkspaceDir)
    step             = $Step
    attempt          = 1
    agent            = "codex"
    exit_code        = $exitCode
    status           = if ($exitCode -eq 0) { "success" } elseif ($exitCode -eq -2) { "timeout" } else { "error" }
    output_files     = @{ raw = $rawFile; output = $msgFile; evidence = (Join-Path $OutDir "evidence.json") }
    split_parent     = $null
    timestamp        = $started.ToString("o")
    warnings         = @($(if (-not $finalMsg) { "no agent_message" } else { $null }) | Where-Object { $_ })
    binding_snapshot = @{ agent = "codex"; model = $Model; permission_mode = $Permissions; sandbox = $sandbox }
}
$evFile = Join-Path $OutDir "evidence.json"
$evidence | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $evFile -Encoding utf8

Write-Output "EXIT_CODE=$exitCode"
Write-Output "ELAPSED=${elapsed}s"
Write-Output "RAW=$rawFile"
if ($Step -eq "step4") {
    Write-Output "REVIEW=$msgFile"
} else {
    Write-Output "OUTPUT=$msgFile"
}
Write-Output "EVIDENCE=$evFile"
