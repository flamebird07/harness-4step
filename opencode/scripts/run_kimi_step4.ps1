# V10 强制：本 runner 默认 300s、末尾输出 EXIT_CODE；bash 必须 timeout=300000 + | Tee-Object -FilePath <OutDir>/run.log，否则 120s 截断
param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDir,
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    [string]$Step = "step4",
    [string]$Model,
    [int]$TimeoutSeconds = 300,
    [string]$Permissions = "default"
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $PromptFile)) { throw "Prompt file not found" }
if (-not (Test-Path -LiteralPath $WorkspaceDir)) { throw "Workspace not found" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$kimi = Get-Command kimi -ErrorAction SilentlyContinue
if (-not $kimi) { throw "kimi CLI not found in PATH" }

$prompt = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw
$prompt = $prompt.Trim()
if (-not $prompt) { throw "Prompt file is empty" }

$rawFile = Join-Path $OutDir "kimi_raw.txt"
$msgFile = Join-Path $OutDir $(if ($Step -eq "step4") { "step4-review.md" } else { "$Step-output.md" })

# Step 4 is the reviewer: read-only, must never modify files.
# kimi has no read-only sandbox flag, so read-only is enforced behaviourally:
# run in -p prompt mode with --add-dir (read access) and WITHOUT --yolo/--auto
# so the reviewer cannot silently apply edits.
# kimi's -p does not reliably accept a long prompt as a single argv value
# (PowerShell/node shim can split it on content). Use the `@<file>` convention,
# which makes kimi Read the prompt file directly and is robust to long content.
$started = Get-Date
$job = Start-Job -ScriptBlock {
    param($PromptFile, $Exe, $WorkspaceDir)
    $OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $out = & $Exe -p "@$PromptFile" --output-format text --add-dir $WorkspaceDir 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
} -ArgumentList $PromptFile, $kimi.Source, $WorkspaceDir
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

# Filter out PowerShell wrapper noise injected to stderr (kimi.ps1 native-command
# errors). Keep the model's actual response lines.
$lines = @($output | ForEach-Object { if ($null -eq $_) { "" } else { $_.ToString() } })
$usable = @($lines | Where-Object {
    $t = $_.Trim()
    ($t -ne "") -and
    (-not $t.StartsWith("node.exe")) -and
    (-not $t.StartsWith("+ ")) -and
    (-not $t.StartsWith("+")) -and
    (-not $t.StartsWith("CategoryInfo")) -and
    (-not $t.StartsWith("FullyQualifiedErrorId")) -and
    (-not $t.StartsWith("kimi")) -and
    (-not $t.Contains(".ps1")) -and
    (-not $t.EndsWith("RemoteException")) -and
    (-not $t.StartsWith("To resume this session"))
})

$finalMsg = ($usable -join [Environment]::NewLine)
if (-not $finalMsg) { $finalMsg = "(no textual output; see raw file)" }

$out = "> kimi CLI (exit $exitCode), $([math]::Round($elapsed,1))s`n`n$finalMsg"
$out | Out-File -LiteralPath $msgFile -Encoding utf8

# evidence.json (advisory, machine-checkable) — does not replace step output / console lines.
$evidence = [ordered]@{
    schema_version   = 1
    task_id          = (Split-Path -Leaf $WorkspaceDir)
    step             = $Step
    attempt          = 1
    agent            = "kimi"
    exit_code        = $exitCode
    status           = if ($exitCode -eq 0) { "success" } elseif ($exitCode -eq -2) { "timeout" } else { "error" }
    output_files     = @{ raw = $rawFile; output = $msgFile; evidence = (Join-Path $OutDir "evidence.json") }
    split_parent     = $null
    timestamp        = $started.ToString("o")
    warnings         = @()
    binding_snapshot = @{ agent = "kimi"; model = $Model; permission_mode = $Permissions }
}
$evFile = Join-Path $OutDir "evidence.json"
$evidence | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $evFile -Encoding utf8

Write-Output ("EXIT_CODE=" + $exitCode)
Write-Output ("ELAPSED=" + $elapsed + "s")
Write-Output ("RAW=" + $rawFile)
Write-Output ($(if ($Step -eq "step4") { "REVIEW=" } else { "OUTPUT=" }) + $msgFile)
Write-Output ("EVIDENCE=" + $evFile)
