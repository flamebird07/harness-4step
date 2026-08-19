param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDir,
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    [string]$Model = "xiaomi/mimo-v2.5-pro",
    [int]$TimeoutSeconds = 300,
    [string]$Permissions = "default"
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

# F-P05/F-P10: 删除原 prompt 字符清理段（stdin 路径下不经过 argv 拆词，清理纯损语义）
# 注：argv 路径下的字符拆词风险由 F-P01（事件驱动 async drain）+ F-P02（套娃保留 + UTF-8）共同避免
$rawFile = Join-Path $OutDir "mimo_raw.txt"
$msgFile = Join-Path $OutDir "step4-review.md"

$started = Get-Date
# --- F-MIMO-HANG: 用 .NET 同步 Process + stdin pipe 替换 Start-Job 异步 ---
# Start-Job + stdin pipe 在 Windows + 长 prompt 时 100% hang；
# .NET Process 同步 stdin/stdout + WaitForExit(ms) 是稳定路径
# PowerShell 5.1 兼容：ProcessStartInfo.Arguments 是 string（空格分隔），用双引号包裹路径
# 注：mimo 命令实际是 ps1 脚本（mimo.Source = .ps1 路径），需通过 powershell.exe 启动
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = (Get-Command powershell.exe).Source
# F-P02/F-P11/F-P12: 加 -OutputFormat XML -InputFormat XML，强制子 powershell 用 UTF-8 透传（避免 GBK 错码/截断）
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -OutputFormat XML -InputFormat XML -File `"$($mimo.Source)`" run -m $Model --dir `"$WorkspaceDir`""
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true

$proc = [System.Diagnostics.Process]::Start($psi)
try {
    # F-P01/F-P09: 关键顺序——先启动 async drain 双流，再 Write stdin
    # 避免对端 stdout/stderr 满 4KB 时 mimo 阻塞 → stdin 写端阻塞 → 死锁
    $script:outBuf = ""
    $script:errBuf = ""
    $proc.add_OutputDataReceived({ if ($EventArgs.Data) { $script:outBuf += $EventArgs.Data + "`n" } })
    $proc.add_ErrorDataReceived({ if ($EventArgs.Data) { $script:errBuf += $EventArgs.Data + "`n" } })
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    # 现在 stdin Write 安全（双流已 drain，不会阻塞）
    $proc.StandardInput.Write($prompt)
    $proc.StandardInput.Close()
    # --- F-MIMO-HANG: WaitForExit 之后再读 buffer ---
    # WaitForExit(ms) 是 .NET 提供的唯一带超时机制的退出检测
    # async drain 已把数据收进 $script:outBuf/$script:errBuf，不再用同步 ReadToEnd
    $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) {
        try { $proc.Kill() } catch {}
        try { $proc.WaitForExit(5000) } catch {}
        $exitCode = -2
        $output = @("TIMEOUT after ${TimeoutSeconds}s")
    } else {
        $exitCode = $proc.ExitCode
        # F-P03: WaitForExit 后给事件循环 200ms 排空最后数据，再读 buffer
        Start-Sleep -Milliseconds 200
        $output = @()
        if ($script:outBuf) { $output += $script:outBuf.Split("`n") }
        if ($script:errBuf) { $output += $script:errBuf.Split("`n") }
    }
} finally {
    $proc.Dispose()
}
$elapsed = ((Get-Date) - $started).TotalSeconds

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

# --- evidence.json 在所有控制台输出之前 ---
$status = switch ($exitCode) {
    0       { "success" }
    -2      { "timeout" }
    default { "error" }
}
$evidence = [ordered]@{
    schema_version   = 1
    task_id          = (Split-Path -Leaf $WorkspaceDir)
    step             = "step4"
    attempt          = 1
    agent            = "mimo"
    exit_code        = $exitCode
    elapsed_seconds  = [math]::Round($elapsed, 2)
    status           = $status
    warnings         = @($(if (-not $finalMsg) { "no agent_message" } else { $null }) | Where-Object { $_ })
    output_files     = @{ raw = $rawFile; output = $msgFile; evidence = (Join-Path $OutDir "evidence.json") }
    binding_snapshot = @{ agent = "mimo"; model = $Model; permission_mode = $Permissions }
    split_parent     = $null
    timestamp        = $started.ToString("o")
}
$evFile = Join-Path $OutDir "evidence.json"
$evidence | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $evFile -Encoding utf8
# --- 控制台输出在 evidence 之后（保留原有顺序与协议） ---
Write-Output "EXIT_CODE=$exitCode"
Write-Output "ELAPSED=${elapsed}s"
Write-Output "RAW=$rawFile"
Write-Output "REVIEW=$msgFile"
Write-Output "EVIDENCE=$evFile"