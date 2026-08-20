# V10 强制：本 runner 默认 Timeout 180-900s、末尾集中输出 EXIT_CODE/ELAPSED/RAW，无 Tee-Object 实时透传；文件头原仅讲 stdin 管道死锁，现补充：bash 调用必须 timeout=300000 + | Tee-Object -FilePath <OutDir>/run.log，否则 >120s 的 mimo/codex 长 prompt 必被 120s 截断、EXIT/ELAPSED 丢失、误判 hang（违规10）
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

# F-P05/F-P10: 删除原 prompt 字符清理段（stdin 路径下不经过 argv 拆词，清理纯损语义）
# 注：argv 路径下的字符拆词风险由 F-P01（事件驱动 async drain）+ F-P02（套娃保留 + UTF-8）共同避免

$started = Get-Date
# --- F-MIMO-HANG: 用 .NET 同步 Process + stdin pipe 替换 Start-Job 异步 ---
# F-MIMO-ROOTFIX: 直接启动 node.exe + bin/mimo，绕过 .ps1 shim 与 powershell.exe 层
$npmDir = Split-Path $mimo.Source -Parent
$nodeExe = if (Test-Path (Join-Path $npmDir "node.exe")) { Join-Path $npmDir "node.exe" } else { (Get-Command node).Source }
$mimoJs = Join-Path $npmDir "node_modules\@mimo-ai\cli\bin\mimo"
if (-not (Test-Path -LiteralPath $mimoJs)) { throw "Cannot resolve mimo JS entry: $mimoJs" }
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $nodeExe
$psi.Arguments = "`"$mimoJs`" run -m $Model --dir `"$WorkspaceDir`" --dangerously-skip-permissions"
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
    # PS 5.1 无 StandardInputEncoding 属性，必须字节直写 UTF-8 保障中文 prompt 不乱码
    $utf8 = [System.Text.Encoding]::UTF8
    $bytes = $utf8.GetBytes($prompt)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
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