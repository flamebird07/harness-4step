# Harness 4-Step orchestrator —— opencode 适配层 v13.0.13（2026-08-18）
# V10 强制调用约定：bash 调用本脚本必须 timeout=300000 + | Tee-Object -FilePath <OutDir>/run.log 实时落盘；本脚本末尾才集中 Write-Output EXIT_CODE/ELAPSED/RAW，无行缓冲，120s 截断将丢失证据。
# 唯一逻辑源：shared/core-logic.md §4b / §6.1 / §8；变更必须先 bump SKILL.md patch 位。
# 本文件由 scripts/run_step.ps1 实施；与 Hermes harness-4step/opencode/scripts/run_step.ps1 结构平行但字段语义不同（嵌套 binding schema + Merge-Evidence）。

param(
    [Parameter(Mandatory=$true)][string]$Step,            # step1|step2|step3|step4
    [Parameter(Mandatory=$true)][string]$PromptFile,
    [Parameter(Mandatory=$true)][string]$WorkspaceDir,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [int]$TimeoutSeconds = 180,
    [int]$MaxAttempts = 3,
    [int]$MaxSplitDepth = 3,
    [int]$MaxTotalBudget = 1500,
    [string]$AddDirs = "",   # v13.0.42 ZCode 兼容：目标目录透传 runner --add-dir（逗号分隔；空=只用 cwd）  # P-07: 总预算（秒），须 < 外层 bash timeout；超限即壁死+handoff，避免外层硬杀丢证据
    [int]$MaxFailoverAttempts = 3 # F-02: 应急降级重试上限；被拒后不再静默 return，循环重试，仍失败 exit 5
)
$bomScript = Join-Path $PSScriptRoot "check-bom.ps1"
if (-not (Test-Path -LiteralPath $bomScript)) { throw "BOM gate missing: $bomScript" }
# [F-04] BOM gate 覆盖全部动态脚本 + 全部 runner（缺一 fail-closed）
$bomFiles = @(
    (Join-Path $PSScriptRoot "run_step.ps1"),
    (Join-Path $PSScriptRoot "run_claude_step12.ps1"),
    (Join-Path $PSScriptRoot "run_codex_step4.ps1"),
    (Join-Path $PSScriptRoot "run_mimo_step3.ps1"),
    (Join-Path $PSScriptRoot "run_mimo_step4.ps1"),
    (Join-Path $PSScriptRoot "run_kimi_step4.ps1"),
    (Join-Path $PSScriptRoot "run_vision_review.ps1"),
    (Join-Path $PSScriptRoot "step4_readonly_guard.ps1"),
    (Join-Path $PSScriptRoot "manage_binding.ps1"),
    $bomScript
)
$bomOutput = @(& $bomScript -Files $bomFiles 2>&1)
if ($LASTEXITCODE -ne 0) {
    $missingBom = @($bomOutput | Where-Object { $_.ToString() -match '^BOM_MISSING=' })
    throw "BOM gate failed closed: $($missingBom -join '; ')"
}
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$scriptBudgetStart = Get-Date   # P-07: 总预算计时起点

# Step 0：加载 binding-lock.json fail-closed 校验（详见 F-PBINDING）
# F-P3：执行层与管理层读同一锁（与 manage_binding.ps1 Resolve-LockPath 同源）。
# repo opencode/binding-lock.json 退化为 -InstallFromRepo 种子模板，执行时不再直读。
$lockFile = $env:OPCODE_BINDING_LOCK
if (-not $lockFile) { $lockFile = Join-Path $HOME ".config\opencode\harness\binding-lock.json" }
if (-not (Test-Path -LiteralPath $lockFile)) { throw "binding-lock.json missing at $lockFile — 先跑 manage_binding.ps1 -InstallFromRepo 从仓库模板安装本机锁" }
try {
    $lock = Get-Content -LiteralPath $lockFile -Encoding UTF8 -Raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "binding-lock.json invalid JSON — fail-closed: $($_.Exception.Message)"
}
if (-not $lock.locked) { throw "binding NOT locked — fail-closed" }
if ($lock.schema_version -ne 2) { throw "binding-lock.json schema_version must be 2 — fail-closed" }
if ($null -eq $lock.backends) { throw "binding-lock.json backends missing — fail-closed" }
$b = $lock.bindings.$Step; if (-not $b) { throw "no binding for $Step in binding-lock.json" }
if ($null -eq $lock.backends.$($b.agent)) { throw "backend '$($b.agent)' is not declared — fail-closed" }
if ($null -eq $lock.constraints -or $lock.constraints.step4_must_differ_from_step3_family -ne $true) { throw "step4 family constraint missing — fail-closed" }
$step3Agent = $lock.bindings.step3.agent
if ($null -eq $lock.backends.$step3Agent) { throw "step3 backend '$step3Agent' is not declared — fail-closed" }
if ($Step -eq "step4" -and $lock.backends.$step3Agent.family -eq $lock.backends.$($b.agent).family) {
    throw "step4 backend family must differ from step3 backend family"
}

# [F-05] 每步 timeout 与 harness-config.json 对齐：manage_binding -Check 展示的 timeout = runner 实际生效值。
# 优先级：显式 -TimeoutSeconds 参数 > harness-config.json（steps.<step>.timeout_seconds 或 defaults.timeout_seconds）> 默认 180s。
if (-not $PSBoundParameters.ContainsKey('TimeoutSeconds')) {
    $cfgPath = if ($env:OPCODE_HARNESS_CONFIG) { $env:OPCODE_HARNESS_CONFIG }
               else { Join-Path $HOME ".config\opencode\harness\harness-config.json" }
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json
            $cfgT = $null
            if ($null -ne $cfg.steps.$Step.timeout_seconds) { $cfgT = [int]$cfg.steps.$Step.timeout_seconds }
            elseif ($null -ne $cfg.defaults.timeout_seconds) { $cfgT = [int]$cfg.defaults.timeout_seconds }
            if ($cfgT -and $cfgT -gt 0) { $TimeoutSeconds = $cfgT; Write-Output "TIMEOUT_FROM_CONFIG=$Step=$TimeoutSeconds" }
        } catch { Write-Output "WARNING: harness-config.json 解析失败，使用默认 timeout=$TimeoutSeconds" }
    }
}

# Step4 只读技术强制（core-logic §8/§8b + F-08）：CLI 路径由本脚本 Save/Assert 快照自动回退并标违规；opencode-sub 路径快照由本脚本 Save、由主编排层 Assert（见 harness-orchestrator.md）
$step4GuardLoaded = $false
if ($Step -eq "step4") {
    $guardScript = Join-Path $PSScriptRoot "step4_readonly_guard.ps1"
    if (Test-Path -LiteralPath $guardScript) {
        try { . $guardScript; $step4GuardLoaded = $true } catch { Write-Output "WARNING: step4 guard load failed: $_" }
        if ($step4GuardLoaded) {
            try { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null; Save-Step4Snapshot -WorkspaceDir $WorkspaceDir -OutDir $OutDir } catch { throw "Save-Step4Snapshot failed — step4 只读强制 fail-closed（不得静默继续）: $_" }
        }
    }
}

# 选择对应 runner 脚本（按 binding.agent）
$runner = switch ($b.agent) {
    "claude" { Join-Path $PSScriptRoot "run_claude_step12.ps1" }
    "mimo"   { Join-Path $PSScriptRoot $(if ($Step -eq "step4") { "run_mimo_step4.ps1" } else { "run_mimo_step3.ps1" }) }
    "codex"  { Join-Path $PSScriptRoot "run_codex_step4.ps1" }
    "kimi"   { Join-Path $PSScriptRoot "run_kimi_step4.ps1" }
    "opencode-sub" {
        ""
    }  # 无 runner 脚本：合法 binding 由 orchestrator 的 Task 工具接管
    default  { throw "unknown agent in binding-lock.json: $($b.agent)" }
}

function Invoke-Runner([string]$pf, [string]$od) {
    if ($b.agent -eq "opencode-sub") {
        # Step 0 已验证绑定；所有四步均可移交 OpenCode 的原生 Task，绝不转调其他 CLI。
        $subagent = switch ($Step) {
            "step1" { "harness-auditor" }
            "step2" { "harness-planner" }
            "step3" { "harness-implementer" }
            "step4" { "harness-verifier" }
            default { throw "Unknown step for opencode-sub: $Step" }
        }
        return [pscustomobject]@{ ExitCode = 99; Output = @("BINDING=opencode-sub", "STEP=$Step", "SUBAGENT=$subagent", "EXIT_CODE=99") }
    }
    $extra = @{ PromptFile = $pf; WorkspaceDir = $WorkspaceDir; OutDir = $od; TimeoutSeconds = $TimeoutSeconds }
    if ($b.agent -eq "claude") { $extra["Step"] = $Step; $extra["Permissions"] = $b.permission_mode; if ($AddDirs) { $extra["AddDirs"] = $AddDirs } }
    if ($b.agent -eq "codex") { $extra["Step"] = $Step; $extra["Permissions"] = $b.permission_mode; if ($b.model) { $extra["Model"] = $b.model } }
    if ($b.agent -eq "mimo" -or $b.agent -eq "kimi") {
        $extra["Step"] = $Step
        $extra["Permissions"] = $b.permission_mode
        if ($b.model) { $extra["Model"] = $b.model }
    }
    try {
        $lines = @(& $runner @extra 2>&1 | ForEach-Object { $_.ToString() })
    } catch {
        $lines = @("RUNNER_INVOCATION_ERROR=$($_.Exception.Message)")
    }
    $m = ($lines | Select-String -Pattern '^EXIT_CODE=(-?\d+)\s*' | Select-Object -First 1)
    $ec = if ($m) { [int]($m.Matches[0].Groups[1].Value) } else { -1 }
    return [pscustomobject]@{ ExitCode = $ec; Output = $lines }
}

function Merge-Evidence([string]$od, [int]$ec, [string]$status, [int]$att, [string]$parent) {
    # 动态发现真实 output 路径：step4 reviewer 类产物 → stepN-review.md；其它 stepN-output.md
    # [F-04] 追加 step1-problems.md / step2-plan.md：审查者/方案者（claude default scoped Write）直接落盘的产品文件
    $candidates = @("$Step-review.md", "$Step-output.md", "$Step-problems.md", "$Step-plan.md")
    $realOutput = $null
    foreach ($c in $candidates) {
        $p = Join-Path $od $c
        if (Test-Path -LiteralPath $p) { $realOutput = $p; break }
    }
    # 读取 runner 既有 evidence.json 作底（如存在），缺则空对象
    $runnerEvFile = Join-Path $od "evidence.json"
    $base = if (Test-Path -LiteralPath $runnerEvFile) {
        try { Get-Content -LiteralPath $runnerEvFile -Encoding UTF8 -Raw | ConvertFrom-Json } catch { [pscustomobject]@{} }
    } else { [pscustomobject]@{} }
    # 合并：orchestrator 覆盖运行上下文；保留 runner 的 binding_snapshot / warnings。
    # Keep the runner's raw/output paths and then add the orchestration-level
    # fields.  A merged record must not discard evidence emitted by a CLI.
    $outputFiles = [ordered]@{}
    if ($base.PSObject.Properties.Name -contains 'output_files' -and $base.output_files) {
        foreach ($property in $base.output_files.PSObject.Properties) {
            $outputFiles[$property.Name] = $property.Value
        }
    }
    $outputFiles['output'] = if ($realOutput) { $realOutput } else { "<not-yet-written>" }
    $outputFiles['evidence'] = $runnerEvFile
    $merged = [ordered]@{
        schema_version   = 1
        task_id          = (Split-Path -Leaf $WorkspaceDir)
        step             = $Step
        attempt          = $att
        agent            = $b.agent
        exit_code        = $ec
        status           = $status
        split_parent     = $parent
        output_files     = $outputFiles
        timestamp        = (Get-Date).ToString("o")
    }
    if ($base.PSObject.Properties.Name -contains 'binding_snapshot') {
        $merged['binding_snapshot'] = $base.binding_snapshot
    } else {
        $snapshot = [ordered]@{ agent = $b.agent; permission_mode = $b.permission_mode }
        if ($null -ne $b.model) { $snapshot['model'] = $b.model }
        $merged['binding_snapshot'] = $snapshot
    }
    if ($base.PSObject.Properties.Name -contains 'warnings' -and $base.warnings) { $merged['warnings'] = $base.warnings }
    # [F-02] 降级被拒证据：evidence.infra_failover_attempts 数组（attempt/category/exit/detail）
    if ($script:infraFailoverAttemptsLog -and $script:infraFailoverAttemptsLog.Count -gt 0) {
        $merged['infra_failover_attempts'] = @($script:infraFailoverAttemptsLog)
    }
    $merged | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $runnerEvFile -Encoding utf8
}

# [F-07/P-06] 权威当前进度：每步完成后写 .harness/<task>/task-state.json（PS 5.1 兼容；编排层重连先读此文件）
function Write-TaskState([int]$ExitCode, [string]$Status) {
    $taskStateFile = Join-Path (Split-Path -Parent $OutDir) "task-state.json"
    $state = @{}
    if (Test-Path -LiteralPath $taskStateFile) {
        try {
            $prev = Get-Content -LiteralPath $taskStateFile -Encoding UTF8 -Raw | ConvertFrom-Json
            if ($prev) { foreach ($p in $prev.PSObject.Properties) { $state[$p.Name] = $p.Value } }   # 合并既有步骤，勿覆盖
        } catch {}
    }
    $realOutput = Join-Path $OutDir "$Step-output.md"
    if (-not (Test-Path -LiteralPath $realOutput)) { $realOutput = Join-Path $OutDir "$Step-review.md" }
    if (-not (Test-Path -LiteralPath $realOutput)) { $realOutput = Join-Path $OutDir "$Step-problems.md" }
    if (-not (Test-Path -LiteralPath $realOutput)) { $realOutput = Join-Path $OutDir "$Step-plan.md" }
    if (-not (Test-Path -LiteralPath $realOutput)) { $realOutput = "<not-yet-written>" }
    $state[$Step] = [ordered]@{
        status          = $Status
        exit_code       = $ExitCode
        completed       = ($ExitCode -eq 0)
        current_binding = $b.agent
        permission_mode = $b.permission_mode
        out_dir         = $OutDir
        last_output     = $realOutput
        timestamp       = (Get-Date).ToString("o")
    }
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $taskStateFile -Encoding UTF8
    Write-Output "TASK_STATE=$taskStateFile"
}

# P2(b) 修复：把"执行单分片 + 超时递归拆分"封装为函数；调度层串行调用每个预分片。
function Invoke-TaskWithSplit {
    param(
        [string]$TaskPrompt, [string]$TaskOut,
        [int]$AttemptBase, [string]$InitialSplitParent
    )
    $curPrompt = $TaskPrompt; $curOut = $TaskOut; $splitParent = $InitialSplitParent
    $infraFailoverApplied = $false   # [P-09] 应急降级一次性守卫，防止 opencode-sub 再失败时无限重置 attempt
    $script:infraFailoverAttempts = 0        # [F-02] 降级被拒重试计数
    $script:infraFailoverAttemptsLog = @()   # [F-02] 降级被拒证据 → evidence.infra_failover_attempts
    $script:quotaWaitActive = $false         # [F-06] quota 排队等待期间豁免总预算守卫（等待≠任务工作，超时由外层 bash timeout 兜底）
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        New-Item -ItemType Directory -Path $curOut -Force | Out-Null
        $att = $AttemptBase + $attempt - 1   # P-07 fix: assign before budget guard (was after Invoke-Runner)
        # P-07: 总预算守卫——超限即壁死（exit 3）+ handoff（由外层 F-P06/P08 发 SPLIT_BLOCKED_HANDOFF）
        # [F-06] quota 排队等待期间豁免：等待≠任务工作，超时由外层 bash timeout 兜底
        if ($MaxTotalBudget -gt 0 -and -not $script:quotaWaitActive -and ((Get-Date) - $scriptBudgetStart).TotalSeconds -gt $MaxTotalBudget) {
            Merge-Evidence $curOut 3 "blocked_split_limit" $att $splitParent
            return [pscustomobject]@{ ExitCode=3; Status="blocked_split_limit"; OutDir=$curOut; Attempt=$att; SplitParent=$splitParent; Detail="total_budget_exceeded" }
        }
        # [F-06] 内层 infra/quota 重试环：quota/INFRA 重试 continue 内环（不消耗外层 $attempt），
        # 非 infra 结果 break 交外层处理 -2 拆分 / 错误返回；exit 13 在重试数达上限时可达。
        # （修复前外层 for 封顶 3 + no_return 兜底使 quota 的 10 次排队等待永远不可达 = 死代码）
        while ($true) {
            $r = Invoke-Runner $curPrompt $curOut
            if ($r.ExitCode -eq 99) {
                Merge-Evidence $curOut 99 "handoff_pending" $att $splitParent
                # 信号不能在本函数内 Write-Output：调用方会把函数输出赋值给 $res，
                # 导致信号被吞掉。作为字段返回，最外层再写到 stdout。
                return [pscustomobject]@{ ExitCode=99; Status="handoff_pending"; OutDir=$curOut; Attempt=$att; SplitParent=$splitParent; Output=$r.Output }
            }
            if ($Step -eq "step4" -and $step4GuardLoaded -and $b.agent -ne "opencode-sub") {
                try {
                    $changed = Assert-Step4ReadOnly -WorkspaceDir $WorkspaceDir -OutDir $OutDir -Step4Agent $b.agent
                    if ($changed -and $changed.Count -gt 0) {
                        Write-Output "VIOLATION: step4 wrote files: $($changed -join ', ') — auto-reverted per core-logic §8/§8b (correctness does not exempt)"
                        Merge-Evidence $curOut 4 "violation_step4_write" $att $splitParent
                        return [pscustomobject]@{ ExitCode=4; Status="violation_step4_write"; OutDir=$curOut; Attempt=$att; SplitParent=$splitParent }
                    }
                } catch { Write-Output "WARNING: Assert-Step4ReadOnly failed: $_" }
            }
            if ($r.ExitCode -eq 0) {
                $status = "success"
                if ($Step -eq "step4" -and $b.agent -eq "mimo") {
                    $dup = $r.Output | Where-Object { $_ -match '\S' } | Group-Object { $_.Trim() } |
                           Where-Object { $_.Count -ge 5 -and $_.Name.Length -ge 20 } | Select-Object -First 1
                    if ($dup) {
                        $status = "success_with_repeat_warning"
                        Write-Output "WARNING: mimo step4 output repeats a line x$($dup.Count): '$($dup.Name.Substring(0,[Math]::Min(40,$dup.Name.Length)))'... possible degenerate generation. Suggestion: rerun step4 with kimi (binding change requires user authorization; NOT auto-switched per section 4b)."
                    }
                }
                Merge-Evidence $curOut 0 $status $att $splitParent
                return [pscustomobject]@{ ExitCode=0; Status=$status; OutDir=$curOut; Attempt=$att; SplitParent=$splitParent }
            }
            # [F-03] EXIT_CODE=-1：runner 未输出 EXIT_CODE 行 → 归入 INFRA_FAILURE:empty_output
            if ($r.ExitCode -eq -1) {
                $infraCat = "empty_output"
                # 走已有的 infra failover 路径（下方 infraCat 检测逻辑无需修改）
                $r.ExitCode = 1   # 统一为 exit 1 + INFRA_FAILURE 信号，进入已有检测块
                $r.Output += "INFRA_FAILURE:empty_output"
            }
            # [P-09/v13.0.42] 基础设施故障检测（不自动降级）
            # ============================================================
            # 设计意图（cross-platform invariant，DSH/Hermes 实现本块时参考）
            # ============================================================
            # v13.0.42 硬不变规则：CLI 不可用时**不自动改绑到另一个 backend**（orchestrator 须等用户显式授权）。
            # 但 CLI 不可用**不等于**任务失败——大多数情况是临时性，proxy 重试即可恢复：
            #
            #   ┌─────────────────────────┐    ┌─────────────────────────┐
            #   │  凭证池配额耗尽 (429)    │ →  │ 排队等待凭证轮换恢复   │
            #   │  • claude: All creds     │    │  • backoff: 60-180s     │
            #   │    exhausted/rate-limited│    │  • attempts: 10          │
            #   │  • codex: rate_limit     │    │  • 总计 ~15-30 分钟      │
            #   └─────────────────────────┘    └─────────────────────────┘
            #                              不异常退出，编排层继续 retry
            #
            #   ┌─────────────────────────┐    ┌─────────────────────────┐
            #   │  P-18 解析失败 / 空输出  │ →  │ 快速重试（凭证轮换）   │
            #   │  • Failed to parse JSON   │    │  • backoff: 5-30s        │
            #   │  • empty_output           │    │  • attempts: 3            │
            #   │  • spawn 失败             │    │  • 总计 ~1-2 分钟        │
            #   └─────────────────────────┘    └─────────────────────────┘
            #                              重试耗尽 → STOP 报告用户
            #
            # **设计关键**：并发 agent 由 proxy 凭证轮换承担（ThreadingHTTPServer + RLock），
            # **不在 runner 层强制串行**。多个 claude.exe 可并行打 proxy，proxy 轮换凭证分配。
            # 用户原话（2026-08-27）："Claude 的并发 agent 和等待功能我都要，
            # 并发不行了就排队等待，而不是直接异常"——本设计正是该要求的落地。
            #
            # **跨平台扩展点**（DSH/Hermes 适配层实现同样机制时）：
            #   - 错误信号识别：claude "Request rejected (429)" / "credentials in the pool
            #     are exhausted or rate-limited"；codex "rate_limit_exceeded"；
            #     kimi "rate limit exceeded"；mimo "rate limit"。DSH/Hermes 各自把
            #     429/quota 信号统一映射为 INFRA_FAILURE:quota_exhausted。
            #   - backoff 参数：`$quotaBackoffSeconds`（默认 60-180）+ `$quotaMaxAttempts`
            #     （默认 10）按代理轮换周期调整；DSH 默认值可不同。
            #   - 等待语义：所有平台都按"长时等待 + 多重试"实现可恢复错误的排队等待；
            #     不在 runner 层报 exit-code 给上层（编排层无需再做 STOP 决策）。
            #   - 不自动降级：统一由 v13.0.42 硬规则保护，所有平台必须 STOP 报告而非切 backend。
            # ============================================================

            $infraCat = $null
            $retryable = $false
            # quotaExhausted 单独标记：区分"等轮换"vs"快速重试"两类故障
            $quotaExhausted = $false
            if ($r.ExitCode -eq 13) {
                $infraCat = "claude_json_parse"
                $retryable = $true
                # 检测 stdout/stderr 是否含 429/quota 信号（claude proxy 当前转发上游 429/quota 字面文本）
                $quotaSignal = ($r.Output | Select-String -Pattern '(?i)429|exhausted|rate.?limit|quota|Request rejected' | Select-Object -First 1)
                if ($quotaSignal) {
                    $infraCat = "quota_exhausted"
                    $quotaExhausted = $true
                }
            } elseif ($r.ExitCode -eq 1) {
                $m = ($r.Output | Select-String -Pattern '^INFRA_FAILURE:(runner_crash|pipe_deadlock|text_repetition|process_leak|empty_output|other)\s*$' | Select-Object -First 1)
                if ($m) { $infraCat = $m.Matches[0].Groups[1].Value }
                # 纯 infra 类别（runner 自身崩溃/死锁/泄漏/空输出）也仅重试，不自动降级（v13.0.42）
                $retryable = $true
                # 检测 stdout/stderr 是否含 quota 信号
                $quotaSignal = ($r.Output | Select-String -Pattern '(?i)429|exhausted|rate.?limit|quota|Request rejected' | Select-Object -First 1)
                if ($quotaSignal) {
                    $infraCat = "quota_exhausted"
                    $quotaExhausted = $true
                }
            }
            # 不同故障类的重试参数（跨平台 invariant：429 → 长等待，其他 → 短重试）
            $currentMaxAttempts = if ($quotaExhausted) { 10 } else { $MaxFailoverAttempts }   # 10 vs 3
            $currentBackoffSeconds = if ($quotaExhausted) { 60 } else { 5 }                  # 起步 backoff
            $currentMaxBackoffSeconds = if ($quotaExhausted) { 180 } else { 30 }              # 上限 backoff

            if ($infraCat -and $retryable) {   # [F-06] 去掉 -lt $currentMaxAttempts：改由下方耗尽判断出口（内环不受外层 3 次限制）
                # [v13.0.42] 同绑定重试（不调 -EmergencyInfraFailover）：本地代理（ThreadingHTTPServer + RLock）
                # 会在配额/限流时自动轮换凭证，重试命中新凭证即可恢复，无需改绑。
                $script:infraFailoverAttempts++
                if ($quotaExhausted) {
                    # 凭证池排队等待语义：长 backoff（60-180s）等待 proxy 轮换凭证池恢复。
                    # 用户原话（2026-08-27）："并发不行了就排队等待，而不是直接异常"。
                    $sleepSeconds = $currentBackoffSeconds
                    $reasonText = "排队等待凭证轮换恢复（proxy 429/quota-exhausted；backoff 60-180s）"
                } else {
                    # 其他 INFRA_FAILURE：短重试（5-30s backoff）
                    $sleepSeconds = $currentBackoffSeconds
                    $reasonText = "同绑定快速重试"
                }
                Write-Output ("INFRA_RETRY step={0} category={1} attempt={2}/{3}（{4}；v13.0.42 不自动降级；proxy 自动轮换凭证）" -f $Step, $infraCat, $script:infraFailoverAttempts, $currentMaxAttempts, $reasonText)
                $script:infraFailoverAttemptsLog += ("attempt=$($script:infraFailoverAttempts) category=$infraCat exit=$($r.ExitCode) quota=$quotaExhausted")
                if ($script:infraFailoverAttempts -ge $currentMaxAttempts) {
                    # 重试耗尽 → 输出 INFRA_FAILURE 信号 + exit 13，编排层 STOP 报告用户（不降级）
                    $r.Output += ("INFRA_FAILURE:" + $infraCat)
                    if ($quotaExhausted) {
                        # [F-10] 编排层机器信号：明确"凭证池耗尽、已排队等待 N 次"，据此向用户报告而非静默重跑
                        Write-Output ("INFRA_FAILURE_CRED_POOL_EXHAUSTED=1 attempts={0}" -f $script:infraFailoverAttempts)
                    }
                    $detailText = if ($quotaExhausted) {
                        "凭证池排队等待 $currentMaxAttempts 次仍 429/quota-exhausted；按 v13.0.42 硬不变规则不自动降级——编排层须 STOP 并向用户报告，等用户显式授权后才能降级"
                    } else {
                        "同绑定重试 $currentMaxAttempts 次仍失败；按 v13.0.42 硬不变规则不自动降级——编排层须 STOP 并向用户报告，等用户显式授权后才能降级"
                    }
                    Merge-Evidence $curOut 13 "infra_retry_exhausted" $att $splitParent
                    Write-TaskState 13 "infra_retry_exhausted"
                    Write-Output ("INFRA_FAILURE:{0}" -f $infraCat)
                    Write-Output ("INFRA_FAILURE_DETAIL: " + $detailText)
                    Write-Output "EXIT_CODE=13"
                    exit 13   # [F-06] 现在可达（内环不受外层 3 次限制）
                }
                if ($quotaExhausted) { $script:quotaWaitActive = $true }   # [F-06] 预算豁免标志：quota 排队等待期间不壁死
                # 排队等待/快速重试前 sleep（让 proxy 凭证池有时间轮换）
                Start-Sleep -Seconds $sleepSeconds
                continue   # [F-06] 内环 continue：不消耗外层 attempt
            }
            $script:quotaWaitActive = $false
            break   # [F-06] 非 infra → 交外层处理 -2 拆分 / 错误返回
        }
        if ($r.ExitCode -ne -2) {
            Merge-Evidence $curOut $r.ExitCode "error" $att $splitParent
            return [pscustomobject]@{ ExitCode=$r.ExitCode; Status="error"; OutDir=$curOut; Attempt=$att; SplitParent=$splitParent }
        }
        # EXIT_CODE=-2：超时 → 按 §6.1 拆分
        if ($attempt -ge $MaxSplitDepth) {
            Merge-Evidence $curOut 3 "blocked_split_limit" $att $splitParent
            return [pscustomobject]@{ ExitCode=3; Status="blocked_split_limit"; OutDir=$curOut; Attempt=$att; SplitParent=$splitParent; Detail="depth=$attempt" }
        }
        $txt = Get-Content -LiteralPath $curPrompt -Encoding UTF8 -Raw
        $ln = $txt -split "`r?`n"
        if ($ln.Count -lt 4) {
            Merge-Evidence $curOut 3 "blocked_split_limit" $att $splitParent
            return [pscustomobject]@{ ExitCode=3; Status="blocked_split_limit"; OutDir=$curOut; Attempt=$att; SplitParent=$splitParent; Detail="min_granularity" }
        }
        $mid = [int]($ln.Count / 2)
        $aTxt = ($ln[0..($mid-1)] -join "`n"); $bTxt = ($ln[$mid..($ln.Count-1)] -join "`n")
        # subitems 落在 $TaskOut 下（每个预分片隔离，避免多分片递归时 path 撞车）
        $sub = Join-Path $TaskOut "subitems\$attempt"
        New-Item -ItemType Directory -Path "$sub\a","$sub\b","$sub\rejected" -Force | Out-Null
        $aTxt | Out-File -LiteralPath "$sub\a\prompt.txt" -Encoding utf8
        $bTxt | Out-File -LiteralPath "$sub\b\prompt.txt" -Encoding utf8
        try { Get-ChildItem -LiteralPath $curOut -File -ErrorAction SilentlyContinue | Move-Item -Destination "$sub\rejected\" -Force } catch {}
        $ra = Invoke-Runner "$sub\a\prompt.txt" "$sub\a"
        if ($Step -eq "step4" -and $step4GuardLoaded -and $b.agent -ne "opencode-sub") {
            try {
                $changed = Assert-Step4ReadOnly -WorkspaceDir $WorkspaceDir -OutDir $OutDir -Step4Agent $b.agent
                if ($changed -and $changed.Count -gt 0) {
                    Write-Output "VIOLATION: step4 wrote files: $($changed -join ', ') — auto-reverted per core-logic §8/§8b (correctness does not exempt)"
                    Merge-Evidence "$sub\a" 4 "violation_step4_write" $att $splitParent
                    return [pscustomobject]@{ ExitCode=4; Status="violation_step4_write"; OutDir="$sub\a"; Attempt=$att; SplitParent=$splitParent }
                }
            } catch { Write-Output "WARNING: Assert-Step4ReadOnly failed: $_" }
        }
        if ($ra.ExitCode -eq -2) {
            if (($attempt+1) -ge $MaxSplitDepth) {
                Merge-Evidence "$sub\a" 3 "blocked_split_limit" ($att+1) $curPrompt
                return [pscustomobject]@{ ExitCode=3; Status="blocked_split_limit"; OutDir="$sub\a"; Attempt=($att+1); SplitParent=$curPrompt; Detail="sub_a_timeout" }
            }
            $curPrompt = "$sub\a\prompt.txt"; $curOut = "$sub\a"; $splitParent = $curPrompt; continue
        }
        $rb = Invoke-Runner "$sub\b\prompt.txt" "$sub\b"
        if ($Step -eq "step4" -and $step4GuardLoaded -and $b.agent -ne "opencode-sub") {
            try {
                $changed = Assert-Step4ReadOnly -WorkspaceDir $WorkspaceDir -OutDir $OutDir -Step4Agent $b.agent
                if ($changed -and $changed.Count -gt 0) {
                    Write-Output "VIOLATION: step4 wrote files: $($changed -join ', ') — auto-reverted per core-logic §8/§8b (correctness does not exempt)"
                    Merge-Evidence "$sub\b" 4 "violation_step4_write" $att $splitParent
                    return [pscustomobject]@{ ExitCode=4; Status="violation_step4_write"; OutDir="$sub\b"; Attempt=$att; SplitParent=$splitParent }
                }
            } catch { Write-Output "WARNING: Assert-Step4ReadOnly failed: $_" }
        }
        if ($rb.ExitCode -eq -2) {
            if (($attempt+1) -ge $MaxSplitDepth) {
                Merge-Evidence "$sub\b" 3 "blocked_split_limit" ($att+1) $curPrompt
                return [pscustomobject]@{ ExitCode=3; Status="blocked_split_limit"; OutDir="$sub\b"; Attempt=($att+1); SplitParent=$curPrompt; Detail="sub_b_timeout" }
            }
            $curPrompt = "$sub\b\prompt.txt"; $curOut = "$sub\b"; $splitParent = $curPrompt; continue
        }
        $worse = if ($ra.ExitCode -ne 0) { $ra.ExitCode } else { $rb.ExitCode }
        $status = if ($worse -eq 0) { "split_success" } else { "split_partial" }
        Merge-Evidence $TaskOut $worse $status $att $curPrompt
        return [pscustomobject]@{ ExitCode=$worse; Status=$status; OutDir=$curOut; Attempt=$att; SplitParent=$curPrompt }
    }
    return [pscustomobject]@{ ExitCode=-1; Status="no_return"; OutDir=$curOut; Attempt=$AttemptBase; SplitParent=$splitParent }
}

# 主循环：尝试 → 成功/非超时退出 → 超时则按 §4b 拆一次
$curPrompt = $PromptFile
$curOut = $OutDir
# Step 0：主动预拆分（P-14）—— prompt 超过 60 行或 6,000 UTF-8 字符时按段落边界预拆，
# 避免一条超长行绕过行数阈值而让 Claude 在 Windows 上长时间占用 stdin。
$prechunkLines = 80        # [F-08] 放宽：每 chunk 目标行数（原 40）
$prechunkTrigger = 120     # [F-08] 放宽：触发行数阈值（原 60）
$chunkCharCap = 15000      # [F-08] 放宽：内层单 chunk 字节上限（原 5000，P-07：原 5000 使放宽后 15000+ 字节方案仍被切 ≥3 片）
$txt0 = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw
$lines0 = $txt0 -split "`r?`n"
$promptChars = [System.Text.Encoding]::UTF8.GetByteCount($txt0)
$preDir = Join-Path $OutDir "prechunks"
$splitParent = $null
# P-01: 所有绑定统一 prechunk，长 prompt 由每个 chunk 独立移交/执行，避免丢失后续 chunks。
if ($lines0.Count -gt $prechunkTrigger -or $promptChars -gt 15000) {   # [F-08] 字节阈值 6000→15000（中文 3 字节/字符 ≈ 5000 中文字）
    New-Item -ItemType Directory -Path $preDir -Force | Out-Null
    $chunks = New-Object System.Collections.ArrayList
    $cur = New-Object System.Collections.ArrayList
    foreach ($l in $lines0) {
        $cur.Add($l) | Out-Null
        # A single pasted paragraph may be enormous.  It needs a character
        # bound too; keep it as a standalone work package rather than sending
        # the entire original prompt to the CLI.
        $chunkChars = [System.Text.Encoding]::UTF8.GetByteCount(($cur -join "`n"))
        $isParagraphBreak = ($l.Trim() -eq "" -or $cur.Count -ge $prechunkLines -or $chunkChars -ge $chunkCharCap)
        if ($isParagraphBreak) {
            if ($cur.Count -ge 4) {
                [void]$chunks.Add(($cur -join "`n"))
                $cur = New-Object System.Collections.ArrayList
            } elseif ($chunks.Count -gt 0) {
                $chunks[$chunks.Count - 1] += "`n" + ($cur -join "`n")
                $cur = New-Object System.Collections.ArrayList
            }
        }
    }
    if ($cur.Count -gt 0) { [void]$chunks.Add(($cur -join "`n")) }
    # P-02: prechunk 分片数不受 MaxSplitDepth 约束（那是递归拆分深度壁垒 §6.1，不是 prechunk 分片数）。
    # 原代码用 MaxSplitDepth 封顶 prechunk 分片数 → >3 片 prompt 直接壁死丢数据，已移除。
    # 串行调度循环（下方）天然处理任意 N 片；超大 prompt 由 Invoke-TaskWithSplit 内部递归拆分兜底。
    if ($chunks.Count -eq 1 -and $lines0.Count -lt 4) {
        Merge-Evidence $OutDir 3 "blocked_split_limit" 1 $PromptFile
        Write-TaskState 3 "blocked_split_limit"
        Write-Output "EXIT_CODE=3 status=blocked_split_limit min_granularity prechunk"
        exit 3
    }
    $i = 0
    foreach ($chunk in $chunks) {
        $i++
        $cp = Join-Path $preDir ("{0:D2}_prompt.txt" -f $i)
        $chunk | Out-File -LiteralPath $cp -Encoding utf8
    }
    # 串行调度每个预分片（修复：02+ 不再静默丢弃）
    $results = @()
    $handoffs = @()
    for ($ci = 1; $ci -le $chunks.Count; $ci++) {
        $cp  = Join-Path $preDir ("{0:D2}_prompt.txt" -f $ci)
        $cod = Join-Path $preDir ("{0:D2}" -f $ci)
        $res = Invoke-TaskWithSplit -TaskPrompt $cp -TaskOut $cod -AttemptBase $ci -InitialSplitParent $PromptFile
        Write-Output "PRECHUNK $ci/$($chunks.Count): exit=$($res.ExitCode) status=$($res.Status)"
        $results += $res
        # opencode-sub handoff：保留并聚合全部分片信号，继续调度后续分片。
        if ($res.ExitCode -eq 99) {
            foreach ($line in $res.Output) {
                $handoffs += [pscustomobject]@{ Chunk = $ci; Line = $line }
                Write-Output "PRECHUNK_HANDOFF $ci/$($chunks.Count): $line"
            }
        }
    }
    if ($handoffs.Count -gt 0) {
        $subagent = ($handoffs | Where-Object { $_.Line -match '^SUBAGENT=' } | Select-Object -First 1).Line -replace '^SUBAGENT=', ''
        if (-not $subagent) { $subagent = "unknown" }
        Write-Output "BINDING=opencode-sub STEP=$Step SUBAGENT=$subagent CHUNKS=$($chunks.Count) EXIT_CODE=99"
        foreach ($h in $handoffs) { Write-Output "PRECHUNK_HANDOFF_CHUNK=$($h.Chunk)/$($chunks.Count) $($h.Line)" }
        Merge-Evidence $OutDir 99 "handoff_pending" 1 $PromptFile
        Write-TaskState 99 "handoff_pending"
        Write-Output "EXIT_CODE=99"; exit 99
    }
    $worse = 0
    foreach ($res in $results) { if ($res.ExitCode -ne 0) { $worse = $res.ExitCode; break } }
    $status = if ($worse -eq 0) { "prechunk_success" } else { "prechunk_partial" }
    Merge-Evidence $OutDir $worse $status 1 $PromptFile
    # P-06/P-08: 壁死后 handoff（prechunk 路径）——编排层消费信号对原 prompt 做语义重拆
    if ($worse -eq 3) { Write-Output "SPLIT_BLOCKED_HANDOFF=$PromptFile NEEDS_SEMANTIC_RESPLIT=1" }
    Write-TaskState $worse $status
    Write-Output "EXIT_CODE=$worse status=$status"
    exit $worse
}  # end if ($lines0.Count -gt $prechunkTrigger)
# 未预拆分（prompt ≤ 60 行 或 opencode-sub）：单任务执行
$res = Invoke-TaskWithSplit -TaskPrompt $PromptFile -TaskOut $OutDir -AttemptBase 1 -InitialSplitParent $null
if ($res.ExitCode -eq 99) {
    foreach ($line in $res.Output) { Write-Output $line }
}
# P-06/P-08: 壁死后 handoff（单任务路径）——编排层消费信号对原 prompt 做语义重拆（不换绑定、不豁免 §8b）
if ($res.ExitCode -eq 3) { Write-Output "SPLIT_BLOCKED_HANDOFF=$PromptFile NEEDS_SEMANTIC_RESPLIT=1" }
Write-TaskState $res.ExitCode $res.Status
Write-Output "EXIT_CODE=$($res.ExitCode) status=$($res.Status)"
exit $res.ExitCode
