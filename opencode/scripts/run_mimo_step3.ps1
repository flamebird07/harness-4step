# V10 强制：本 runner 默认 Timeout 180s、末尾集中输出 EXIT_CODE/ELAPSED/RAW，无 Tee-Object 实时透传；bash 调用必须 timeout=300000 + | Tee-Object -FilePath <OutDir>/run.log，否则 >120s 的 mimo/codex 长 prompt 必被 120s 截断、EXIT/ELAPSED 丢失、误判 hang（违规10）
param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDir,
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    [string]$Model = "xiaomi/mimo-v2.5-pro",
    [string]$Step = "step3",
    [int]$TimeoutSeconds = 180,
    [string]$Permissions = "dangerously-skip-permissions"
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
$msgFile = Join-Path $OutDir $(if ($Step -eq "step4") { "step4-review.md" } else { "$Step-output.md" })

# F-P05/F-P10: 删除原 prompt 字符清理段（stdin 路径下不经过 argv 拆词，清理纯损语义）
# 注：argv 路径下的字符拆词风险由 F-P01（事件驱动 async drain）+ F-P02（套娃保留 + UTF-8）共同避免

$started = Get-Date
$warnings = @()

# 仅对已存在的文件/目录取 8.3 短路径。无法解析、8.3 被卷禁用或路径不存在时返回原路径；
# 命令串仍会为每个路径保留双引号，因此含空格的兜底路径也可安全传递给 cmd。
function ConvertTo-ShortPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved) {
        return $Path
    }

    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $fullPath = $resolved.Path
        $item = Get-Item -LiteralPath $fullPath -Force

        if ($item.PSIsContainer) {
            $shortPath = $fso.GetFolder($fullPath).ShortPath
        } else {
            $shortPath = $fso.GetFile($fullPath).ShortPath
        }

        if ($shortPath) { return $shortPath }
    } catch {
        # 保留原路径；下方命令串的双引号负责含空格路径的兜底。
    }

    return $resolved.Path
}

$npmDir = Split-Path $mimo.Source -Parent
$nodeExe = if (Test-Path (Join-Path $npmDir "node.exe")) { Join-Path $npmDir "node.exe" } else { (Get-Command node).Source }
$mimoJs = Join-Path $npmDir "node_modules\@mimo-ai\cli\bin\mimo"
if (-not (Test-Path -LiteralPath $mimoJs)) { throw "Cannot resolve mimo JS entry: $mimoJs" }

$stdoutFile = Join-Path $OutDir "mimo_step3_stdout.tmp"
$stderrFile = Join-Path $OutDir "mimo_step3_stderr.tmp"
Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue

$nodeExeShort = ConvertTo-ShortPath $nodeExe
$mimoJsShort = ConvertTo-ShortPath $mimoJs
$workspaceDirShort = ConvertTo-ShortPath $WorkspaceDir
$promptFileShort = ConvertTo-ShortPath $PromptFile
$stdoutFileShort = ConvertTo-ShortPath $stdoutFile
$stderrFileShort = ConvertTo-ShortPath $stderrFile

$commandLine = ('"{0}" "{1}" run -m "{2}" --dir "{3}" --dangerously-skip-permissions < "{4}" 1> "{5}" 2> "{6}"' -f `
    $nodeExeShort, $mimoJsShort, $Model, $workspaceDirShort, $promptFileShort, $stdoutFileShort, $stderrFileShort)

$batchFile = Join-Path $OutDir "mimo_step3_run.cmd"
[System.IO.File]::WriteAllText(
    $batchFile,
    "@echo off`r`n$commandLine`r`n",
    [System.Text.Encoding]::ASCII
)
$batchFileShort = ConvertTo-ShortPath $batchFile
$batchFileArg = if ($batchFileShort -match '\s') { '"' + $batchFileShort + '"' } else { $batchFileShort }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $env:ComSpec
$psi.Arguments = '/c ' + $batchFileArg
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi

try {
    if (-not $proc.Start()) { throw "Failed to start cmd.exe" }

    $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) {
        $killedPid = $proc.Id
        & taskkill.exe /PID $killedPid /T /F *> $null
        $taskkillExitCode = $LASTEXITCODE
        $warnings += "timeout: taskkill /PID $killedPid /T /F exit_code=$taskkillExitCode"
        try { $proc.WaitForExit(5000) } catch {}
        $exitCode = -2
        $output = @("TIMEOUT after ${TimeoutSeconds}s")
    } else {
        $exitCode = $proc.ExitCode
        $output = @()

        if (Test-Path -LiteralPath $stdoutFile) {
            $stdout = [System.IO.File]::ReadAllText($stdoutFile, [System.Text.Encoding]::UTF8)
            if ($stdout) { $output += [regex]::Split($stdout, "`r?`n") }
        }
        if (Test-Path -LiteralPath $stderrFile) {
            $stderr = [System.IO.File]::ReadAllText($stderrFile, [System.Text.Encoding]::UTF8)
            if ($stderr) { $output += [regex]::Split($stderr, "`r?`n") }
        }
    }
} finally {
    $proc.Dispose()
}
$elapsed = ((Get-Date) - $started).TotalSeconds

$output | Out-File -LiteralPath $rawFile -Encoding utf8
$textRepetition = (($output | ForEach-Object { if ($null -eq $_) { "" } else { $_.ToString() } }) -join "`n").Contains("Text repetition detected")
if ($textRepetition) {
    $warnings += "text_repetition"
    $exitCode = 13
    Write-Output "INFRA_FAILURE:text_repetition"
}

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
    step             = $Step
    attempt          = 1
    agent            = "mimo"
    exit_code        = $exitCode
    status           = if ($textRepetition) { "infrastructure_error" } elseif ($exitCode -eq 0) { "success" } elseif ($exitCode -eq -2) { "timeout" } else { "error" }
    output_files     = @{ raw = $rawFile; output = $msgFile; evidence = (Join-Path $OutDir "evidence.json") }
    split_parent     = $null
    timestamp        = $started.ToString("o")
    warnings         = $warnings
    binding_snapshot = @{ agent = "mimo"; model = $Model; permission_mode = $Permissions }
}
$evFile = Join-Path $OutDir "evidence.json"
$evidence | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $evFile -Encoding utf8

Write-Output ("EXIT_CODE=" + $exitCode)
Write-Output ("ELAPSED=" + $elapsed + "s")
Write-Output ("RAW=" + $rawFile)
Write-Output ($(if ($Step -eq "step4") { "REVIEW=" } else { "OUTPUT=" }) + $msgFile)
Write-Output ("EVIDENCE=" + $evFile)
