# Harness 4-Step orchestrator —— opencode 适配层 v13.0.13（2026-08-18）
# V10 强制调用约定：bash 调用本脚本必须 timeout=300000 + | Tee-Object -FilePath <OutDir>/run.log 实时落盘；本脚本末尾才集中 Write-Output EXIT_CODE/ELAPSED/RAW，无行缓冲，120s 截断将丢失证据。
# 唯一逻辑源：shared/core-logic.md §4b / §6.1 / §8；变更必须先 bump SKILL.md patch 位。
# 本文件由 scripts/run_step.ps1 实施；与 Hermes harness-4step/opencode/scripts/run_step.ps1 结构平行但字段语义不同（嵌套 binding schema + Merge-Evidence）。

param(
    [Parameter(Mandatory=$true)][string]$Step,            # step1|step2|step3|step4
    [Parameter(Mandatory=$true)][string]$PromptFile,
    [Parameter(Mandatory=$true)][string]$WorkspaceDir,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [int]$TimeoutSeconds = 900,
    [int]$MaxAttempts = 3,
    [int]$MaxSplitDepth = 3
)
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Step 0：加载 binding-lock.json fail-closed 校验（详见 F-PBINDING）
$SkillDir = Split-Path -Parent $PSScriptRoot
$lockFile = Join-Path $SkillDir "binding-lock.json"
if (-not (Test-Path -LiteralPath $lockFile)) { throw "binding-lock.json missing at $lockFile" }
$lock = Get-Content -LiteralPath $lockFile -Encoding UTF8 -Raw | ConvertFrom-Json
if (-not $lock.locked) { throw "binding NOT locked — fail-closed" }
$b = $lock.bindings.$Step; if (-not $b) { throw "no binding for $Step in binding-lock.json" }
if ($Step -eq "step4" -and $lock.constraints.step4_must_differ_from_step3_family) {
    if ($lock.bindings.step3.agent -eq $b.agent) {
        throw "step4 agent ($($b.agent)) must differ from step3 agent ($($lock.bindings.step3.agent)) family"
    }
}

# Step4 只读技术强制（core-logic §8/§8b + F-08）：CLI 路径由本脚本 Save/Assert 快照自动回退并标违规；opencode-sub 路径快照由本脚本 Save、由主编排层 Assert（见 harness-orchestrator.md）
$step4GuardLoaded = $false
if ($Step -eq "step4") {
    $guardScript = Join-Path $PSScriptRoot "step4_readonly_guard.ps1"
    if (Test-Path -LiteralPath $guardScript) {
        try { . $guardScript; $step4GuardLoaded = $true } catch { Write-Output "WARNING: step4 guard load failed: $_" }
        if ($step4GuardLoaded) {
            try { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null; Save-Step4Snapshot -WorkspaceDir $WorkspaceDir -OutDir $OutDir } catch { Write-Output "WARNING: Save-Step4Snapshot failed: $_" }
        }
    }
}

# 选择对应 runner 脚本（按 binding.agent）
$runner = switch ($b.agent) {
    "claude" { Join-Path $PSScriptRoot "run_claude_step12.ps1" }
    "mimo"   { Join-Path $PSScriptRoot $(if ($Step -eq "step4") { "run_mimo_step4.ps1" } else { "run_mimo_step3.ps1" }) }
    "codex"  { Join-Path $PSScriptRoot "run_codex_step4.ps1" }
    "kimi"   { Join-Path $PSScriptRoot "run_kimi_step4.ps1" }
    "opencode-sub" { "" }  # 无 runner 脚本：主 agent 用 Task 调 subagent（harness-auditor/planner/implementer/verifier）——快照 Assert 由主编排层在 Task 返回后执行
    default  { throw "unknown agent in binding-lock.json: $($b.agent)" }
}

function Invoke-Runner([string]$pf, [string]$od) {
    if ($b.agent -eq "opencode-sub") {
        # 主 agent 用 Task 调 subagent：输出 BINDING=opencode-sub + exit 99 让调度者接管
        return [pscustomobject]@{ ExitCode = 99; Output = @("BINDING=opencode-sub", "EXIT_CODE=99") }
    }
    $extra = @{ PromptFile = $pf; WorkspaceDir = $WorkspaceDir; OutDir = $od; TimeoutSeconds = $TimeoutSeconds }
    if ($b.agent -eq "claude") { $extra["Step"] = $Step; $extra["Permissions"] = $b.permission_mode }
    $lines = & $runner @extra 2>&1
    $m = ($lines | Select-String -Pattern '^EXIT_CODE=(-?\d+)\s*' | Select-Object -First 1)
    $ec = if ($m) { [int]($m.Matches[0].Groups[1].Value) } else { -1 }
    return [pscustomobject]@{ ExitCode = $ec; Output = $lines }
}

function Merge-Evidence([string]$od, [int]$ec, [string]$status, [int]$att, [string]$parent) {
    # 动态发现真实 output 路径：step4 reviewer 类产物 → stepN-review.md；其它 stepN-output.md
    $candidates = @("$Step-review.md", "$Step-output.md")
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
    # 合并：orchestrator 覆盖 schema/step/attempt/agent/exit/status/split_parent/output_files/timestamp；保留 base 的 binding_snapshot / warnings
    $merged = [ordered]@{
        schema_version   = 1
        task_id          = (Split-Path -Leaf $WorkspaceDir)
        step             = $Step
        attempt          = $att
        agent            = $b.agent
        exit_code        = $ec
        status           = $status
        split_parent     = $parent
        output_files     = [ordered]@{
            output    = if ($realOutput) { $realOutput } else { "<not-yet-written>" }
            evidence  = $runnerEvFile
        }
        timestamp        = (Get-Date).ToString("o")
    }
    if ($base.PSObject.Properties.Name -contains 'binding_snapshot') { $merged['binding_snapshot'] = $base.binding_snapshot }
    if ($base.PSObject.Properties.Name -contains 'warnings' -and $base.warnings) { $merged['warnings'] = $base.warnings }
    $merged | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $runnerEvFile -Encoding utf8
}

# 主循环：尝试 → 成功/非超时退出 → 超时则按 §4b 拆一次
$curPrompt = $PromptFile
$curOut = $OutDir
# Step 0：主动预拆分（P-14）—— prompt 行数 > 60 时按段落边界预拆为 ≤40 行的子任务，
# 避免 claude/mimo 长 prompt 直接超时（BLOCKED_SPLIT_LIMIT 只在超时后才被动触发）。
$prechunkLines = 40
$prechunkTrigger = 60
$txt0 = Get-Content -LiteralPath $PromptFile -Encoding UTF8 -Raw
$lines0 = $txt0 -split "`r?`n"
$preDir = Join-Path $OutDir "prechunks"
$splitParent = $null
if ($lines0.Count -gt $prechunkTrigger) {
    New-Item -ItemType Directory -Path $preDir -Force | Out-Null
    $chunks = New-Object System.Collections.ArrayList
    $cur = New-Object System.Collections.ArrayList
    foreach ($l in $lines0) {
        $cur.Add($l) | Out-Null
        $isParagraphBreak = ($l.Trim() -eq "" -or $cur.Count -ge $prechunkLines)
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
    # V11 壁垒：prechunk 受 MaxSplitDepth 与最小粒度约束，不得绕过 §6.1
    if ($chunks.Count -gt $MaxSplitDepth) {
        Merge-Evidence $OutDir -2 "blocked_split_limit" 1 $PromptFile
        Write-Output "EXIT_CODE=3 status=blocked_split_limit prechunk_exceeds_depth=$($chunks.Count) MaxSplitDepth=$MaxSplitDepth"
        exit 3
    }
    if ($chunks.Count -eq 1 -and $lines0.Count -lt 4) {
        Merge-Evidence $OutDir -2 "blocked_split_limit" 1 $PromptFile
        Write-Output "EXIT_CODE=3 status=blocked_split_limit min_granularity prechunk"
        exit 3
    }
    $i = 0
    foreach ($chunk in $chunks) {
        $i++
        $cp = Join-Path $preDir ("{0:D2}_prompt.txt" -f $i)
        $chunk | Out-File -LiteralPath $cp -Encoding utf8
    }
    $curPrompt = Join-Path $preDir "01_prompt.txt"
    $curOut = Join-Path $preDir "01"
    New-Item -ItemType Directory -Path $curOut -Force | Out-Null
    $splitParent = $PromptFile
}
# 调用方已用 Tee-Object 实时透传（V10），本循环末尾 Write-Output EXIT_CODE/ELAPSED/RAW 才会增量落盘
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    New-Item -ItemType Directory -Path $curOut -Force | Out-Null
    $r = Invoke-Runner $curPrompt $curOut
    if ($r.ExitCode -eq 99) {
        # opencode-sub 分派：主 agent 接管（Task 调 subagent），不在此写 evidence；快照已在脚本头部 Save，Assert 由主编排层在 subagent 返回后执行（harness-orchestrator.md 违规记录强制点 1）
        Write-Output "STEP4_GUARD_SNAPSHOT=$OutDir/pre-step4.sha256 (Assert deferred to orchestrator for opencode-sub)"
        Write-Output "EXIT_CODE=99"
        exit 99
    }
    # Step4 CLI 路径：每次 runner 返回后立即 Assert 快照（§8b 正确性不豁免：即使测试通过也回退）
    if ($Step -eq "step4" -and $step4GuardLoaded -and $b.agent -ne "opencode-sub") {
        try {
            $changed = Assert-Step4ReadOnly -WorkspaceDir $WorkspaceDir -OutDir $OutDir -Step4Agent $b.agent
            if ($changed -and $changed.Count -gt 0) {
                Write-Output "VIOLATION: step4 wrote files: $($changed -join ', ') — auto-reverted per core-logic §8/§8b (correctness does not exempt)"
                Merge-Evidence $curOut 4 "violation_step4_write" $attempt $splitParent
                Write-Output "EXIT_CODE=4 status=violation_step4_write"
                exit 4
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
        Merge-Evidence $curOut 0 $status $attempt $splitParent
        Write-Output "EXIT_CODE=0"; exit 0
    }
    if ($r.ExitCode -ne -2) {
        Merge-Evidence $curOut $r.ExitCode "error" $attempt $splitParent
        Write-Output "EXIT_CODE=$($r.ExitCode)"; exit $r.ExitCode
    }
    # V11 修复：移除 step4 auto_pass_timeout 静默转 success；EXIT_CODE=-2 必须立即走 §6.1 拆分（见下方 MaxSplitDepth/最小粒度壁垒），不得 exit 0
    # 否则拆一次 prompt，分别跑两半；若任一半仍超时则 BLOCKED_SPLIT_LIMIT
    if ($attempt -ge $MaxSplitDepth) {
        Merge-Evidence $curOut -2 "blocked_split_limit" $attempt $splitParent
        Write-Output "EXIT_CODE=3 status=blocked_split_limit depth=$attempt"; exit 3
    }
    $txt = Get-Content -LiteralPath $curPrompt -Encoding UTF8 -Raw
    $ln = $txt -split "`r?`n"
    if ($ln.Count -lt 4) {
        # 已是最小粒度（< 4 行 ≈ 单文件，见 shared/core-logic.md §6.1）不能再拆
        Merge-Evidence $curOut -2 "blocked_split_limit" $attempt $splitParent
        Write-Output "EXIT_CODE=3 status=blocked_split_limit min_granularity"; exit 3
    }
    $mid = [int]($ln.Count / 2)
    $aTxt = ($ln[0..($mid-1)] -join "`n")
    $bTxt = ($ln[$mid..($ln.Count-1)] -join "`n")
    $sub = Join-Path $OutDir "subitems\$attempt"
    New-Item -ItemType Directory -Path "$sub\a","$sub\b","$sub\rejected" -Force | Out-Null
    $aTxt | Out-File -LiteralPath "$sub\a\prompt.txt" -Encoding utf8
    $bTxt | Out-File -LiteralPath "$sub\b\prompt.txt" -Encoding utf8
    # rejected Move-Item 使用 -Force：当前每 attempt 后立即 exit，调度器无重试路径；
    # 若未来调度引入重试，应改为带 attempt 编号子目录以避免覆盖。
    try { Get-ChildItem -LiteralPath $curOut -File -ErrorAction SilentlyContinue | Move-Item -Destination "$sub\rejected\" -Force } catch {}
    $ra = Invoke-Runner "$sub\a\prompt.txt" "$sub\a"
    if ($ra.ExitCode -eq -2) {
        if (($attempt+1) -ge $MaxSplitDepth) {
            Merge-Evidence "$sub\a" -2 "blocked_split_limit" ($attempt+1) $curPrompt
            Write-Output "EXIT_CODE=3 status=blocked_split_limit sub_a_timeout depth=$($attempt+1)"; exit 3
        }
        $curPrompt = "$sub\a\prompt.txt"; $curOut = "$sub\a"; $splitParent = $curPrompt
        continue
    }
    $rb = Invoke-Runner "$sub\b\prompt.txt" "$sub\b"
    if ($rb.ExitCode -eq -2) {
        if (($attempt+1) -ge $MaxSplitDepth) {
            Merge-Evidence "$sub\b" -2 "blocked_split_limit" ($attempt+1) $curPrompt
            Write-Output "EXIT_CODE=3 status=blocked_split_limit sub_b_timeout depth=$($attempt+1)"; exit 3
        }
        $curPrompt = "$sub\b\prompt.txt"; $curOut = "$sub\b"; $splitParent = $curPrompt
        continue
    }
    # 子项 evidence 已在 $sub\a / $sub\b 各自落盘（exit_code=-2 保留）；父 evidence 的 exit_code=$worse 不覆盖子项 -2
    $worse = if ($ra.ExitCode -ne 0) { $ra.ExitCode } else { $rb.ExitCode }
    $status = if ($worse -eq 0) { "split_success" } else { "split_partial" }
    Merge-Evidence $OutDir $worse $status $attempt $curPrompt
    Write-Output "EXIT_CODE=$worse status=$status"
    exit $worse
}
