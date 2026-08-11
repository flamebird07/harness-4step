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

if (-not (Test-Path -LiteralPath $PromptFile)) { throw "Prompt file not found: $PromptFile" }
if (-not (Test-Path -LiteralPath $WorkspaceDir)) { throw "Workspace not found: $WorkspaceDir" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$mimo = Get-Command mimo -ErrorAction SilentlyContinue
if (-not $mimo) { throw "mimo CLI not found in PATH" }

$prompt = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw
$prompt = $prompt.Trim()
if (-not $prompt) { throw "Prompt file is empty" }

$rawFile = Join-Path $OutDir "mimo_raw.txt"
$msgFile = Join-Path $OutDir "step4-review.md"

$started = Get-Date
$job = Start-Job -ScriptBlock {
    param($Prompt, $Exe, $Model, $WorkspaceDir)
    $out = & $Exe run -m $Model "--dir" $WorkspaceDir $Prompt 2>&1
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

$out = "> mimo CLI (exit $exitCode), $([math]::Round($elapsed,1))s, model=$Model`n`n$finalMsg"
$out | Out-File -LiteralPath $msgFile -Encoding utf8

Write-Output ("RAW=" + $rawFile)
Write-Output ("REVIEW=" + $msgFile)