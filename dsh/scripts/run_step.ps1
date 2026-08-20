param(
    [Parameter(Mandatory = $true)][string]$Step,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$WorkspaceDir,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [int]$TimeoutSeconds = 0,
    [string]$SplitOf = "",       # 非空 = 本次为拆分重跑，父项标记拆分
    [int]$MaxSplitDepth = 3,
    [int]$MaxAttempts = 3
)
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Fail-Cli([string]$Message) { Write-Output "EXIT_CODE=-3"; Write-Output ("ERROR=" + $Message); exit 1 }
$KNOWN_STEPS = @("step1","step2","step3","step4")
if ($KNOWN_STEPS -notcontains $Step) { Fail-Cli "Invalid Step '$Step'" }
# 读绑定锁（fail-closed）：schema_version / locked / 恰好 step1..step4 / 受支持 agent / step3≠step4 模型族
$lockPath = $env:DSH_BINDING_LOCK
if (-not $lockPath) { $lockPath = Join-Path $HOME ".dsh\harness\binding-lock.json" }
if (-not (Test-Path -LiteralPath $lockPath)) { Fail-Cli "Missing binding lock: $lockPath" }
try { $lock = Get-Content -LiteralPath $lockPath -Encoding UTF8 -Raw | ConvertFrom-Json } catch { Fail-Cli "Invalid binding lock JSON" }
if ($lock.schema_version -ne 1) { Fail-Cli "Invalid binding lock: schema_version 必须为 1" }
if (-not $lock.locked) { Fail-Cli "Invalid binding lock: locked 必须为 true" }
$lockKeys = @($lock.bindings.PSObject.Properties.Name)
if (($lockKeys | Sort-Object) -join "," -ne (($KNOWN_STEPS | Sort-Object) -join ",")) {
    Fail-Cli "Binding lock 必须恰好定义 step1, step2, step3, step4"
}
$AGENT_FAMILY = @{
    "claude" = "claude"; "codex" = "openai"; "mimo" = "mimo";
    "kimi" = "moonshot"; "dsh-sub" = "deepseek"
}
foreach ($s in $KNOWN_STEPS) {
    $a = $lock.bindings.$s
    if (-not $AGENT_FAMILY.ContainsKey($a)) {
        Fail-Cli "绑定 '$a'（$s）不受支持（受支持 agent：$($AGENT_FAMILY.Keys -join ', ')）"
    }
}
# step3≠step4 模型族（对齐 manage_binding.ps1 Get-StepFamily：dsh-sub 族由 models 字段决定）
function Get-StepFamily([object]$L, [string]$S) {
    $ag = $L.bindings.$S
    if ($ag -ne "dsh-sub") { return $AGENT_FAMILY[$ag] }
    if ($null -ne $L.models -and $null -ne $L.models.$S.family) { return $L.models.$S.family }
    return "deepseek"
}
if ((Get-StepFamily $lock "step3") -eq (Get-StepFamily $lock "step4")) {
    Fail-Cli "绑定违规：step3='$($lock.bindings.step3)' 与 step4='$($lock.bindings.step4)' 同模型族。Step 4 必须与 Step 3 不同模型族。"
}
$agent = $lock.bindings.$Step
if (-not $agent) { Fail-Cli "No binding for $Step in $lockPath" }
# 读 harness-config 超时
$cfgPath = $env:DSH_HARNESS_CONFIG
if (-not $cfgPath) { $cfgPath = Join-Path $HOME ".dsh\harness\harness-config.json" }
$timeout = $TimeoutSeconds
if (Test-Path -LiteralPath $cfgPath) {
    try { $cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json } catch { $cfg = $null }
    if ($null -ne $cfg -and $TimeoutSeconds -eq 0) { $timeout = $cfg.steps.$Step.timeout_seconds }
}
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# CLI runner（claude/codex/mimo/kimi）与 opencode 适配层共享：两者都是 PowerShell、平台无关，
# 位于仓库 opencode/scripts/。从 dsh/scripts/ 引用时相对路径为 ../../opencode/scripts/。
$cliRunnerDir = Join-Path (Split-Path -Parent (Split-Path -Parent $scriptDir)) "opencode\scripts"
# Step4 快照强制（core-logic §8b + F-08）：dsh-sub 与 CLI 均需 Save；CLI 由本脚本 Assert，dsh-sub 由主编排层 Assert（同 opencode 模式）
$step4GuardLoaded = $false
if ($Step -eq "step4") {
    $guardScript = Join-Path $cliRunnerDir "step4_readonly_guard.ps1"
    if (Test-Path -LiteralPath $guardScript) {
        try { . $guardScript; $step4GuardLoaded = $true } catch { Write-Output "WARNING: step4 guard load failed: $_" }
        if ($step4GuardLoaded) {
            try { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null; Save-Step4Snapshot -WorkspaceDir $WorkspaceDir -OutDir $OutDir } catch { Write-Output "WARNING: Save-Step4Snapshot failed: $_" }
        }
    }
}
# 拆分契约输出——供编排层把子项落为独立工作包（唯一逻辑源见 core-logic §4b/§6b）
if ($SplitOf) {
    Write-Output "SPLIT=child-of-$SplitOf"
    Write-Output "   子项须独立完成 Step1→4；子项 Step4 需调整则按 core-logic §6b 回 Step2 迭代"
}
# 分派
switch ($agent) {
    "dsh-sub" {
        # DSH subagent 后端：本脚本不直接创建 subagent（那是主 agent 用 subagent 工具做的事）。
        # 权威分派契约：输出 BINDING/STEP/SUBAGENT 信号 + 出口码 99，主 agent 必须消费此信号并改用 subagent 工具调度。
        # 未消费（忽略输出）视为未完成而非成功。
        $subagent = switch ($Step) {
            "step1" { "harness-auditor" }
            "step2" { "harness-planner" }
            "step3" { "harness-implementer" }
            "step4" { "harness-verifier" }
            default { Fail-Cli "Unknown step for dsh-sub: $Step" }
        }
        Write-Output "BINDING=dsh-sub"
        Write-Output "STEP=$Step"
        Write-Output "SUBAGENT=$subagent"
        Write-Output ("MODEL_STEP3=" + $(if($lock.models){$lock.models.step3.model}else{""}))
        Write-Output ("MODEL_STEP4=" + $(if($lock.models){$lock.models.step4.model}else{""}))
        if ($Step -eq "step4" -and $step4GuardLoaded) {
            Write-Output "STEP4_GUARD_SNAPSHOT=$OutDir/pre-step4.sha256 (Assert deferred to orchestrator for dsh-sub, §8b)"
        }
        exit 99
    }
    "claude" {
        if ($Step -notin @("step1","step2","step3")) { Fail-Cli "claude runner only supports step1/2/3" }
        $defaultT = if ($Step -eq "step3") { 300 } else { 120 }
        & (Join-Path $cliRunnerDir "run_claude_step12.ps1") -Step $Step -PromptFile $PromptFile -WorkspaceDir $WorkspaceDir -OutDir $OutDir -TimeoutSeconds $(if($timeout){$timeout}else{$defaultT})
    }
    "codex" {
        if ($Step -ne "step4") { Fail-Cli "codex runner only supports step4" }
        & (Join-Path $cliRunnerDir "run_codex_step4.ps1") -PromptFile $PromptFile -WorkspaceDir $WorkspaceDir -OutDir $OutDir -TimeoutSeconds $(if($timeout){$timeout}else{180})
    }
    "mimo" {
        if ($Step -ne "step4") { Fail-Cli "mimo runner only supports step4" }
        & (Join-Path $cliRunnerDir "run_mimo_step4.ps1") -PromptFile $PromptFile -WorkspaceDir $WorkspaceDir -OutDir $OutDir -TimeoutSeconds $(if($timeout){$timeout}else{180})
    }
    "kimi" {
        if ($Step -ne "step4") { Fail-Cli "kimi runner only supports step4" }
        & (Join-Path $cliRunnerDir "run_kimi_step4.ps1") -PromptFile $PromptFile -WorkspaceDir $WorkspaceDir -OutDir $OutDir -TimeoutSeconds $(if($timeout){$timeout}else{180})
    }
    default { Fail-Cli "Unknown agent '$agent' for $Step" }
}
# V11 新增：超时拆分闭环（对齐 shared/core-logic.md §6.1 / opencode run_step.ps1:140）
# 约定：runner 末尾输出 EXIT_CODE=-2 即超时；捕获后按 MaxSplitDepth=3、MaxAttempts=3、最小粒度<4行 拆分，触壁垒写 evidence.json status=blocked_split_limit 并 EXIT_CODE=3
# 调用方必须用 bash timeout=300000 + Tee-Object 实时落盘，否则 EXIT_CODE 末尾行被 120s 截断（V10）
function Merge-DshEvidence([string]$od,[int]$ec,[string]$status,[int]$att){ $evFile=Join-Path $od "evidence.json"; $ev=[ordered]@{schema_version=1;task_id=(Split-Path -Leaf $WorkspaceDir);step=$Step;attempt=$att;agent=$agent;exit_code=$ec;status=$status;split_parent=$SplitOf;timestamp=(Get-Date).ToString("o")}; $ev|ConvertTo-Json -Depth 5|Out-File -LiteralPath $evFile -Encoding utf8 }
$exitCode = $LASTEXITCODE
# Step4 CLI 快照校验（§8b）：即使测试通过也回退，命中即 EXIT_CODE=4
if ($Step -eq "step4" -and $step4GuardLoaded -and $agent -ne "dsh-sub" -and $exitCode -eq 0) {
    try {
        $changed = Assert-Step4ReadOnly -WorkspaceDir $WorkspaceDir -OutDir $OutDir -Step4Agent $agent
        if ($changed -and $changed.Count -gt 0) {
            Write-Output "VIOLATION: step4 wrote files: $($changed -join ', ') — auto-reverted per core-logic §8/§8b"
            Merge-DshEvidence $OutDir 4 "violation_step4_write" 1
            Write-Output "EXIT_CODE=4 status=violation_step4_write"
            exit 4
        }
    } catch { Write-Output "WARNING: Assert-Step4ReadOnly failed: $_" }
}
if ($exitCode -eq -2) {
    $txt = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
    if (-not $txt) { $txt = "" }
    $ln = $txt -split "`r?`n"
    if ($ln.Count -lt 4) {
        Merge-DshEvidence $OutDir -2 "blocked_split_limit" 1 $PromptFile
        Write-Output "EXIT_CODE=3 status=blocked_split_limit min_granularity"
        exit 3
    }
    if ($MaxSplitDepth -le 1) {
        Merge-DshEvidence $OutDir -2 "blocked_split_limit" 1 $PromptFile
        Write-Output "EXIT_CODE=3 status=blocked_split_limit depth=$MaxSplitDepth"
        exit 3
    }
    $mid = [int]($ln.Count / 2)
    $aTxt = ($ln[0..($mid-1)] -join "`n")
    $bTxt = ($ln[$mid..($ln.Count-1)] -join "`n")
    $sub = Join-Path $OutDir "subitems"
    New-Item -ItemType Directory -Path "$sub\a","$sub\b" -Force | Out-Null
    $aTxt | Out-File -LiteralPath "$sub\a\prompt.txt" -Encoding utf8
    $bTxt | Out-File -LiteralPath "$sub\b\prompt.txt" -Encoding utf8
    Merge-DshEvidence $OutDir -2 "split_required" 1 $PromptFile
    Write-Output "EXIT_CODE=-2 status=split_required subitems=$sub MaxSplitDepth=$MaxSplitDepth MaxAttempts=$MaxAttempts"
    exit -2
}
Write-Output "EXIT_CODE=$exitCode"
exit $exitCode
