<#
.SYNOPSIS
opencode 适配层绑定管理：加载/校验/展示 binding-lock.json，仅允许经显式用户授权改写绑定
（写入 authorization_log，tmp 原子替换）。对齐 Hermes 端 binding-lock.json + authorize_binding_change()。

用法：
  manage_binding.ps1 -ShowBindings                          # 展示每步绑定 + 合并配置后的超时 + 可执行文件状态
  manage_binding.ps1 -Check                                 # 校验（fail-closed）：lock 存在且有效、bindings 恰好 step1..step4、step4 与 step3 不同模型族
  manage_binding.ps1 -AuthorizeStep step3 -Agent claude -Authorization "<用户授权原文，≥12字符>"

路径：lock 默认 $HOME/.config/opencode/harness/binding-lock.json（本机私有；模板在仓库 opencode/binding-lock.json）；
      config 默认同目录 harness-config.json。环境变量覆盖：OPCODE_BINDING_LOCK / OPCODE_HARNESS_CONFIG。
#>
param(
    [string]$LockPath = $env:OPCODE_BINDING_LOCK,
    [string]$ConfigPath = $env:OPCODE_HARNESS_CONFIG,
    [switch]$ShowBindings,
    [switch]$Check,
    [string]$AuthorizeStep,
    [string]$Agent,
    [string]$Authorization
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$KNOWN_STEPS = @("step1", "step2", "step3", "step4")
# 模型族分组：step3 与 step4 必须不同族（shared/core-logic.md §4:34）
$AGENT_FAMILY = @{
    "claude" = "claude"; "codex" = "openai"; "mimo" = "mimo";
    "kimi" = "moonshot"; "opencode-sub" = "opencode-main"   # 统一受支持集合（去 gemini，run_step.ps1 分派器不支持）
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
function Test-Step4FamilyDifferent([string]$Step3Agent, [string]$Step4Agent) {
    $f3 = $AGENT_FAMILY[$Step3Agent]; $f4 = $AGENT_FAMILY[$Step4Agent]
    if (-not $f3) { Fail-Cli "未知 step3 agent '$Step3Agent'（已知：$($AGENT_FAMILY.Keys -join ', ')）" }
    if (-not $f4) { Fail-Cli "未知 step4 agent '$Step4Agent'（已知：$($AGENT_FAMILY.Keys -join ', ')）" }
    if ($f3 -eq $f4) {
        Fail-Cli "绑定违规：step3='$Step3Agent' 与 step4='$Step4Agent' 同模型族 '$f3'。Step 4 必须与 Step 3 不同模型族（shared/core-logic.md §4）。"
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
    $lock = Load-Lock (Resolve-LockPath)
    $cfg = Load-Config (Resolve-ConfigPath)
    Test-Step1Step2Supported $lock
    Test-Step4FamilyDifferent $lock.bindings.step3 $lock.bindings.step4
    $defaultT = 180
    if ($null -ne $cfg -and $null -ne $cfg.defaults.timeout_seconds) { $defaultT = $cfg.defaults.timeout_seconds }
    foreach ($step in $KNOWN_STEPS) {
        $agent = $lock.bindings.$step
        $timeout = $defaultT
        if ($null -ne $cfg -and $null -ne $cfg.steps.$step.timeout_seconds) { $timeout = $cfg.steps.$step.timeout_seconds }
        $exe = Get-Command $agent -ErrorAction SilentlyContinue
        $status = if ($exe) { $exe.Source } else { "N/A" }
        Write-Output ("{0}: agent={1}, timeout={2}s, exe={3}" -f $step, $agent, $timeout, $status)
    }
    Write-Output "BINDING_LOCK_OK"
    exit 0
}

if ($AuthorizeStep) {
    if ($KNOWN_STEPS -notcontains $AuthorizeStep) { Fail-Cli "未知步骤：$AuthorizeStep" }
    if (-not $AGENT_FAMILY.ContainsKey($Agent)) { Fail-Cli "未知 agent：$Agent" }
    if (-not $Authorization -or $Authorization.Trim().Length -lt 12) {
        Fail-Cli "必须提供用户显式授权原文（至少 12 字符）"
    }
    $path = Resolve-LockPath
    $lock = Load-Lock $path
    $lock.bindings.$AuthorizeStep = $Agent
    # 写入前先校验模型族硬约束，不满足则拒绝写入（fail-closed）
    Test-Step1Step2Supported $lock
    Test-Step4FamilyDifferent $lock.bindings.step3 $lock.bindings.step4
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

Write-Output "用法：manage_binding.ps1 -ShowBindings | -Check | -AuthorizeStep <step> -Agent <agent> -Authorization <授权原文>"
exit 1
