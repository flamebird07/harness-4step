# V10 强制：本 runner 用 Start-Job + Wait-Job 且末尾输出 EXIT_CODE/ELAPSED/RAW；bash 默认 120s 将截断，调用必须 timeout=300000 + | Tee-Object -FilePath <OutDir>/run.log
param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDir,
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    [int]$TimeoutSeconds = 180,
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

# --- P4: bundle-aware codex resolution -------------------------------------
# STRATEGY (write-down): a "complete bundle" = ONE directory that simultaneously
#   contains codex.exe + codex-command-runner.exe + codex-windows-sandbox-setup.exe.
# On Windows the read-only sandbox makes codex.exe CreateProcess() the sandbox
#   setup helper. If the codex.exe picked from PATH is a bare exe and its helper
#   (a different version, discovered elsewhere on disk) is mixed onto PATH, the
#   read-only sandbox fails opaquely ("program not found" / version mismatch).
# Therefore:
#   1. ALWAYS prefer a complete bundle; prepend its dir to PATH in BOTH the
#      parent and the child Job so codex.exe and its helpers are version-matched.
#   2. If no complete bundle exists, fall back to a bare codex.exe (PATH, then
#      CODEX_HOME/.sandbox-bin). Degradation policy for the bare-exe case is
#      enforced in the helper block below (after $sandbox is known):
#        - danger-full-access : allowed, warn (no Windows sandbox helper invoked)
#        - read-only          : throw  (helper required; mismatch = opaque failure)
#        - workspace-write / default : allowed, warn (does not invoke the
#          read-only sandbox setup helper; non-fatal if helper absent/mismatched)
# ---------------------------------------------------------------------------
if (-not $env:CODEX_HOME) { $env:CODEX_HOME = Join-Path $env:USERPROFILE ".ccsc\codex-mimo" }
# Candidate dirs to scan for a complete bundle (standard Codex install locations
# only; no hardcoded user-specific paths).
$bundleCandidates = @()
$pathCodex = Get-Command codex -ErrorAction SilentlyContinue
if ($pathCodex) { $bundleCandidates += Split-Path $pathCodex.Source -Parent }
$bundleRoots = @(
    "$env:LOCALAPPDATA\OpenAI\Codex\bin",
    (Join-Path $env:CODEX_HOME ".sandbox-bin")
)
$bundleCandidates += $bundleRoots
$codexExe = ""
$bundleDir = $null
foreach ($dir in ($bundleCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)) {
    $dirsToCheck = @($dir)
    # Codex Windows installs may place a version-hash bundle one level below
    # either known root. Check the root first, then only its direct children.
    if ($bundleRoots -contains $dir) {
        $dirsToCheck += @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)
    }
    foreach ($bundleCandidate in $dirsToCheck) {
        $c = Join-Path $bundleCandidate "codex.exe"
        $r = Join-Path $bundleCandidate "codex-command-runner.exe"
        $s = Join-Path $bundleCandidate "codex-windows-sandbox-setup.exe"
        if ((Test-Path -LiteralPath $c) -and (Test-Path -LiteralPath $r) -and (Test-Path -LiteralPath $s)) {
            $codexExe = $c
            $bundleDir = $bundleCandidate
            break
        }
    }
    if ($bundleDir) { break }
}
# No complete bundle: degrade to a bare codex.exe (PATH, then CODEX_HOME).
if (-not $codexExe) {
    if ($pathCodex) {
        $codexExe = $pathCodex.Source
    } else {
        $candidate = Join-Path $env:CODEX_HOME ".sandbox-bin\codex.exe"
        if (Test-Path -LiteralPath $candidate) { $codexExe = $candidate }
    }
}
if (-not $codexExe) { throw "codex.exe not found: check PATH or set CODEX_HOME" }
$prompt = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw

$rawFile = Join-Path $OutDir "codex_raw.jsonl"
$errFile = Join-Path $OutDir "codex_stderr.txt"
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

# --- P4: apply bundle PATH + enforce bare-exe degradation policy ------------
# Complete bundle ($bundleDir set): codex.exe + helpers are co-located & version-
#   matched; prepend $bundleDir to PATH in BOTH parent and child Job. The child
#   Job re-prepends from the $HelperDir arg because Start-Job runs in a separate
#   process that does NOT inherit the parent's $env:PATH mutation. This replaces
#   the old recursive helper search, which could mix a mismatched-version helper
#   onto PATH and make the read-only sandbox fail opaquely.
# Bare-exe fallback ($bundleDir is $null): enforce the degradation policy written
#   in the resolution block above — danger-full-access proceeds with a warning;
#   read-only throws (the Windows read-only sandbox cannot work without a
#   co-located, version-matched codex-windows-sandbox-setup.exe); any other
#   sandbox mode proceeds best-effort with a warning.
if ($bundleDir) {
    $env:PATH = "$bundleDir;$env:PATH"
} else {
    switch ($sandbox) {
        "danger-full-access" {
            Write-Warning "P4: incomplete Codex bundle (bare codex.exe); running danger-full-access without the Windows sandbox helper."
        }
        "read-only" {
            throw "codex read-only sandbox requires a complete Codex bundle (codex.exe + codex-command-runner.exe + codex-windows-sandbox-setup.exe in one directory); only a bare codex.exe was found. Repair the Codex install or run with danger-full-access."
        }
        default {
            Write-Warning "P4: incomplete Codex bundle (bare codex.exe); running '$sandbox' sandbox best-effort without a co-located helper."
        }
    }
}
$sandboxHelper = $bundleDir   # passed to child Job, which re-prepends it to PATH

$started = Get-Date
# Run in a background job so $TimeoutSeconds actually bounds the call;
# a synchronous "&" would block forever on a stuck CLI.
$job = Start-Job -ScriptBlock {
    param($Prompt, $Exe, $ArgsArr, $HelperDir)
    if ($HelperDir) { $env:PATH = "$HelperDir;$env:PATH" }
    # P3 修复：Job 子进程不继承父 Console 编码，必须显式 UTF-8（同 run_claude_step12.ps1:54-55）
    $OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    # 合流后按对象类型分流：native stderr → ErrorRecord，stdout → string；二者不再互染
    $stdout = New-Object System.Collections.Generic.List[string]
    $stderr = New-Object System.Collections.Generic.List[string]
    $Prompt | & $Exe @ArgsArr 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { [void]$stderr.Add([string]$_) }
        else { [void]$stdout.Add([string]$_) }
    }
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $stdout; Err = $stderr }
} -ArgumentList $prompt, $codexExe, $args, $sandboxHelper
if (Wait-Job $job -Timeout $TimeoutSeconds) {
    $result = Receive-Job $job
    $exitCode = if ($null -ne $result.Exit) { [int]$result.Exit } else { -1 }
    $output = @($result.Out)
    $errLines = @($result.Err)
} else {
    Stop-Job $job
    $exitCode = -2
    $output = @("TIMEOUT after ${TimeoutSeconds}s")
    $errLines = @()
}
Remove-Job $job -Force
$elapsed = ((Get-Date) - $started).TotalSeconds
# stdout 原样落 codex_raw.jsonl；stderr 单独落 codex_stderr.txt（均 UTF-8）
$output | Out-File -LiteralPath $rawFile -Encoding utf8
$errLines | Out-File -LiteralPath $errFile -Encoding utf8

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
    output_files     = @{ raw = $rawFile; stderr = $errFile; output = $msgFile; evidence = (Join-Path $OutDir "evidence.json") }
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
