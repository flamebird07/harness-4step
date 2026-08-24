# V10 警示：本 runner 用 Start-Job + Wait-Job -Timeout 且 103-106 行才输出 EXIT_CODE/ELAPSED/RAW；bash 默认 120s 将先截断本 runner，调用方必须 bash --timeout 300000 + | Tee-Object -FilePath <OutDir>/run.log，否则 -2 超时无法触发上游拆分
param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDir,
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    [string]$Step = "step1",
    [int]$TimeoutSeconds = 300,
    [ValidateSet("default", "acceptEdits", "bypassPermissions")]
    [string]$Permissions = "default"
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $PromptFile)) { throw "Prompt file not found: $PromptFile" }
if (-not (Test-Path -LiteralPath $WorkspaceDir)) { throw "Workspace not found: $WorkspaceDir" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) { throw "claude CLI not found in PATH" }
$claudeExe = Join-Path (Split-Path -Parent $claude.Source) "node_modules\@anthropic-ai\claude-code\bin\claude.exe"
if (-not (Test-Path -LiteralPath $claudeExe)) {
    throw "Claude executable not found at $claudeExe (resolved from $($claude.Source))"
}

$prompt = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw
$prompt = $prompt.Trim()
if (-not $prompt) { throw "Prompt file is empty" }

# 保留当前会话的 ANTHROPIC_* 环境变量；本机凭据代理可能依赖这些变量。

$rawFile = Join-Path $OutDir "claude_raw.txt"
$msgFile = Join-Path $OutDir "$Step-output.md"

$started = Get-Date
# Do not put claude.exe behind Start-Job + a PowerShell pipeline.  On Windows
# that combination can leave stdin or a child node process alive after the job
# timeout, turning the next OpenCode step into a phantom >240s timeout.
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $claudeExe
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
# Windows PowerShell 5.1 exposes StandardInputEncoding without a setter; the
# redirected StreamWriter already defaults to UTF-8, so do not assign it.
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
$psi.WorkingDirectory = $WorkspaceDir
$psi.ArgumentList.Add("-p")
$psi.ArgumentList.Add($prompt)
$psi.ArgumentList.Add("--output-format")
$psi.ArgumentList.Add("text")
$psi.ArgumentList.Add("--add-dir")
$psi.ArgumentList.Add($WorkspaceDir)
if ($Permissions -ne "default") {
    $psi.ArgumentList.Add("--permission-mode")
    $psi.ArgumentList.Add($Permissions)
}
$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
if (-not $proc.Start()) { throw "Failed to start Claude executable: $claudeExe" }
$stdoutTask = $proc.StandardOutput.ReadToEndAsync()
$stderrTask = $proc.StandardError.ReadToEndAsync()
$warnings = @()
if ($proc.WaitForExit($TimeoutSeconds * 1000)) {
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $output = @($stdout, $stderr | Where-Object { $_ })
} else {
    # /T terminates descendants created by the CLI as well as its launcher.
    & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null
    $proc.WaitForExit()
    $exitCode = -2
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $output = @("TIMEOUT after ${TimeoutSeconds}s (Claude process tree terminated)", $stdout, $stderr | Where-Object { $_ })
    $warnings += "timeout at ${TimeoutSeconds}s"
}
$proc.Dispose()
$elapsed = ((Get-Date) - $started).TotalSeconds

$output | Out-File -LiteralPath $rawFile -Encoding utf8

$lines = @($output | ForEach-Object { if ($null -eq $_) { "" } else { $_.ToString() } })
$usable = @($lines | Where-Object {
    $t = $_.Trim()
    ($t -ne "") -and
    (-not $_.StartsWith("claude")) -and
    (-not $_.StartsWith("node.exe")) -and
    (-not $_.StartsWith("CategoryInfo")) -and
    (-not $_.StartsWith("FullyQualifiedErrorId")) -and
    (-not $_.StartsWith("Connection")) 
})

$finalMsg = ($usable -join "`n").Trim()
if (-not $finalMsg) { $finalMsg = "(no textual output; see raw file)" }

$out = "> claude CLI (exit $exitCode), $([math]::Round($elapsed,1))s`n`n$finalMsg"
$out | Out-File -LiteralPath $msgFile -Encoding utf8

# evidence.json (advisory, machine-checkable) — does not replace step output / console lines.
$evidence = [ordered]@{
    schema_version   = 1
    task_id          = (Split-Path -Leaf $WorkspaceDir)
    step             = $Step
    attempt          = 1
    agent            = "claude"
    exit_code        = $exitCode
    status           = if ($exitCode -eq 0) { "success" } elseif ($exitCode -eq -2) { "timeout" } else { "error" }
    output_files     = @{ raw = $rawFile; output = $msgFile; evidence = (Join-Path $OutDir "evidence.json") }
    split_parent     = $null
    timestamp        = $started.ToString("o")
    warnings         = $warnings
    binding_snapshot = @{ agent = "claude"; permission_mode = $Permissions; model = $null }
}
$evFile = Join-Path $OutDir "evidence.json"
$evidence | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $evFile -Encoding utf8

Write-Output ("EXIT_CODE=" + $exitCode)
Write-Output ("ELAPSED=" + $elapsed + "s")
Write-Output ("RAW=" + $rawFile)
Write-Output ("OUTPUT=" + $msgFile)
Write-Output ("EVIDENCE=" + $evFile)
