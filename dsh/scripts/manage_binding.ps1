<#
.SYNOPSIS
DSH（DeepSeek Harness）适配层绑定管理：加载/校验/展示 binding-lock.json，仅允许经显式用户授权改写绑定
（写入 authorization_log，tmp 原子替换）。对齐 Hermes 端 binding-lock.json + opencode 端 manage_binding.ps1。

V10 调用约定：bash 调本脚本及 run_step.ps1 必须 timeout=300000 + | Tee-Object -FilePath <OutDir>/run.log 实时透传，否则 EXIT_CODE/BINDING_LOCK_OK 因 120s 截断丢失
用法（bash 侧）：
  bash --timeout 300000 -c "powershell.exe -File dsh/scripts/manage_binding.ps1 -Check | Tee-Object -FilePath .harness/<task>/binding-check.log"
  bash --timeout 300000 -c "powershell.exe -File dsh/scripts/run_step.ps1 -Step step1 ... | Tee-Object -FilePath .harness/<task>/step1/run.log"
用法（powershell.exe 直接）：
  manage_binding.ps1 -ShowBindings                          # 展示每步绑定 + models 模型族 + 超时 + 可执行文件状态
  manage_binding.ps1 -Check                                 # 校验（fail-closed）：lock 存在且有效、bindings 恰好 step1..step4、step3≠step4 模型族
  manage_binding.ps1 -InstallFromRepo                       # 幂等：把仓库 dsh/binding-lock.json 同步到本机锁路径（保留本机 authorization_log）
  manage_binding.ps1 -AuthorizeStep step3 -Agent claude -Authorization "<用户授权原文，≥12字符>"

路径：lock 默认 $HOME/.dsh/harness/binding-lock.json（本机私有；模板在仓库 dsh/binding-lock.json）；
       config 默认同目录 harness-config.json。环境变量覆盖：DSH_BINDING_LOCK / DSH_HARNESS_CONFIG。
#>
param(
    [string]$LockPath = $env:DSH_BINDING_LOCK,
    [string]$ConfigPath = $env:DSH_HARNESS_CONFIG,
    [switch]$ShowBindings,
    [switch]$Check,
    [switch]$InstallFromRepo,
    [switch]$RecordViolation,
    [string]$Id,
    [string]$By,
    [string]$Reason,
    [string]$AuthorizeStep,
    [string]$Agent,
    [string]$Authorization
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$KNOWN_STEPS = @("step1", "step2", "step3", "step4")
# 模型族分组：step3 与 step4 必须不同族（shared/core-logic.md §4）。
# CLI 后端按执行二进制固定族；dsh-sub 的族由 binding-lock.json 的 models 字段（family）决定，
# 未配置 models 时默认族 = "deepseek"（step4 应显式配置为其他族以满足硬约束）。
$AGENT_FAMILY = @{
    "claude" = "claude"; "codex" = "openai"; "mimo" = "mimo";
    "kimi" = "moonshot"; "dsh-sub" = "deepseek"
}

function Resolve-LockPath {
    if ($LockPath) { return $LockPath }
    return Join-Path $HOME ".dsh\harness\binding-lock.json"
}
function Resolve-ConfigPath {
    if ($ConfigPath) { return $ConfigPath }
    return Join-Path $HOME ".dsh\harness\harness-config.json"
}
function Fail-Cli([string]$Message) {
    Write-Output ("ERROR=" + $Message)
    exit 1
}
function Load-Lock([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        Fail-Cli "Missing binding lock: $Path (从仓库 dsh/binding-lock.json 复制，见 dsh/README.md 安装)"
    }
    try { $data = Get-Content -LiteralPath $Path -Encoding UTF8 -Raw | ConvertFrom-Json }
    catch { Fail-Cli "Invalid JSON in binding lock: $Path ($_)" }
    if ($data.schema_version -ne 1) { Fail-Cli "Invalid binding lock: schema_version 必须为 1（$Path）" }
    if (-not $data.locked) { Fail-Cli "Invalid binding lock: locked 必须为 true（$Path）" }
    $keys = @($data.bindings.PSObject.Properties.Name)
    if (($keys | Sort-Object) -join "," -ne (($KNOWN_STEPS | Sort-Object) -join ",")) {
        Fail-Cli "Binding lock 必须恰好定义 step1, step2, step3, step4（$Path）"
    }
    return $data
}
function Load-Config([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $cfg = Get-Content -LiteralPath $Path -Encoding UTF8 -Raw | ConvertFrom-Json
    # 对齐 Hermes v13.0.10：配置不得含 agent 字段，绑定只由 binding-lock.json 决定（防双配置源漂移）
    foreach ($name in $KNOWN_STEPS) {
        if ($null -ne $cfg.steps.$name.agent) {
            Fail-Cli "harness-config.json 不得为 '$name' 定义 agent（绑定只由 binding-lock.json 决定）"
        }
    }
    return $cfg
}
function Get-StepFamily([object]$Lock, [string]$Step) {
    $agent = $Lock.bindings.$Step
    if (-not $AGENT_FAMILY.ContainsKey($agent)) { Fail-Cli "未知 agent '$agent'（已知：$($AGENT_FAMILY.Keys -join ', ')）" }
    if ($agent -ne "dsh-sub") { return $AGENT_FAMILY[$agent] }
    # dsh-sub：族由 models 字段决定；未配置回退默认族
    if ($null -ne $Lock.models -and $null -ne $Lock.models.$Step.family) { return $Lock.models.$Step.family }
    return "deepseek"
}
function Test-Step4FamilyDifferent([object]$Lock) {
    $f3 = Get-StepFamily $Lock "step3"
    $f4 = Get-StepFamily $Lock "step4"
    if ($f3 -eq $f4) {
        Fail-Cli "绑定违规：step3='$($Lock.bindings.step3)'(族 $f3) 与 step4='$($Lock.bindings.step4)'(族 $f4) 同模型族。Step 4 必须与 Step 3 不同模型族（shared/core-logic.md §4）。"
    }
}
function Test-Step1Step2Supported($Lock) {
    foreach ($s in @("step1", "step2")) {
        $a = $Lock.bindings.$s
        if (-not $AGENT_FAMILY.ContainsKey($a)) {
            Fail-Cli "绑定违规：$s='$a' 不受支持（受支持 agent：$($AGENT_FAMILY.Keys -join ', ')）"
        }
    }
}

if ($ShowBindings -or $Check) {
    $path = Resolve-LockPath
    $lock = Load-Lock $path
    $cfg = Load-Config (Resolve-ConfigPath)
    Test-Step1Step2Supported $lock
    Test-Step4FamilyDifferent $lock
    # [P-08] stale pending failover 检测（>24h 未 ratify → 自动回退 + 警告），镜像 opencode F-P04
    $pendingPath = Join-Path (Split-Path -Parent $path) "pending-auth.json"
    if (Test-Path -LiteralPath $pendingPath) {
        $raw = Get-Content -LiteralPath $pendingPath -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
        $pending = @(); if ($raw) { try { $j = $raw | ConvertFrom-Json; if ($j) { $pending = @($j) } } catch { $pending = @() } }
        $now = Get-Date; $stale = @()
        foreach ($e in $pending) {
            if ($e.ratified -eq $true) { continue }
            try { $ts = [datetime]$e.timestamp } catch { $stale += $e; continue }
            if (($now - $ts).TotalHours -gt 24) { $stale += $e }
        }
        if ($stale.Count -gt 0) {
            foreach ($e in $stale) {
                if ($lock.bindings.$($e.step) -eq $e.target_agent) {
                    $lock.bindings.$($e.step) = $e.original_agent
                    Write-Output "WARN: stale pending failover (>$($e.timestamp), step=$($e.step)) auto-reverted to $($e.original_agent)"
                }
            }
            Test-Step4FamilyDifferent $lock
            $tmp = $path + ".tmp"
            Set-Content -LiteralPath $tmp -Value ($lock | ConvertTo-Json -Depth 6) -Encoding UTF8
            Move-Item -LiteralPath $tmp -Destination $path -Force
            $staleKeys = @(); foreach ($e in $stale) { $staleKeys += ($e.timestamp + "|" + $e.step) }
            $remaining = @($pending | Where-Object { ($_.ratified -eq $true) -or -not ($staleKeys -contains ($_.timestamp + "|" + $_.step)) })
            $remJson = if ($remaining.Count -eq 0) { "[]" } elseif ($remaining.Count -eq 1) { "[" + ($remaining | ConvertTo-Json -Depth 4) + "]" } else { $remaining | ConvertTo-Json -Depth 4 }
            Set-Content -LiteralPath $pendingPath -Value $remJson -Encoding UTF8
        }
    }
    $defaultT = 180
    if ($null -ne $cfg -and $null -ne $cfg.defaults.timeout_seconds) { $defaultT = $cfg.defaults.timeout_seconds }
    foreach ($step in $KNOWN_STEPS) {
        $agent = $lock.bindings.$step
        $family = Get-StepFamily $lock $step
        $timeout = $defaultT
        if ($null -ne $cfg -and $null -ne $cfg.steps.$step.timeout_seconds) { $timeout = $cfg.steps.$step.timeout_seconds }
        if ($agent -eq "dsh-sub") {
            Write-Output ("{0}: agent={1}, family={2}, timeout={3}s, model={4}" -f $step, $agent, $family, $timeout, $lock.models.$step.model)
        } else {
            $exe = Get-Command $agent -ErrorAction SilentlyContinue
            $status = if ($exe) { $exe.Source } else { "N/A" }
            Write-Output ("{0}: agent={1}, family={2}, timeout={3}s, exe={4}" -f $step, $agent, $family, $timeout, $status)
        }
    }
    Write-Output "BINDING_LOCK_OK"
    exit 0
}

# F-R-01：把仓库 dsh/binding-lock.json 同步到本机锁路径（幂等，保留本机 authorization_log）
if ($InstallFromRepo) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoLock = Join-Path (Split-Path -Parent $scriptDir) "binding-lock.json"   # dsh/binding-lock.json
    if (-not (Test-Path -LiteralPath $repoLock)) {
        Fail-Cli "Missing repo binding lock template: $repoLock"
    }
    try { $repoLockData = Get-Content -LiteralPath $repoLock -Encoding UTF8 -Raw | ConvertFrom-Json }
    catch { Fail-Cli "Invalid repo binding lock JSON: $repoLock ($_)" }
    $dest = Resolve-LockPath
    if (Test-Path -LiteralPath $dest) {
        try {
            $existing = Get-Content -LiteralPath $dest -Encoding UTF8 -Raw | ConvertFrom-Json
            if ($existing.authorization_log) { $repoLockData.authorization_log = $existing.authorization_log }
        } catch {
            Write-Output "WARN=本机 lock 无法解析，将覆盖：$dest ($_)"
        }
    }
    $destParent = Split-Path -Parent $dest
    New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    $json = $repoLockData | ConvertTo-Json -Depth 6
    $tmp = $dest + ".tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $dest -Force
    Write-Output ("INSTALLED_FROM_REPO=$repoLock -> $dest")
    Write-Output "需再跑 manage_binding.ps1 -Check 确认同步后绑定有效"
    exit 0
}

# F-O01：追加记录违规到仓库 tracked 路径 docs/violations.log（避免手写覆盖历史）
if ($RecordViolation) {
    if (-not $Id -or -not $By -or -not $Reason) {
        Fail-Cli "用法：manage_binding.ps1 -RecordViolation -Id <id> -By <actor> -Reason <文本>"
    }
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)   # scripts -> dsh -> 仓库根
    $logPath = Join-Path $repoRoot "docs\violations.log"
    if (-not (Test-Path -LiteralPath $logPath)) {
        Set-Content -LiteralPath $logPath -Value "# Harness Violations Log" -Encoding UTF8
    }
    $stamp = Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz"
    $entry = "`n## $Id`n`n**时间**：$stamp`n**责任人**：$By`n**原因**：$Reason`n---`n"
    Add-Content -LiteralPath $logPath -Value $entry -Encoding UTF8
    Write-Output ("VIOLATION_RECORDED=$logPath (id=$Id, by=$By)")
    exit 0
}

if ($AuthorizeStep) {
    if ($KNOWN_STEPS -notcontains $AuthorizeStep) { Fail-Cli "未知步骤：$AuthorizeStep" }
    if (-not $AGENT_FAMILY.ContainsKey($Agent)) { Fail-Cli "未知 agent：$Agent（已知：$($AGENT_FAMILY.Keys -join ', ')）" }
    if (-not $Authorization -or $Authorization.Trim().Length -lt 12) {
        Fail-Cli "必须提供用户显式授权原文（至少 12 字符）"
    }
    $path = Resolve-LockPath
    $lock = Load-Lock $path
    # 授权前校验 CLI 可用性（dsh-sub 为 subagent，无需系统命令）
    if ($Agent -ne "dsh-sub") {
        $exe = Get-Command $Agent -ErrorAction SilentlyContinue
        if (-not $exe) {
            Fail-Cli "授权失败：PATH 无 $Agent，先安装/配置后再授权"
        }
    }
    $lock.bindings.$AuthorizeStep = $Agent
    # 写入前先校验模型族硬约束，不满足则拒绝写入（fail-closed）
    Test-Step1Step2Supported $lock
    Test-Step4FamilyDifferent $lock
    $entry = [pscustomobject]@{
        at = (Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz")
        step = $AuthorizeStep
        agent = $Agent
        authorization = $Authorization.Trim()
    }
    if ($null -eq $lock.authorization_log) { $lock.authorization_log = @() }
    $lock.authorization_log += $entry
    $json = $lock | ConvertTo-Json -Depth 6
    $tmp = $path + ".tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
    Write-Output $json
    Write-Output "AUTHORIZED"
    exit 0
}

# [P-08] 基础设施故障应急降级（镜像 opencode F-P01，target=dsh-sub；schema_version 保持 v1）
if ($EmergencyInfraFailover) {
    if ($KNOWN_STEPS -notcontains $Step) { Fail-Cli "用法：-EmergencyInfraFailover -Step <step> -FailureCategory <runner_crash|pipe_deadlock|text_repetition|process_leak|other> -FailureEvidence <证据> -Reason <文本>" }
    if (-not $FailureCategory) { Fail-Cli "-FailureCategory 必填" }
    if (@("timeout","auth_failure","model_quality") -contains $FailureCategory) {
        Fail-Cli "-FailureCategory='$FailureCategory' 不是 infra-failure（超时/认证/模型质量走拆分/循环，core-logic §4b），拒绝应急降级"
    }
    if (-not $FailureEvidence) { Fail-Cli "-FailureEvidence 必填" }
    if (-not $Reason -or $Reason.Trim().Length -lt 12) { Fail-Cli "-Reason 必填且≥12字符" }
    $path = Resolve-LockPath
    $lock = Load-Lock $path
    $originalAgent = $lock.bindings.$Step
    if (-not $originalAgent) { Fail-Cli "step '$Step' 当前无绑定" }
    $targetAgent = "dsh-sub"
    # [P-07 镜像] 前置族校验：内存改 → Test-Step4FamilyDifferent（同族即 exit，磁盘未改=fail-closed）
    $lock.bindings.$Step = $targetAgent
    Test-Step4FamilyDifferent $lock
    # pending-auth.json（独立文件，schema_version 不动）
    $pendingPath = Join-Path (Split-Path -Parent $path) "pending-auth.json"
    $raw = Get-Content -LiteralPath $pendingPath -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
    $pending = @(); if ($raw) { try { $j = $raw | ConvertFrom-Json; if ($j) { $pending = @($j) } } catch { $pending = @() } }
    $stamp = Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz"
    $pending += [pscustomobject]@{ step=$Step; original_agent=$originalAgent; target_agent=$targetAgent; timestamp=$stamp; failure_category=$FailureCategory; evidence=$FailureEvidence; reason=$Reason.Trim(); ratified=$false }
    # violations.log 结构化条目
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
    $logPath = Join-Path $repoRoot "docs\violations.log"
    if (-not (Test-Path -LiteralPath $logPath)) { Set-Content -LiteralPath $logPath -Value "# Harness Violations Log" -Encoding UTF8 }
    $vioId = "INFRA-FAILOVER-$stamp"
    $vioEntry = "`n## $vioId`n`n**时间**：$stamp`n**责任人**：orchestrator（infra-failover）`n**类别**：infra-failure`n**降级目标**：$targetAgent`n**原始绑定**：$originalAgent（$Step）`n**故障分类**：$FailureCategory`n**pending授权**：$pendingPath`n**原因**：$Reason`n---`n"
    # 原子事务（pending+violations 先，binding 最后）
    $lockTmp=$path+".tmp"; $pendingTmp=$pendingPath+".tmp"; $logTmp=$logPath+".tmp"
    try {
        $lockJson = $lock | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $lockTmp -Value $lockJson -Encoding UTF8
        $pendingJson = if ($pending.Count -eq 0) { "[]" } elseif ($pending.Count -eq 1) { "[" + ($pending | ConvertTo-Json -Depth 4) + "]" } else { $pending | ConvertTo-Json -Depth 4 }
        Set-Content -LiteralPath $pendingTmp -Value $pendingJson -Encoding UTF8
        $existing = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Encoding UTF8 -Raw } else { "" }
        Set-Content -LiteralPath $logTmp -Value ($existing + $vioEntry) -Encoding UTF8
        Move-Item -LiteralPath $pendingTmp -Destination $pendingPath -Force
        Move-Item -LiteralPath $logTmp -Destination $logPath -Force
        Move-Item -LiteralPath $lockTmp -Destination $path -Force
    } catch {
        foreach ($t in @($lockTmp,$pendingTmp,$logTmp)) { if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue } }
        Fail-Cli "应急降级原子写失败，已清理 tmp。错误：$_"
    }
    Write-Output "EMERGENCY_FAILOVER_APPLIED step=$Step original=$originalAgent target=$targetAgent category=$FailureCategory"
    Write-Output "PENDING_AUTH=$pendingPath"
    Write-Output "VIOLATION_RECORDED=$logPath (id=$vioId)"
    Write-Output $lockJson
    exit 0
}

# [P-08] session 结束清理（镜像 opencode F-P04）
if ($CleanupPendingFailovers) {
    $path = Resolve-LockPath
    $pendingPath = Join-Path (Split-Path -Parent $path) "pending-auth.json"
    if (-not (Test-Path -LiteralPath $pendingPath)) { Write-Output "CLEANUP_PENDING_NOOP=no pending-auth.json"; exit 0 }
    $raw = Get-Content -LiteralPath $pendingPath -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
    $pending = @(); if ($raw) { try { $j = $raw | ConvertFrom-Json; if ($j) { $pending = @($j) } } catch { $pending = @() } }
    $reverted = 0; $ratified = 0
    foreach ($e in $pending) {
        if ($e.ratified -eq $true) { $ratified++; continue }
        $lock = Load-Lock $path
        if ($lock.bindings.$($e.step) -eq $e.target_agent) {
            $lock.bindings.$($e.step) = $e.original_agent
            Test-Step4FamilyDifferent $lock
            $tmp = $path + ".tmp"
            Set-Content -LiteralPath $tmp -Value ($lock | ConvertTo-Json -Depth 6) -Encoding UTF8
            Move-Item -LiteralPath $tmp -Destination $path -Force
            $reverted++
        }
    }
    Set-Content -LiteralPath $pendingPath -Value "[]" -Encoding UTF8
    Write-Output "CLEANUP_PENDING_DONE reverted=$reverted ratified=$ratified"
    exit 0
}

Write-Output "用法：manage_binding.ps1 -ShowBindings | -Check | -InstallFromRepo | -RecordViolation -Id <id> -By <actor> -Reason <文本> | -AuthorizeStep <step> -Agent <agent> -Authorization <授权原文> | -EmergencyInfraFailover -Step <step> -FailureCategory <runner_crash|pipe_deadlock|text_repetition|process_leak|other> -FailureEvidence <证据> -Reason <文本> | -CleanupPendingFailovers"
exit 1
