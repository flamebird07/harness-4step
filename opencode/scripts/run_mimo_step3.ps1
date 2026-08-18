param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDir,
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    [string]$Model = "xiaomi/mimo-v2.5-pro",
    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $PromptFile)) { throw "Prompt file not found" }
if (-not (Test-Path -LiteralPath $WorkspaceDir)) { throw "Workspace not found" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$mimo = Get-Command mimo -ErrorAction SilentlyContinue
if (-not $mimo) { throw "mimo CLI not found in PATH" }

$prompt = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw
$prompt = $prompt.Trim()
if (-not $prompt) { throw "Prompt file is empty" }

$rawFile = Join-Path $OutDir "mimo_step3_raw.txt"
$msgFile = Join-Path $OutDir "step3-output.md"

$started = Get-Date
# --dangerously-skip-permissions lets the implementer edit files (Step 3 role).
$job = Start-Job -ScriptBlock {
    param($Prompt, $Exe, $Model, $WorkspaceDir)
    $OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    # Feed the prompt via stdin instead of argv: long prompts break Windows argv
    # parsing (same as kimi). mimo.ps1 forwards pipeline input to the message.
    $out = $Prompt | & $Exe run -m $Model --dir $WorkspaceDir --dangerously-skip-permissions 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
} -ArgumentList $prompt, $mimo.Source, $Model, $WorkspaceDir
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

$lines = @($output | ForEach-Object { if ($null -eq $_) { "" } else { $_.ToString() } })
$usable = @($lines | Where-Object {
    $t = $_.Trim()
    ($t -ne "") -and
    (-not $t.StartsWith("node.exe")) -and
    (-not $t.StartsWith("+ ")) -and
    (-not $t.StartsWith("+")) -and
    (-not $t.StartsWith("CategoryInfo")) -and
    (-not $t.StartsWith("FullyQualifiedErrorId")) -and
    (-not $t.StartsWith("mimo")) -and
    (-not $t.Contains(".ps1")) -and
    (-not $t.EndsWith("RemoteException")) -and
    (-not $t.StartsWith("To resume"))
})

$finalMsg = ($usable -join [Environment]::NewLine)
if (-not $finalMsg) { $finalMsg = "(no textual output; see raw file)" }

$out = "> mimo CLI (exit $exitCode), $([math]::Round($elapsed,1))s, model=$Model`n`n$finalMsg"
$out | Out-File -LiteralPath $msgFile -Encoding utf8

# evidence.json (advisory, machine-checkable) — does not replace step output / console lines.
$evidence = [ordered]@{
    schema_version   = 1
    task_id          = (Split-Path -Leaf $WorkspaceDir)
    step             = "step3"
    attempt          = 1
    agent            = "mimo"
    exit_code        = $exitCode
    status           = if ($exitCode -eq 0) { "success" } elseif ($exitCode -eq -2) { "timeout" } else { "error" }
    binding_snapshot = @{ agent = "mimo"; permission_mode = "dangerously-skip-permissions" }
}
$evFile = Join-Path $OutDir "evidence.json"
$evidence | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $evFile -Encoding utf8

Write-Output ("EXIT_CODE=" + $exitCode)
Write-Output ("ELAPSED=" + $elapsed + "s")
Write-Output ("RAW=" + $rawFile)
Write-Output ("OUTPUT=" + $msgFile)