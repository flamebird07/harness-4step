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
    [int]$MaxSplitDepth = 3
)
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Step 0：加载 binding-lock.json fail-closed 校验（详见 F-PBINDING）
$SkillDir = Split-Path -Parent $PSScriptRoot
$lockFile = Join-Path $SkillDir "binding-lock.json"
if (-not (Test-Path -LiteralPath $lockFile)) { throw "binding-lock.json missing at $lockFile" }
try {
    $lock = Get-Content -LiteralPath $lockFile -Encoding UTF8 -Raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "binding-lock.json invalid JSON — fail-closed: $($_.Exception.Message)"
}
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
    "opencode-sub" {
        if ($Step -ne "step4") {
            throw "opencode-sub is authorized only for bindings.step4 — fail-closed"
        }
        ""
    }  # 无 runner 脚本：仅合法 step4 binding 由 orchestrator 接管
    default  { throw "unknown agent in binding-lock.json: $($b.agent)" }
}

function Invoke-Runner([string]$pf, [string]$od) {
    if ($b.agent -eq "opencode-sub") {
        # Step 0 已验证：只有 bindings.step4.agent=opencode-sub 才能移交 orchestrator。
        return [pscustomobject]@{ ExitCode = 99; Output = @("BINDING=opencode-sub", "EXIT_CODE=99") }
    }
    $extra = @{ PromptFile = $pf; WorkspaceDir = $WorkspaceDir; OutDir = $od; TimeoutSeconds = $TimeoutSeconds }
    if ($b.agent -eq "claude") { $extra["Step"] = $Step; $extra["Permissions"] = $b.permission_mode }
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
    $merged | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $runnerEvFile -Encoding utf8
}

# P2(b) 修复：把"执行单分片 + 超时递归拆分"封装为函数；调度层串行调用每个预分片。
function Invoke-TaskWithSplit {
    param(
        [string]$TaskPrompt, [string]$TaskOut,
        [int]$AttemptBase, [string]$InitialSplitParent
    )
    $curPrompt = $TaskPrompt; $curOut = $TaskOut; $splitParent = $InitialSplitParent
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        New-Item -ItemType Directory -Path $curOut -Force | Out-Null
        $r = Invoke-Runner $curPrompt $curOut
        $att = $AttemptBase + $attempt - 1
        if ($r.ExitCode -eq 99) {
            Merge-Evidence $curOut 99 "handoff_pending" $att $splitParent
            return [pscustomobject]@{ ExitCode=99; Status="handoff_pending"; OutDir=$curOut; Attempt=$att; SplitParent=$splitParent }
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
        Merge-Evidence $OutDir 3 "blocked_split_limit" 1 $PromptFile
        Write-Output "EXIT_CODE=3 status=blocked_split_limit prechunk_exceeds_depth=$($chunks.Count) MaxSplitDepth=$MaxSplitDepth"
        exit 3
    }
    if ($chunks.Count -eq 1 -and $lines0.Count -lt 4) {
        Merge-Evidence $OutDir 3 "blocked_split_limit" 1 $PromptFile
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
    for ($ci = 1; $ci -le $chunks.Count; $ci++) {
        $cp  = Join-Path $preDir ("{0:D2}_prompt.txt" -f $ci)
        $cod = Join-Path $preDir ("{0:D2}" -f $ci)
        $res = Invoke-TaskWithSplit -TaskPrompt $cp -TaskOut $cod -AttemptBase $ci -InitialSplitParent $PromptFile
        Write-Output "PRECHUNK $ci/$($chunks.Count): exit=$($res.ExitCode) status=$($res.Status)"
        $results += $res
        # opencode-sub 合法 handoff：移交 orchestrator，终止后续分片调度
        if ($res.ExitCode -eq 99) {
            Write-Output "STEP4_GUARD_SNAPSHOT=$OutDir/pre-step4.sha256 (Assert deferred to orchestrator for opencode-sub)"
            Merge-Evidence $OutDir 99 "handoff_pending" 1 $PromptFile
            Write-Output "EXIT_CODE=99"; exit 99
        }
    }
    $worse = 0
    foreach ($res in $results) { if ($res.ExitCode -ne 0) { $worse = $res.ExitCode; break } }
    $status = if ($worse -eq 0) { "prechunk_success" } else { "prechunk_partial" }
    Merge-Evidence $OutDir $worse $status 1 $PromptFile
    Write-Output "EXIT_CODE=$worse status=$status"
    exit $worse
}  # end if ($lines0.Count -gt $prechunkTrigger)
# 未预拆分（prompt ≤ 60 行）：单任务执行
$res = Invoke-TaskWithSplit -TaskPrompt $PromptFile -TaskOut $OutDir -AttemptBase 1 -InitialSplitParent $null
Write-Output "EXIT_CODE=$($res.ExitCode) status=$($res.Status)"
exit $res.ExitCode
