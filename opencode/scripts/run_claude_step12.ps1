param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDir,
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    [string]$Step = "step1",
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $PromptFile)) { throw "Prompt file not found: $PromptFile" }
if (-not (Test-Path -LiteralPath $WorkspaceDir)) { throw "Workspace not found: $WorkspaceDir" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) { throw "claude CLI not found in PATH" }

$prompt = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw
$prompt = $prompt.Trim()
if (-not $prompt) { throw "Prompt file is empty" }

# Strip any ANTHROPIC_* overrides inherited from the shell environment.
# claude-code reads its own credentials/base-url from ~/.claude/settings.json;
# leftover shell vars (e.g. deepseek proxy) point at a dead endpoint and hang.
foreach ($name in @("ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL",
                    "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                    "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
                    "ANTHROPIC_DEFAULT_FABLE_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME", "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME")) {
    Remove-Item ("Env:" + $name) -ErrorAction SilentlyContinue
}

$rawFile = Join-Path $OutDir "claude_raw.txt"
$msgFile = Join-Path $OutDir "$Step-output.md"

$cmd = @("-p", "--output-format", "text")   # prompt 经管道喂 stdin，避免 8191 字符命令行截断

$started = Get-Date
$job = Start-Job -ScriptBlock {
    param($Prompt, $Exe, $Cmd)
    $out = $Prompt | & $Exe @Cmd 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
} -ArgumentList $prompt, $claude.Source, $cmd
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

Write-Output ("EXIT_CODE=" + $exitCode)
Write-Output ("ELAPSED=" + $elapsed + "s")
Write-Output ("RAW=" + $rawFile)
Write-Output ("OUTPUT=" + $msgFile)