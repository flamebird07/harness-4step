param(
    [Parameter(Mandatory = $true)][string]$Step,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$WorkspaceDir,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [int]$TimeoutSeconds = 0,
    [string]$SplitOf = ""       # 非空 = 本次为拆分重跑，父项标记拆分
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
