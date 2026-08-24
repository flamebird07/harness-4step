<#
.SYNOPSIS
opencode 适配层绑定管理：加载/校验/展示 binding-lock.json，仅允许经显式用户授权改写绑定
（写入 authorization_log，tmp 原子替换）。对齐 Hermes 端 binding-lock.json + authorize_binding_change()。

V10 调用约定：bash 调本脚本及 run_step.ps1 必须 timeout=300000 + | Tee-Object -FilePath <OutDir>/run.log 实时透传，否则 EXIT_CODE/BINDING_LOCK_OK 因 120s 截断丢失
用法（bash 侧）：
  bash --timeout 300000 -c "pwsh -File manage_binding.ps1 -Check | Tee-Object -FilePath .harness/<task>/binding-check.log"
  bash --timeout 300000 -c "pwsh -File opencode/scripts/run_step.ps1 -Step step1 ... | Tee-Object -FilePath .harness/<task>/step1/run.log"
用法（pwsh 直接）：
  manage_binding.ps1 -ShowBindings                          # 展示每步绑定 + 合并配置后的超时 + 可执行文件状态
  manage_binding.ps1 -Check                                 # 校验（fail-closed）：lock 存在且有效、bindings 恰好 step1..step4、step4 与 step3 不同模型族
  manage_binding.ps1 -InstallFromRepo                       # 幂等：把仓库 opencode/binding-lock.json 同步到本机锁路径（保留本机 authorization_log）
  manage_binding.ps1 -RecordViolation -Id <id> -By <actor> -Reason "<文本>"   # 追加写入 docs/violations.log（原因+责任人+时间戳）
  manage_binding.ps1 -AuthorizeStep step3 -Agent claude -Authorization "<用户授权原文，≥12字符>"

路径：lock 默认 $HOME/.config/opencode/harness/binding-lock.json（本机私有；模板在仓库 opencode/binding-lock.json）；
       config 默认同目录 harness-config.json。环境变量覆盖：OPCODE_BINDING_LOCK / OPCODE_HARNESS_CONFIG。
#>
param(
    [string]$LockPath = $env:OPCODE_BINDING_LOCK,
    [string]$ConfigPath = $env:OPCODE_HARNESS_CONFIG,
    [switch]$ShowBindings,
    [switch]$Check,
    [switch]$InstallFromRepo,
    [switch]$RecordViolation,
    [string]$Id,
    [string]$By,
    [string]$Reason,
    [string]$AuthorizeStep,
    [string]$AuthorizeSteps,
    [string]$Agent,
    [string]$Authorization
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$KNOWN_STEPS = @("step1", "step2", "step3", "step4")
# 模型族分组：step3 与 step4 必须不同族（shared/core-logic.md §4:34）
$SUPPORTED_AGENTS = @("claude", "codex", "mimo", "kimi", "opencode-sub")

function Get-BoundAgent($Lock, [string]$Step) {
    $b = $Lock.bindings.$Step
    if ($null -eq $b) { return $null }
    if ($b -is [string]) { return $b }
    return $b.agent
}
function Set-BoundAgent($Lock, [string]$Step, [string]$Agent) {
    $b = $Lock.bindings.$Step
    if ($null -eq $b -or $b -is [string]) {
        $Lock.bindings.$Step = [pscustomobject]@{ agent = $Agent; model = $null; permission_mode = "bypassPermissions" }
    } else {
        $b.agent = $Agent
    }
}

function Resolve-LockPath {
    if ($LockPath) { return $LockPath }
    return Join-Path $HOME ".config\opencode\harness\binding-lock.json"
}
function Resolve-ConfigPath {
    if ($ConfigPath) { return $ConfigPath }
    return Join-Path $HOME ".config\opencode\harness\harness-config.json"
}
function Fail-Cli([string]$Message) {
    Write-Output ("ERROR=" + $Message)
    exit 1
}
function Load-Lock([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        Fail-Cli "Missing binding lock: $Path (从仓库 opencode/binding-lock.json 复制，见 opencode/README.md 安装 2c)"
    }
    try { $data = Get-Content -LiteralPath $Path -Encoding UTF8 -Raw | ConvertFrom-Json }
    catch { Fail-Cli "Invalid JSON in binding lock: $Path ($_)" }
    if ($data.schema_version -ne 2) { Fail-Cli "Invalid binding lock: schema_version 必须为 2（$Path）" }
    if (-not $data.locked) { Fail-Cli "Invalid binding lock: locked 必须为 true（$Path）" }
    if ($null -eq $data.backends -or @($data.backends.PSObject.Properties).Count -eq 0) { Fail-Cli "Binding lock 必须声明非空 backends（$Path）" }
    $keys = @($data.bindings.PSObject.Properties.Name)
    if (($keys | Sort-Object) -join "," -ne (($KNOWN_STEPS | Sort-Object) -join ",")) {
        Fail-Cli "Binding lock 必须恰好定义 step1, step2, step3, step4（$Path）"
    }
    foreach ($step in $KNOWN_STEPS) {
        $agent = Get-BoundAgent $data $step
        if (-not $agent -or $null -eq $data.backends.$agent) { Fail-Cli "绑定 $step='$agent' 未在 backends 中声明（$Path）" }
        $family = $data.backends.$agent.family
        if (-not ($family -is [string]) -or [string]::IsNullOrWhiteSpace($family)) { Fail-Cli "backend '$agent' 缺少非空 family（$Path）" }
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
function Test-Step4FamilyDifferent($Lock) {
    if ($null -eq $Lock.constraints -or $Lock.constraints.step4_must_differ_from_step3_family -ne $true) { Fail-Cli "Binding lock 必须设置 constraints.step4_must_differ_from_step3_family=true" }
    $step3Agent = Get-BoundAgent $Lock "step3"; $step4Agent = Get-BoundAgent $Lock "step4"
    $f3 = $Lock.backends.$step3Agent.family; $f4 = $Lock.backends.$step4Agent.family
    if ($f3 -eq $f4) {
        Fail-Cli "绑定违规：step3='$Step3Agent' 与 step4='$Step4Agent' 同模型族 '$f3'。Step 4 必须与 Step 3 不同模型族（shared/core-logic.md §4）。"
    }
}
function Test-BindingsSupported($Lock) {
    foreach ($s in $KNOWN_STEPS) {
        $a = Get-BoundAgent $Lock $s
        if ($SUPPORTED_AGENTS -notcontains $a) {
            Fail-Cli "绑定违规：$s='$a' 不受此运行器支持（受支持 agent：$($SUPPORTED_AGENTS -join ', ')）"
        }
    }
}

if ($ShowBindings -or $Check) {
    $lock = Load-Lock (Resolve-LockPath)
    $cfg = Load-Config (Resolve-ConfigPath)
    Test-BindingsSupported $lock
    Test-Step4FamilyDifferent $lock
    $defaultT = 180
    if ($null -ne $cfg -and $null -ne $cfg.defaults.timeout_seconds) { $defaultT = $cfg.defaults.timeout_seconds }
    foreach ($step in $KNOWN_STEPS) {
        $agent = Get-BoundAgent $lock $step
        $timeout = $defaultT
        if ($null -ne $cfg -and $null -ne $cfg.steps.$step.timeout_seconds) { $timeout = $cfg.steps.$step.timeout_seconds }
        $exe = Get-Command $agent -ErrorAction SilentlyContinue
        $status = if ($exe) { $exe.Source } else { "N/A" }
        Write-Output ("{0}: agent={1}, timeout={2}s, exe={3}" -f $step, $agent, $timeout, $status)
    }
    Write-Output "BINDING_LOCK_OK"
    exit 0
}

# F-R-01：把仓库 opencode/binding-lock.json 同步到本机锁路径（幂等，保留本机 authorization_log）
if ($InstallFromRepo) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoLock = Join-Path (Split-Path -Parent $scriptDir) "binding-lock.json"   # opencode/binding-lock.json
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
    # F2-A-02：确保目标锁文件父目录存在（首次安装时 ~/.config/opencode/harness/ 可能不存在）
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
    $repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)   # scripts -> opencode -> 仓库根
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

# F-P5：批量授权，单事务 read→改全部→Test-Step4FamilyDifferent→原子写（避免半改状态触发 fail-closed）。
# 接受 JSON 映射 {"step1":"claude","step4":"codex"}。-AuthorizeStep 保留向后兼容。
if ($AuthorizeSteps) {
    if (-not $Authorization -or $Authorization.Trim().Length -lt 12) {
        Fail-Cli "必须提供用户显式授权原文（至少 12 字符）"
    }
    try { $map = $AuthorizeSteps | ConvertFrom-Json } catch { Fail-Cli "-AuthorizeSteps 非合法 JSON 映射 {step:agent}: $_" }
    if ($null -eq $map) { Fail-Cli "-AuthorizeSteps 映射为空" }
    $pairs = @()
    foreach ($prop in $map.PSObject.Properties) {
        $s = $prop.Name; $ag = $prop.Value
        if ($KNOWN_STEPS -notcontains $s) { Fail-Cli "未知步骤：$s" }
        if ($SUPPORTED_AGENTS -notcontains $ag) { Fail-Cli "未知 agent：$ag" }
        $pairs += [pscustomobject]@{ Step = $s; Agent = $ag }
    }
    # F-P11Rev2：显式拒绝零项映射——{} 通过 $null 检查但 $pairs 为空，
    # 不拒绝会写 step:"all"/agent:"" 无效日志。
    if ($pairs.Count -eq 0) { Fail-Cli "-AuthorizeSteps 映射为空（无有效 step:agent 对）" }
    $path = Resolve-LockPath
    $lock = Load-Lock $path
    # 授权前校验 CLI 可用性（opencode-sub 为 subagent，无需系统命令）
    foreach ($p in $pairs) {
        if ($p.Agent -ne "opencode-sub") {
            $exe = Get-Command $p.Agent -ErrorAction SilentlyContinue
            if (-not $exe) { Fail-Cli "授权失败：PATH 无 $($p.Agent)，先安装/配置后再授权" }
        }
    }
    # 单事务：全部 Set-BoundAgent 后再统一校验约束 + 原子写（不满足约束则整体不落盘）
    foreach ($p in $pairs) { Set-BoundAgent $lock $p.Step $p.Agent }
    Test-BindingsSupported $lock
    Test-Step4FamilyDifferent $lock
    $entry = [pscustomobject]@{
        at = (Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz")
        step = "all"
        agent = (($pairs | ForEach-Object { "$($_.Step)=$($_.Agent)" }) -join ",")
        authorization = $Authorization.Trim()
    }
    if ($null -eq $lock.authorization_log) { $lock.authorization_log = @() }
    $lock.authorization_log += $entry
    $json = $lock | ConvertTo-Json -Depth 6
    $tmp = $path + ".tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8   # 原子写：先写临时文件再替换
    Move-Item -LiteralPath $tmp -Destination $path -Force
    Write-Output $json
    Write-Output "AUTHORIZED_STEPS"
    exit 0
}
if ($AuthorizeStep) {
    if ($KNOWN_STEPS -notcontains $AuthorizeStep) { Fail-Cli "未知步骤：$AuthorizeStep" }
    if ($SUPPORTED_AGENTS -notcontains $Agent) { Fail-Cli "未知 agent：$Agent" }
    if (-not $Authorization -or $Authorization.Trim().Length -lt 12) {
        Fail-Cli "必须提供用户显式授权原文（至少 12 字符）"
    }
    $path = Resolve-LockPath
    $lock = Load-Lock $path
    # F-R-02：授权前校验 CLI 可用性（opencode-sub 为 subagent，无需系统命令）
    if ($Agent -ne "opencode-sub") {
        $exe = Get-Command $Agent -ErrorAction SilentlyContinue
        if (-not $exe) {
            Fail-Cli "授权失败：PATH 无 $Agent，先安装/配置后再授权"
        }
    }
    Set-BoundAgent $lock $AuthorizeStep $Agent
    # 写入前先校验模型族硬约束，不满足则拒绝写入（fail-closed）
    Test-BindingsSupported $lock
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
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8   # 原子写：先写临时文件再替换
    Move-Item -LiteralPath $tmp -Destination $path -Force
    Write-Output $json
    Write-Output "AUTHORIZED"
    exit 0
}

Write-Output "用法：manage_binding.ps1 -ShowBindings | -Check | -InstallFromRepo | -RecordViolation -Id <id> -By <actor> -Reason <文本> | -AuthorizeStep <step> -Agent <agent> -Authorization <授权原文> | -AuthorizeSteps '{""step1"":""claude"",""step4"":""codex""}' -Authorization <授权原文>"
exit 1
