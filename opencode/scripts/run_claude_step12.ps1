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

function Fail-Cli([string]$Message) {
    Write-Output "EXIT_CODE=-3"
    Write-Output ("ERROR=" + $Message)
    exit 1
}
if (-not (Test-Path -LiteralPath $PromptFile)) { Fail-Cli "Prompt file not found: $PromptFile" }
if (-not (Test-Path -LiteralPath $WorkspaceDir)) { Fail-Cli "Workspace not found: $WorkspaceDir" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# 步骤枚举校验：仅 step1/step2/step3（step3 需写权限，走 --dangerously-skip-permissions 分支，见 F-11c）
$validSteps = @("step1", "step2", "step3")
if ($validSteps -notcontains $Step) { Fail-Cli ("Invalid Step '$Step'. Must be one of: " + ($validSteps -join ", ")) }
# 超时默认值对齐 Hermes（run_cli.py DEFAULT_CONFIG）：step1/2=120s、step3=300s
if (-not $PSBoundParameters.ContainsKey("TimeoutSeconds")) {
    $TimeoutSeconds = if ($Step -eq "step3") { 300 } else { 120 }
}

$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) { Fail-Cli "claude CLI not found in PATH" }

$prompt = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw
$prompt = $prompt.Trim()
if (-not $prompt) { Fail-Cli "Prompt file is empty" }

# 按步骤注入保护前缀（对齐 Hermes run_cli.py STEP_PROMPT_PREFIXES：step3 禁止自跑测试）。
# 不再删除 ANTHROPIC_* 环境变量：删除会清掉用户显式设置的有效凭据，且与同目录另外两个 ps1 行为不一致；
# 若环境残留指向失效端点的代理变量导致挂起，由超时分支保留的部分输出（F-13c）暴露，主 agent 据此诊断。
$STEP_PREFIXES = @{
    step1 = "你是四步法第1步审查者：只找问题，不写方案，不改代码。输出带 P 编号的问题清单。`n"
    step2 = "你是四步法第2步方案者：只写修复方案，不改代码。每个修复对应一个 P 编号，给出 before/after。`n"
    step3 = "IMPORTANT: This is Step 3 implementation. Implement only the approved changes and modify files as needed. You may inspect and edit files required for the implementation. You SHOULD run read-only validation that needs no approval (e.g. git diff --check, read-only syntax/compile checks via `python -B`); you MAY run regression (e.g. pytest) if the environment permits without approval. If a validation command is blocked by permission, approval, or missing tools, do NOT treat that as implementation failure — record it in the required `## Step 3 验证状态` block as blocked(<command>/<reason>) or not-run(<reason>). NEVER claim tests passed unless you actually ran them and they passed. At the end of your reply output a `## Step 3 验证状态` section with: validation-method, syntax-check, regression, remarks.`n`n"
}
$prompt = $STEP_PREFIXES[$Step] + $prompt

$rawFile = Join-Path $OutDir "claude_raw.txt"
$msgFile = Join-Path $OutDir "$Step-output.md"

# step1/2 只读：-p + stdin（避免 8191 字符命令行截断）；step3 需写文件：去掉 -p、加 --dangerously-skip-permissions（对齐 Hermes run_cli.py）
if ($Step -eq "step3") {
    $cmd = @("--dangerously-skip-permissions", "--add-dir", $WorkspaceDir)
} else {
    $cmd = @("-p", "--output-format", "text", "--add-dir", $WorkspaceDir)
}

$started = Get-Date
$job = Start-Job -ScriptBlock {
    param($Prompt, $Exe, $Cmd)
    # 子进程 stdin 必须显式 UTF-8，否则中文 prompt 经管道传给 claude 时被按 ANSI/GBK 解码成乱码
    $OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $out = $Prompt | & $Exe @Cmd 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
} -ArgumentList $prompt, $claude.Source, $cmd
if (Wait-Job $job -Timeout $TimeoutSeconds) {
    try { $result = Receive-Job $job } catch { $result = $null }
    if ($null -ne $result) {
        $exitCode = if ($null -ne $result.Exit) { [int]$result.Exit } else { -1 }
        $output = @($result.Out)
    } else {
        $exitCode = -1
        $output = @("Receive-Job failed (job unreadable)")
    }
} else {
    # 保留已产生的部分输出：用于诊断超时源于模型工作 / CLI 卡死 / prompt 需拆分（对齐 Hermes run_cli.py:343-351）
    try { $partial = Receive-Job $job } catch { $partial = $null }
    Stop-Job $job
    $exitCode = -2
    if ($null -ne $partial -and @($partial).Count -gt 0) { $output = @($partial) } else { $output = @("TIMEOUT after ${TimeoutSeconds}s") }
}
Remove-Job $job -Force
$elapsed = ((Get-Date) - $started).TotalSeconds

$output | Out-File -LiteralPath $rawFile -Encoding utf8

$lines = @($output | ForEach-Object { if ($null -eq $_) { "" } else { $_.ToString() } })
$usable = @($lines | Where-Object {
    $t = $_.Trim()
    ($t -ne "") -and
    (-not $_.StartsWith("node.exe")) -and
    (-not $_.StartsWith("CategoryInfo")) -and
    (-not $_.StartsWith("FullyQualifiedErrorId"))
})
# 注：不按 "claude"/"Connection" 行首过滤——正文可能以这些词开头，误删会丢真实内容；原始输出完整保留在 raw 文件

$finalMsg = ($usable -join "`n").Trim()
if (-not $finalMsg) { $finalMsg = "(no textual output; see raw file)" }

$out = "> claude CLI (exit $exitCode), $([math]::Round($elapsed,1))s`n`n$finalMsg"
$out | Out-File -LiteralPath $msgFile -Encoding utf8

Write-Output ("EXIT_CODE=" + $exitCode)
Write-Output ("ELAPSED=" + $elapsed + "s")
Write-Output ("RAW=" + $rawFile)
Write-Output ("OUTPUT=" + $msgFile)