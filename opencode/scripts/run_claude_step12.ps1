# V10 警示：本 runner 用 Start-Job + Wait-Job -Timeout 且 103-106 行才输出 EXIT_CODE/ELAPSED/RAW；bash 默认 120s 将先截断本 runner，调用方必须 bash --timeout 300000 + | Tee-Object -FilePath <OutDir>/run.log，否则 -2 超时无法触发上游拆分
param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceDir,
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    [string]$Step = "step1",
    [int]$TimeoutSeconds = 180,
    [ValidateSet("default", "acceptEdits", "bypassPermissions")]
    [string]$Permissions = "default",
    [string]$AddDirs = ""   # v13.0.42 ZCode 兼容：逗号分隔目标目录；空=只用 cwd（不再 --add-dir 整个 WorkspaceDir，避免扫 .harness 卡死）
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
# [F-03] 中文路径 mojibake 防护：prompt 全部 NFD→NFC 归一化（PS 5.1 按 ANSI 解码时中文/拼音路径会呈分解形式，导致 CLI 读不到同名文件）
$prompt = $prompt.Normalize([System.Text.NormalizationForm]::FormC)

# P-04: 条件化 ANTHROPIC_* 处理——仅当 ANTHROPIC_BASE_URL 指向本地凭据池代理（127.0.0.1 / localhost）
# 时保留 BASE_URL/API_KEY/AUTH_TOKEN（claude-code-credential-pool skill 依赖此代理）；否则 strip 之，
# 让 claude 回落 ~/.claude/settings.json 取凭据，避免残留 dead endpoint（如 deepseek proxy）导致 hang。
# 模型名覆盖变量（ANTHROPIC_MODEL / ANTHROPIC_DEFAULT_*）一律 strip：它们是 shell 残留，会无视代理路径
# 钉死模型；模型选择应由 settings.json 控制。
$anthropicBaseUrl = $env:ANTHROPIC_BASE_URL
$keepLocalProxy = $anthropicBaseUrl -and ($anthropicBaseUrl -match '127\.0\.0\.1|localhost')
if (-not $keepLocalProxy) {
    foreach ($name in @("ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")) {
        Remove-Item ("Env:" + $name) -ErrorAction SilentlyContinue
    }
}
foreach ($name in @("ANTHROPIC_MODEL",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL",
                    "ANTHROPIC_DEFAULT_OPUS_MODEL",
                    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
                    "ANTHROPIC_DEFAULT_FABLE_MODEL",
                    "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME",
                    "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME")) {
    Remove-Item ("Env:" + $name) -ErrorAction SilentlyContinue
}

$rawFile = Join-Path $OutDir "claude_raw.txt"
$msgFile = Join-Path $OutDir "$Step-output.md"

# [F-03] 多目录 --add-dir：工作目录 + OPENCODE_EXTRA_ADD_DIRS（分号分隔）逐个解析为全路径并 NFC 归一化。
# 相对路径以当前 PowerShell 位置为基准展开（bash 调本脚本时通常即仓库根）。
function Resolve-AddDir([string]$d) {
    $d = $d.Trim()
    if (-not $d) { return $null }
    if (-not [System.IO.Path]::IsPathRooted($d)) { $d = Join-Path (Get-Location).Path $d }
    return [System.IO.Path]::GetFullPath($d).Normalize([System.Text.NormalizationForm]::FormC)
}
$addDirs = New-Object System.Collections.Generic.List[string]
$wd = Resolve-AddDir $WorkspaceDir
if ($wd) { [void]$addDirs.Add($wd) }
if ($env:OPENCODE_EXTRA_ADD_DIRS) {
    foreach ($d in ($env:OPENCODE_EXTRA_ADD_DIRS -split ';')) {
        $rd = Resolve-AddDir $d
        if ($rd -and -not $addDirs.Contains($rd)) { [void]$addDirs.Add($rd) }
    }
}
$cmd = @("-p", "--output-format", "text")   # prompt 经管道喂 stdin，避免 8191 字符命令行截断；--add-dir 放行 Read 工具读各目录
foreach ($d in $addDirs) { $cmd += "--add-dir"; $cmd += $d }
if ($Permissions -ne "default") {
    $cmd += "--permission-mode"; $cmd += $Permissions
}

$started = Get-Date
# Do not put claude.exe behind Start-Job + a PowerShell pipeline.  On Windows
# that combination can leave stdin or a child node process alive after the job
# timeout, turning the next OpenCode step into a phantom >240s timeout.
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $claudeExe
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
# Windows PowerShell 5.1 exposes StandardInputEncoding without a setter; the
# redirected StreamWriter already defaults to UTF-8, so do not assign it.
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
$psi.WorkingDirectory = $wd   # [F-03] 归一化全路径作为工作目录（中文路径不再 mojibake）
$psi.Arguments = '-p --output-format text' + (($addDirs | ForEach-Object { ' --add-dir "' + $_.Replace('"', '\"') + '"' }) -join '')
if ($Permissions -ne "default") { $psi.Arguments += ' --permission-mode ' + $Permissions }
# [F-04] step1/2 审查者（claude default 权限门）：保持工作区行为性只读（default），仅放行 Write/Edit 到本任务产物目录。
# 修复前 default 下 Write/Edit 全被 gate 拒 → 完整问题清单/方案只能落 stdout 摘要（P-04：r4 实测 901B 覆盖 1751B）。
# 产物 glob = 任务产物根 .harness/<task>/**（兼容主流程 OutDir=.harness/<task>/stepN 与 prechunks/NN 分片路径）。
$allowGlob = $null
if (($Step -eq "step1" -or $Step -eq "step2") -and $Permissions -eq "default") {
    $taskDirParts = $OutDir -split '[\\/]'
    $hIdx = [Array]::IndexOf($taskDirParts, ".harness")
    if ($hIdx -ge 0 -and $taskDirParts.Count -ge $hIdx + 2) {
        $taskDir = (($taskDirParts[0..($hIdx+1)]) -join "/").TrimEnd('/')
    } else {
        $taskDir = (Split-Path -Parent $OutDir).Replace('\','/').TrimEnd('/')
    }
    $allowGlob = $taskDir + "/**"
    $cmd += "--allowedTools"; $cmd += ("Write(" + $allowGlob + ")")
    $cmd += "--allowedTools"; $cmd += ("Edit(" + $allowGlob + ")")
    $psi.Arguments += ' --allowedTools "Write(' + $allowGlob + ')"'
    $psi.Arguments += ' --allowedTools "Edit(' + $allowGlob + ')"'
}
$argSummary = [ordered]@{
    executable = (Split-Path -Leaf $claudeExe)
    switches = @("-p", "--output-format", "text") + ($addDirs | ForEach-Object { "--add-dir" }) + $(if ($Permissions -ne "default") { @("--permission-mode") } else { @() })
    add_dir = $true
    add_dirs = @($addDirs)   # [F-03] 实际传给 --add-dir 的目录清单（含 OPENCODE_EXTRA_ADD_DIRS）
    workspace_path_length = $WorkspaceDir.Length
    allowed_tools_glob = $allowGlob   # [F-04] step1/2 default 下放行的产物 Write/Edit glob（非 step1/2 为 $null）
}
$promptByteCount = [System.Text.Encoding]::UTF8.GetByteCount($prompt)
$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
if (-not $proc.Start()) { throw "Failed to start Claude executable: $claudeExe" }
$stdoutTask = $proc.StandardOutput.ReadToEndAsync()
$stderrTask = $proc.StandardError.ReadToEndAsync()
$stdinWrite = "success"
# [F-03] UTF-8 BOM 写入 stdin：PS 5.1 的 StandardInput StreamWriter 编码不可靠（可能按 ANSI），
# 直接 BaseStream 写 UTF-8 BOM + NFC 字节，保证 CLI 侧按 UTF-8 解码（与 check-bom.ps1 相同 EF BB BF 前置）。
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$promptBytes = $utf8Bom.GetPreamble() + $utf8Bom.GetBytes($prompt)
try {
    $proc.StandardInput.BaseStream.Write($promptBytes, 0, $promptBytes.Length)
    $proc.StandardInput.BaseStream.Flush()
    $proc.StandardInput.Close()
}
catch { $stdinWrite = "failure: $($_.Exception.Message)"; try { $proc.StandardInput.Close() } catch {} }

# P-09: 启动后立即写 "running" evidence.json——外层硬杀（SIGKILL/timeout）时仍有启动记录，
# 不再留下空目录无证据。最终正常退出会覆盖为完整 evidence（见下方 $evidence | ConvertTo-Json）。
$evFileEarly = Join-Path $OutDir "evidence.json"
$evRunning = [ordered]@{
    schema_version   = 1
    task_id          = (Split-Path -Leaf $WorkspaceDir)
    step             = $Step
    attempt          = 1
    agent            = "claude"
    exit_code        = $null
    status           = "running"
    output_files     = @{ raw = $rawFile; output = $msgFile; evidence = $evFileEarly }
    split_parent     = $null
    timestamp        = $started.ToString("o")
    warnings         = @()
    binding_snapshot = @{ agent = "claude"; permission_mode = $Permissions; model = $null }
}
$evRunning | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $evFileEarly -Encoding utf8

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
}
$proc.Dispose()
$elapsed = ((Get-Date) - $started).TotalSeconds

# [F-04] EXIT_CODE=-1 诊断：区分 spawn 失败、stdin 写入失败、空输出、ExitCode 范围异常
$diagnosticSignal = $null
if ($exitCode -eq -1) {
    $stdoutLen = if ($stdout) { $stdout.Length } else { 0 }
    $stderrLen = if ($stderr) { $stderr.Length } else { 0 }
    if ($stdinWrite -ne "success") {
        $diagnosticSignal = "INFRA_FAILURE:stdin_write_failed"
    } elseif ($stdoutLen -eq 0 -and $stderrLen -eq 0) {
        $diagnosticSignal = "INFRA_FAILURE:empty_output"
    } else {
        $diagnosticSignal = "INFRA_FAILURE:exit_code_anomaly"
    }
    Write-Output $diagnosticSignal
    Write-Output "INFRA_FAILURE_DETAIL:exit=$exitCode stdout_bytes=$stdoutLen stderr_bytes=$stderrLen stdin=$stdinWrite"
}

$output | Out-File -LiteralPath $rawFile -Encoding utf8
$combinedRaw = (($output | ForEach-Object { if ($null -eq $_) { "" } else { $_.ToString() } }) -join "`n")
$jsonParseFailure = $combinedRaw.Contains("API Error: Failed to parse JSON")
if ($jsonParseFailure) {
    $exitCode = 13
    Write-Output "INFRA_FAILURE:other"
    Write-Output "INFRA_FAILURE_DETAIL:claude_json_parse"
}

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
    status           = if ($jsonParseFailure) { "infrastructure_error" } elseif ($exitCode -eq 0) { "success" } elseif ($exitCode -eq -2) { "timeout" } else { "error" }
    output_files     = @{ raw = $rawFile; output = $msgFile; evidence = (Join-Path $OutDir "evidence.json") }
    split_parent     = $null
    timestamp        = $started.ToString("o")
    warnings         = $(if ($jsonParseFailure) { @("claude_json_parse") } else { @() })
    diagnostics      = @{ argument_summary = $argSummary; prompt_utf8_bytes = $promptByteCount; stdin_write = $stdinWrite; stderr = $stderr; json_parse_failure = $jsonParseFailure }
    binding_snapshot = @{ agent = "claude"; permission_mode = $Permissions; model = $null }
}
$evFile = Join-Path $OutDir "evidence.json"
$evidence | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $evFile -Encoding utf8

Write-Output ("EXIT_CODE=" + $exitCode)
Write-Output ("ELAPSED=" + $elapsed + "s")
Write-Output ("RAW=" + $rawFile)
Write-Output ("OUTPUT=" + $msgFile)
Write-Output ("EVIDENCE=" + $evFile)
