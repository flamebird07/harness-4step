<#
.SYNOPSIS
opencode 适配层绑定管理：加载/校验/展示 binding-lock.json，仅允许经显式用户授权改写绑定
（写入 authorization_log，tmp 原子替换）。对齐 Hermes 端 binding-lock.json + authorize_binding_change()。

V10 调用约定：bash 调本脚本及 run_step.ps1 必须 timeout=300000 + | Tee-Object -FilePath <OutDir>/run.log 实时透传，否则 EXIT_CODE/BINDING_LOCK_OK 因 120s 截断丢失
用法（bash 侧）：
  bash --timeout 300000 -c "powershell.exe -NoProfile -NonInteractive -NoLogo -File manage_binding.ps1 -Check | Tee-Object -FilePath .harness/<task>/binding-check.log"
  bash --timeout 300000 -c "powershell.exe -NoProfile -NonInteractive -NoLogo -File opencode/scripts/run_step.ps1 -Step step1 ... | Tee-Object -FilePath .harness/<task>/step1/run.log"
用法（powershell.exe 直接）：
  manage_binding.ps1 -ShowBindings                          # 展示每步绑定 + 合并配置后的超时 + 可执行文件状态
  manage_binding.ps1 -Check                                 # 校验（fail-closed）：lock 存在且有效、bindings 恰好 step1..step4、step4 与 step3 不同模型族
  manage_binding.ps1 -InstallFromRepo                       # 幂等：把仓库 opencode/binding-lock.json 同步到本机锁路径（保留本机 authorization_log）
  manage_binding.ps1 -RecordViolation -Id <id> -By <actor> -Reason "<文本>"   # 追加写入 docs/violations.log（原因+责任人+时间戳）
  manage_binding.ps1 -AuthorizeStep step3 -Agent claude -Authorization "<用户授权原文，≥12字符>"
  # [F-01] 并发写防护：写锁命令加 -AcquireLock <task_id> 声明持有者；lock 顶层写 last_writer（task_id+时间戳），
  #         其它会话经独占读句柄 + 读后指纹比对检测外写并 fail-closed（"锁被外部会话更新，请重读"）。
  # [F-02] 应急降级加 -CandidateAgents <a>,<b> 按序试到 step4≠step3 族约束通过（默认 opencode-sub,codex,mimo,kimi）。

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
    [string]$Authorization,
    # [F-01] 并发写防护：声明本会话持有锁的 task_id；写锁时记录 last_writer，其它会话检测到持有者非自己则 fail-closed
    [string]$AcquireLock,
    # [P-01] 应急降级参数集（与 -AuthorizeStep 语义不同：先写后补授权）
    [switch]$EmergencyInfraFailover,
    [switch]$CleanupPendingFailovers,
    [string]$Step,
    [ValidateSet("runner_crash","pipe_deadlock","text_repetition","process_leak","other","timeout","auth_failure","model_quality")]
    [string]$FailureCategory,
    [string]$FailureEvidence,
    # [F-02] 应急降级候选顺序（按序试到 step4≠step3 族约束通过；默认 opencode-sub 优先，后接外部 CLI）
    [string[]]$CandidateAgents
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$script:lockHandle = $null   # [F-01/F-06/F-01R3] sidecar mutex 句柄（挂 <Path>.mutex，不再挂数据文件本身）

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
function Get-LockFingerprint([string]$Path) {
    # [F-01] 计算锁指纹：内容 sha256（全字节十六进制）+ 最后写时间 Ticks；文件不存在返回 $null（跳过比对）
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "") + "@" + ([System.IO.File]::GetLastWriteTimeUtc($Path).Ticks)
    } catch { return $null }
}
function Get-LockOwner([string]$Path) {
    # [F-01] 返回 lock 顶层 last_writer.task_id（无则空）
    try {
        $d = Get-Content -LiteralPath $Path -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($d.last_writer -and $d.last_writer.task_id) { return ([string]$d.last_writer.task_id) }
    } catch {}
    return $null
}
function Release-LockHandle {
    # [F-01R3] 幂等释放互斥句柄（finally/catch/重入均可重复调用）
    if ($script:lockHandle) {
        try { $script:lockHandle.Close() } catch {}
        try { $script:lockHandle.Dispose() } catch {}
        $script:lockHandle = $null
    }
}
function Assert-LockWriteAvailable([string]$Path, [string]$Fingerprint) {
    # [F-01/F-06/F-01R3] 跨进程互斥：独占句柄挂 sidecar <Path>.mutex（OpenOrCreate+FileShare.None 持有全程）
    #   数据文件本身从不独占 → 不阻塞后续 Move-Item 覆盖（P-01 根因）；互斥语义完整保留（持有期=整个写事务）
    # [F-01R3/P-03] 指纹按路径读取（数据文件未独占 → 可重开），比对真正生效
    Release-LockHandle
    $mutex = $Path + ".mutex"
    try {
        $script:lockHandle = [System.IO.File]::Open($mutex, 'OpenOrCreate', 'ReadWrite', 'None')
    } catch {
        Fail-Cli "锁被外部会话持有（无法获取互斥句柄 $mutex）：$Path — 请重读后再改（F-01/F-06）"
    }
    if ($Fingerprint) {
        $cur = Get-LockFingerprint $Path
        if ($cur -and $cur -ne $Fingerprint) {
            Release-LockHandle
            $owner = Get-LockOwner $Path
            Fail-Cli "锁被外部会话更新，请重读（last_writer=$owner；本会话=$AcquireLock）— 拒绝覆盖（F-01/F-06）"
        }
    }
}
function Set-LastWriter([object]$Lock) {
    # [F-01] 在锁顶层记录本会话持有者（task_id + 时间戳）；未传 -AcquireLock 记 unknown
    $id = if ($AcquireLock) { $AcquireLock } else { "unknown" }
    $Lock | Add-Member -NotePropertyName last_writer -NotePropertyValue ([pscustomobject]@{ task_id = $id; at = (Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz") }) -Force
}
function Write-LockAtomic([object]$Lock, [string]$Path, [string]$Fingerprint) {
    # [F-01/F-06] 统一写锁出口：sidecar mutex 互斥门 → last_writer → tmp 原子替换
    # [F-01R3] 数据文件从未被自身持有 → Move-Item 覆盖不再被阻塞（"Cannot create a file when that file already exists" 消除）
    Assert-LockWriteAvailable $Path $Fingerprint
    Set-LastWriter $Lock
    $tmp = $Path + ".tmp"
    try {
        Set-Content -LiteralPath $tmp -Value ($Lock | ConvertTo-Json -Depth 6) -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } catch {
        Fail-Cli "Write-LockAtomic 失败：$_"     # 失败显式报错，不留半态
    } finally {
        Release-LockHandle
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}
function Load-Lock([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        Fail-Cli "Missing binding lock: $Path (从仓库 opencode/binding-lock.json 复制，见 opencode/README.md 安装 2c)"
    }
    try { $data = Get-Content -LiteralPath $Path -Encoding UTF8 -Raw | ConvertFrom-Json }
    catch { Fail-Cli "Invalid JSON in binding lock: $Path ($_)" }
    # [P-03] schema_version 保持 v2：pending 状态存独立 pending-auth.json，不扩展 binding-lock.json schema
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
    # [F-01] -AcquireLock 持有语义：声明持锁的会话必须独占；last_writer 是其它任务且近期（≤5min）写过的 → fail-closed
    if ($AcquireLock -and $data.last_writer -and $data.last_writer.task_id -and ([string]$data.last_writer.task_id) -ne $AcquireLock) {
        $at = $null
        try { $at = [datetime]$data.last_writer.at } catch {}
        if ($at -and ((Get-Date) - $at).TotalMinutes -le 5) {
            Fail-Cli "lock held by task_$($data.last_writer.task_id)（at=$($data.last_writer.at)）— 本会话 task_$AcquireLock 无法获取锁（F-01）"
        }
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
function Test-BindingsAllSupportedBool($Lock) {
    # [F-02] 返回 bool 的支持性探测（不 exit），供候选降级循环逐项试
    foreach ($s in $KNOWN_STEPS) {
        $a = Get-BoundAgent $Lock $s
        if ($SUPPORTED_AGENTS -notcontains $a) { return $false }
    }
    return $true
}
function Test-Step4FamilyDiffer([object]$Lock) {
    # [F-02] 返回 bool 的 step4≠step3 族约束探测（不 exit），供候选降级循环逐项试
    if ($null -eq $Lock.constraints -or $Lock.constraints.step4_must_differ_from_step3_family -ne $true) { return $false }
    $s3 = Get-BoundAgent $Lock "step3"; $s4 = Get-BoundAgent $Lock "step4"
    if (-not $s3 -or -not $s4) { return $false }
    if ($null -eq $Lock.backends.$s3 -or $null -eq $Lock.backends.$s4) { return $false }
    $f3 = $Lock.backends.$s3.family; $f4 = $Lock.backends.$s4.family
    return ($f3 -ne $f4)
}
function Test-AgentSupportedBool($Lock) {
    # [F-02] 单步 agent 支持性探测（不 exit），供候选降级循环逐项试
    $a = Get-BoundAgent $Lock $Step
    return ($SUPPORTED_AGENTS -contains $a)
}
function Test-Step4FamilyDifferentBool($Lock) {
    # [F-02] step4≠step3 族约束探测（不 exit），供候选降级循环逐项试
    # [F-05] 约束缺失 → fail-closed（返回 $false），对齐 Test-Step4FamilyDiffer 和 -Check 语义
    if ($null -eq $Lock.constraints -or $Lock.constraints.step4_must_differ_from_step3_family -ne $true) { return $false }
    $s3 = Get-BoundAgent $Lock "step3"; $s4 = Get-BoundAgent $Lock "step4"
    if (-not $s3 -or -not $s4) { return $false }
    if ($null -eq $Lock.backends.$s3 -or $null -eq $Lock.backends.$s4) { return $false }
    $f3 = $Lock.backends.$s3.family; $f4 = $Lock.backends.$s4.family
    return ($f3 -ne $f4)
}
function Test-PermissionModesValid($Lock) {
    # [F-NEW-01] -Check 校验每步 permission_mode 是当前 agent 的已知枚举（防 2026-08-23 类事故复发）
    foreach ($s in $KNOWN_STEPS) {
        $b = $Lock.bindings.$s
        if ($b -is [string]) { continue }   # 旧 schema 字符串形式绑定无 permission_mode，跳过
        $a = Get-BoundAgent $Lock $s
        $pm = $b.permission_mode
        if ($null -eq $pm -or [string]::IsNullOrWhiteSpace([string]$pm)) { $pm = "default" }
        $valid = switch ($a) {
            "claude"       { @("default", "acceptEdits", "bypassPermissions") }
            "codex"        { @("read_only", "workspace-write", "danger-full-access", "bypassPermissions", "default") }
            "mimo"         { @("read_only", "workspace-write", "danger-full-access", "bypassPermissions", "default") }
            "kimi"         { @("read_only", "workspace-write", "danger-full-access", "bypassPermissions", "default") }
            "opencode-sub" { @("default", "acceptEdits", "bypassPermissions") }
            default        { $null }
        }
        if ($null -eq $valid) { continue }
        if ($valid -notcontains $pm) {
            Fail-Cli "绑定违规：$s($a) 的 permission_mode='$pm' 非法（合法值：$($valid -join '|')）"
        }
    }
}

if ($ShowBindings -or $Check) {
    $path = Resolve-LockPath
    $lock = Load-Lock $path
    $fp0 = Get-LockFingerprint $path   # [F-01] 读后指纹，供下方 stale-pending 自动回退写锁时比对
    $cfg = Load-Config (Resolve-ConfigPath)
    Test-BindingsSupported $lock
    Test-Step4FamilyDifferent $lock
    Test-PermissionModesValid $lock    # [F-NEW-01]
    # [F-02] -Check 展示：降级禁用提示
    if ($lock.constraints -and $lock.constraints.disable_auto_degrade -eq $true) {
        Write-Output "NOTE: auto-degrade disabled (constraints.disable_auto_degrade=true)"
    }
    # [P-04] stale pending failover 检测（>24h 未 ratify → 自动回退绑定 + 警告）
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
                if ((Get-BoundAgent $lock $e.step) -eq $e.target_agent) {
                    Set-BoundAgent $lock $e.step $e.original_agent
                    Write-Output "WARN: stale pending failover (>$($e.timestamp), step=$($e.step)) auto-reverted to $($e.original_agent)"
                }
            }
            Test-Step4FamilyDifferent $lock
            Write-LockAtomic $lock $path $fp0   # [F-01] stale 回退也走并发门 + last_writer + 原子写
            # 从 pending-auth.json 移除 stale 条目（按 timestamp|step 键去重，避免对象引用比较）
            $staleKeys = @(); foreach ($e in $stale) { $staleKeys += ($e.timestamp + "|" + $e.step) }
            $remaining = @($pending | Where-Object { ($_.ratified -eq $true) -or -not ($staleKeys -contains ($_.timestamp + "|" + $_.step)) })
            $remJson = if ($remaining.Count -eq 0) { "[]" } elseif ($remaining.Count -eq 1) { "[" + ($remaining | ConvertTo-Json -Depth 4) + "]" } else { $remaining | ConvertTo-Json -Depth 4 }
            Set-Content -LiteralPath $pendingPath -Value $remJson -Encoding UTF8
        }
    }
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
    $fp0 = Get-LockFingerprint $dest   # [F-01] dest 可能不存在（首次安装）→ $null 跳过比对
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
    # [F-01R3/P-02] 安装走统一写锁出口（互斥门/指纹/last_writer/原子替换 由 Write-LockAtomic 内部完成）
    Write-LockAtomic $repoLockData $dest $fp0
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
    $fp0 = Get-LockFingerprint $path   # [F-01] 读后指纹，供 Write-LockAtomic 并发门比对
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
    Write-LockAtomic $lock $path $fp0   # [F-01] 统一出口：持有式并发门 + last_writer + tmp 原子替换
    $json = $lock | ConvertTo-Json -Depth 6
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
    $fp0 = Get-LockFingerprint $path   # [F-01] 读后指纹，供 Write-LockAtomic 并发门比对
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
    Write-LockAtomic $lock $path $fp0   # [F-01] 统一出口：持有式并发门 + last_writer + tmp 原子替换
    $json = $lock | ConvertTo-Json -Depth 6
    Write-Output $json
    Write-Output "AUTHORIZED"
    exit 0
}

# [P-01/P-02/P-05/P-06/P-07/P-11] 基础设施故障应急降级（core-logic §4b 第4项 代码实现 v13.0.39）
# 单一原子操作：binding-lock.json（绑定改 opencode-sub）+ pending-auth.json（追加 pending 条目）+ docs/violations.log（结构化 infra-failure 条目）
# pending 状态由独立文件 pending-auth.json 承载，不动 binding-lock schema_version（保持 v2，见 F-P03）。
# TargetAgent 按候选链降级（infra-failover 核心=切受支持代理，step4≠step3 族约束逐项探测，F-02）。
if ($EmergencyInfraFailover) {
    if ($KNOWN_STEPS -notcontains $Step) { Fail-Cli "用法：-EmergencyInfraFailover -Step <step> -FailureCategory <runner_crash|pipe_deadlock|text_repetition|process_leak|other> -FailureEvidence <证据> -Reason <文本>" }
    if (-not $FailureCategory) { Fail-Cli "-FailureCategory 必填（runner_crash|pipe_deadlock|text_repetition|process_leak|other）" }
    # [P-05] 明确拒绝非 infra-failure 类别（超时/认证/模型质量走拆分/循环，不走应急降级）
    if (@("timeout","auth_failure","model_quality") -contains $FailureCategory) {
        Fail-Cli "-FailureCategory='$FailureCategory' 不是 infra-failure（超时/认证/模型质量走拆分/循环，core-logic §4b），拒绝应急降级"
    }
    if (-not $FailureEvidence) { Fail-Cli "-FailureEvidence 必填（runner EXIT_CODE/stderr/evidence.json 路径等）" }
    if (-not $Reason -or $Reason.Trim().Length -lt 12) { Fail-Cli "-Reason 必填且≥12字符（infra-failure 根因描述）" }

    $path = Resolve-LockPath
    $lock = Load-Lock $path
    $fp0 = Get-LockFingerprint $path   # [F-01R3/P-04] 写前指纹（供互斥门比对，须在候选降级改内存之前取）
    # [F-02] 降级禁用开关：binding-lock.json 顶层 constraints.disable_auto_degrade=true → 拒绝降级
    if ($lock.constraints -and $lock.constraints.disable_auto_degrade -eq $true) {
        Write-Output "INFRA_FAILOVER_DISABLED step=$Step category=$FailureCategory (constraints.disable_auto_degrade=true)"
        exit 0
    }
    $originalAgent = Get-BoundAgent $lock $Step
    if (-not $originalAgent) { Fail-Cli "step '$Step' 当前无绑定，无法降级" }
    # [F-02] 候选链：按 -CandidateAgents 顺序（默认 opencode-sub, codex, mimo, kimi）试到 step4≠step3 族约束通过；耗尽即恢复原绑定后 Fail-Cli
    $candidates = if ($CandidateAgents -and $CandidateAgents.Count -gt 0) { $CandidateAgents } else { @("opencode-sub","codex","mimo","kimi") }
    $pickedAgent = $null
    foreach ($candidate in $candidates) {
        Set-BoundAgent $lock $Step $candidate
        if (-not (Test-AgentSupportedBool $lock)) { continue }
        if (-not (Test-Step4FamilyDifferentBool $lock)) { continue }
        $pickedAgent = $candidate
        break
    }
    if (-not $pickedAgent) {
        # 恢复原绑定（内存中），原始 lock 不落盘
        Set-BoundAgent $lock $Step $originalAgent
        Fail-Cli "应急降级失败：候选（$($candidates -join ', '))均不满足 step4≠step3 模型族约束或不受支持；原始绑定 $originalAgent 保留未落盘（F-02）"
    }
    $targetAgent = $pickedAgent

    # [P-07] 降级后 permission_mode 仍须为已知枚举
    Test-PermissionModesValid $lock

    # [P-02] pending 状态写入独立文件 pending-auth.json（不动 binding-lock schema_version）
    $pendingPath = Join-Path (Split-Path -Parent $path) "pending-auth.json"
    $raw = Get-Content -LiteralPath $pendingPath -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
    $pending = @()
    if ($raw) { try { $j = $raw | ConvertFrom-Json; if ($j) { $pending = @($j) } } catch { $pending = @() } }
    $stamp = Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz"
    $pending += [pscustomobject]@{
        step             = $Step
        original_agent   = $originalAgent
        target_agent     = $targetAgent
        timestamp        = $stamp
        failure_category = $FailureCategory
        evidence         = $FailureEvidence
        reason           = $Reason.Trim()
        ratified         = $false
    }

    # [P-06] violations.log 结构化 infra-failure 条目（保持人类可读 markdown + 结构化字段）
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
    $logPath = Join-Path $repoRoot "docs\violations.log"
    if (-not (Test-Path -LiteralPath $logPath)) { Set-Content -LiteralPath $logPath -Value "# Harness Violations Log" -Encoding UTF8 }
    $vioId = "INFRA-FAILOVER-$stamp"
    $vioEntry = "`n## $vioId`n`n**时间**：$stamp`n**责任人**：orchestrator（infra-failover）`n**类别**：infra-failure`n**降级目标**：$targetAgent`n**原始绑定**：$originalAgent（$Step）`n**故障分类**：$FailureCategory`n**pending授权**：$pendingPath`n**原因**：$Reason`n---`n"

    # [F-01R3/P-04] 应急降级也走并发门：sidecar mutex 互斥 + 指纹比对（防会话 A 持锁期间会话 B 覆盖）+ last_writer
    Assert-LockWriteAvailable $path $fp0
    Set-LastWriter $lock
    # [P-11] 原子事务（结构不变；选项 C 下数据文件未持有，:530 Move-Item 无需释放）
    $lockTmp = $path + ".tmp"; $pendingTmp = $pendingPath + ".tmp"; $logTmp = $logPath + ".tmp"
    $lockBak = $path + ".bak"; $pendingBak = $pendingPath + ".bak"; $logBak = $logPath + ".bak"
    $moved = @()
    try {
        $lockJson = $lock | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $lockTmp -Value $lockJson -Encoding UTF8
        $pendingJson = if ($pending.Count -eq 0) { "[]" } elseif ($pending.Count -eq 1) { "[" + ($pending | ConvertTo-Json -Depth 4) + "]" } else { $pending | ConvertTo-Json -Depth 4 }
        Set-Content -LiteralPath $pendingTmp -Value $pendingJson -Encoding UTF8
        $existing = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Encoding UTF8 -Raw } else { "" }
        Set-Content -LiteralPath $logTmp -Value ($existing + $vioEntry) -Encoding UTF8
        # 备份现有目标文件（若存在）
        if (Test-Path -LiteralPath $pendingPath) { Copy-Item -LiteralPath $pendingPath -Destination $pendingBak -Force }
        if (Test-Path -LiteralPath $logPath) { Copy-Item -LiteralPath $logPath -Destination $logBak -Force }
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $lockBak -Force }
        # 依次 Move；记录已 Move 的文件以便回滚
        Move-Item -LiteralPath $pendingTmp -Destination $pendingPath -Force; $moved += $pendingPath
        Move-Item -LiteralPath $logTmp -Destination $logPath -Force; $moved += $logPath
        Move-Item -LiteralPath $lockTmp -Destination $path -Force; $moved += $path
        # 清理备份
        foreach ($b in @($lockBak,$pendingBak,$logBak)) { if (Test-Path -LiteralPath $b) { Remove-Item -LiteralPath $b -Force -ErrorAction SilentlyContinue } }
    } catch {
        Release-LockHandle   # [F-01R3] 释放互斥句柄，回滚 Copy-Item 不受影响（数据文件本就不持有，此处为整洁释放）
        # 回滚：已 Move 的文件从备份恢复（注意反向顺序：binding→log→pending）
        foreach ($m in @($path,$logPath,$pendingPath)) {
            if ($moved -contains $m) {
                $bk = switch ($m) { $path { $lockBak } $logPath { $logBak } $pendingPath { $pendingBak } }
                if (Test-Path -LiteralPath $bk) { Copy-Item -LiteralPath $bk -Destination $m -Force }
            }
        }
        foreach ($t in @($lockTmp,$pendingTmp,$logTmp,$lockBak,$pendingBak,$logBak)) { if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue } }
        Fail-Cli "应急降级原子写失败，已回滚。错误：$_"
    }

    Write-Output "EMERGENCY_FAILOVER_APPLIED step=$Step original=$originalAgent target=$targetAgent category=$FailureCategory"
    Write-Output "PENDING_AUTH=$pendingPath (ratify via -AuthorizeStep $Step -Agent $originalAgent -Authorization <用户授权原文≥12字符>，或 session 结束 -CleanupPendingFailovers 回退)"
    Write-Output "VIOLATION_RECORDED=$logPath (id=$vioId)"
    Write-Output $lockJson
    exit 0
}

# [P-04] session 结束清理：ratified 保留记录、未 ratified 回退绑定到 original_agent
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
        $fpNow = Get-LockFingerprint $path   # [F-01R3] 每次写前取最新指纹（循环内文件被上一轮 Write-LockAtomic 改写，原循环前单次 $fp0 会假 fail-closed）
        if ((Get-BoundAgent $lock $e.step) -eq $e.target_agent) {
            Set-BoundAgent $lock $e.step $e.original_agent
            Test-BindingsSupported $lock
            Test-Step4FamilyDifferent $lock
            Write-LockAtomic $lock $path $fpNow
            $reverted++
        }
    }
    Set-Content -LiteralPath $pendingPath -Value "[]" -Encoding UTF8
    Write-Output "CLEANUP_PENDING_DONE reverted=$reverted ratified=$ratified"
    exit 0
}

Write-Output "用法：manage_binding.ps1 -ShowBindings | -Check | -InstallFromRepo | -RecordViolation -Id <id> -By <actor> -Reason <文本> | -AuthorizeStep <step> -Agent <agent> -Authorization <授权原文> | -AuthorizeSteps '{""step1"":""claude"",""step4"":""codex""}' -Authorization <授权原文> | -EmergencyInfraFailover -Step <step> -FailureCategory <runner_crash|pipe_deadlock|text_repetition|process_leak|other> -FailureEvidence <证据> -Reason <文本> | -CleanupPendingFailovers"
exit 1
