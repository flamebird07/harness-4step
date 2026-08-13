param(
    [Parameter(Mandatory = $true)][string]$Step,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$WorkspaceDir,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [int]$TimeoutSeconds = 0
)
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Fail-Cli([string]$Message) { Write-Output "EXIT_CODE=-3"; Write-Output ("ERROR=" + $Message); exit 1 }
$KNOWN_STEPS = @("step1","step2","step3","step4")
if ($KNOWN_STEPS -notcontains $Step) { Fail-Cli "Invalid Step '$Step'" }
# 读绑定锁（fail-closed）：schema_version / locked / 恰好 step1..step4 / 受支持 agent / step3≠step4 模型族
$lockPath = $env:OPCODE_BINDING_LOCK
if (-not $lockPath) { $lockPath = Join-Path $HOME ".config\opencode\harness\binding-lock.json" }
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
    "kimi" = "moonshot"; "opencode-sub" = "opencode-main"
}
foreach ($s in $KNOWN_STEPS) {
    $a = $lock.bindings.$s
    if (-not $AGENT_FAMILY.ContainsKey($a)) {
        Fail-Cli "绑定 '$a'（$s）不受支持（受支持 agent：$($AGENT_FAMILY.Keys -join ', ')）"
    }
}
if ($lock.bindings.step3 -eq $lock.bindings.step4 -or $AGENT_FAMILY[$lock.bindings.step3] -eq $AGENT_FAMILY[$lock.bindings.step4]) {
    Fail-Cli "绑定违规：step3='$($lock.bindings.step3)' 与 step4='$($lock.bindings.step4)' 同模型族。Step 4 必须与 Step 3 不同模型族。"
}
$agent = $lock.bindings.$Step
if (-not $agent) { Fail-Cli "No binding for $Step in $lockPath" }
# 读 harness-config 超时
$cfgPath = $env:OPCODE_HARNESS_CONFIG
if (-not $cfgPath) { $cfgPath = Join-Path $HOME ".config\opencode\harness\harness-config.json" }
$timeout = $TimeoutSeconds
if (Test-Path -LiteralPath $cfgPath) {
    try { $cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json } catch { $cfg = $null }
    if ($null -ne $cfg -and $TimeoutSeconds -eq 0) { $timeout = $cfg.steps.$Step.timeout_seconds }
}
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# 分派
switch ($agent) {
    "claude" {
        if ($Step -notin @("step1","step2","step3")) { Fail-Cli "claude runner only supports step1/2/3" }
        & (Join-Path $scriptDir "run_claude_step12.ps1") -Step $Step -PromptFile $PromptFile -WorkspaceDir $WorkspaceDir -OutDir $OutDir -TimeoutSeconds $(if($timeout){$timeout}else{120})
    }
    "codex" {
        if ($Step -ne "step4") { Fail-Cli "codex runner only supports step4" }
        & (Join-Path $scriptDir "run_codex_step4.ps1") -PromptFile $PromptFile -WorkspaceDir $WorkspaceDir -OutDir $OutDir -TimeoutSeconds $(if($timeout){$timeout}else{300})
    }
    "mimo" {
        if ($Step -ne "step4") { Fail-Cli "mimo runner only supports step4" }
        & (Join-Path $scriptDir "run_mimo_step4.ps1") -PromptFile $PromptFile -WorkspaceDir $WorkspaceDir -OutDir $OutDir -TimeoutSeconds $(if($timeout){$timeout}else{300})
    }
    "kimi" {
        if ($Step -ne "step4") { Fail-Cli "kimi runner only supports step4" }
        & (Join-Path $scriptDir "run_kimi_step4.ps1") -PromptFile $PromptFile -WorkspaceDir $WorkspaceDir -OutDir $OutDir -TimeoutSeconds $(if($timeout){$timeout}else{300})
    }
    "opencode-sub" {
        Write-Output "BINDING=opencode-sub"   # 主 agent 据此改走 Task 调度对应 subagent
        exit 0
    }
    default { Fail-Cli "Unknown agent '$agent' for $Step" }
}