# step4_readonly_guard.ps1 — P-08 Step 4 只读技术强制（Layer B）
# 导出：
#   Save-Step4Snapshot -WorkspaceDir <dir> -OutDir <dir>
#   Assert-Step4ReadOnly -WorkspaceDir <dir> -OutDir <dir> -Step4Agent <agent> -ViolationsLog
<#
.SYNOPSIS
Step 4 只读技术强制（P-08）：step4 运行前对受监控文件做 sha256 快照 + 内容备份，
运行后比对，越权写文件即自动回退 + 记录违规 + 返回差异列表。
#>
# P1 修复：Save/Assert 共用的路径规范化。
# Resolve-Path 消除正/反斜杠差异、尾斜杠、./..；仅当 OutDir 严格位于 Workspace 内
# 才返回 OutRel（否则 $null → 不排除任何东西，避免误判 OutDir 产物为越权新建）。
function Get-Step4PathContext {
    param([string]$WorkspaceDir, [string]$OutDir)
    $ws = (Resolve-Path -LiteralPath $WorkspaceDir -ErrorAction Stop).Path -replace '/', '\'
    $ws = $ws.TrimEnd('\')
    # P5：OutDir 必须严格位于 Workspace 内，否则无可靠排除基线——fail-closed 抛错，替换原静默 $null 逻辑。
    if (-not (Test-Path -LiteralPath $OutDir)) {
        throw "step4 guard: OutDir 不存在，无法建立排除基线 — fail-closed: $OutDir"
    }
    $od = (Resolve-Path -LiteralPath $OutDir -ErrorAction Stop).Path -replace '/', '\'
    $od = $od.TrimEnd('\')
    if ($od -eq $ws) {
        throw "step4 guard: OutDir==WorkspaceDir（配置错误，无排除基线）— fail-closed: $od"
    }
    if (-not $od.StartsWith($ws + '\')) {
        throw "step4 guard: OutDir 不在 WorkspaceDir 内（配置错误）— fail-closed: $od"
    }
    $outRel = $od.Substring($ws.Length).TrimStart('\')
    return [pscustomobject]@{ Workspace = $ws; OutRel = $outRel }
}
function Save-Step4Snapshot {
    param([string]$WorkspaceDir, [string]$OutDir)
    # P3：枚举/哈希失败必须 fail-closed——函数作用域内置 Stop，使错误升级为终止错误并抛出，
    # 禁止被调用方静默吞为 WARNING 后继续启动 step4（对齐「只读技术强制不可被环境错误禁用」）。
    $ErrorActionPreference = 'Stop'
    # P1+P4：排除集扩充 .harness（消除跨任务/跨项目嵌套爆炸根因）；匹配规则见下方「任一级段命中」。
    $exclude = @(".git",".hg",".svn","node_modules",".venv","__pycache__",".pytest_cache",
                 ".idea",".vs","dist","build","target",".next",".harness")
    $ctx = Get-Step4PathContext -WorkspaceDir $WorkspaceDir -OutDir $OutDir
    $ws = $ctx.Workspace; $outRel = $ctx.OutRel
    $snapDir = Join-Path $OutDir "pre-step4-backup"
    New-Item -ItemType Directory -Path $snapDir -Force | Out-Null
    $files = @(Get-ChildItem -LiteralPath $WorkspaceDir -Recurse -File -Force)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($ws.Length).TrimStart('\')      # 与 $outRel 同源（规范反斜杠）
        if (-not $rel) { continue }
        # P4：路径任一级段命中排除集即跳过（覆盖嵌套 __pycache__、子模块 .git、.hg/.svn/dist/build 等）。
        $segs = $rel -split '\\'
        $skip = $false
        foreach ($s in $segs) { if ($exclude -contains $s) { $skip = $true; break } }
        if ($skip) { continue }
        if ($outRel -and ($rel -eq $outRel -or $rel.StartsWith($outRel + '\'))) { continue }
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        # P2：先 Copy-Item 成功，再把条目写入 manifest，消除「manifest 有条目而备份缺文件」窗口。
        $dst = Join-Path $snapDir $rel
        $d = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
        $lines.Add("$rel`t$hash`t$($f.Length)")
    }
    $lines | Out-File -LiteralPath (Join-Path $OutDir "pre-step4.sha256") -Encoding utf8
}
function Assert-Step4ReadOnly {
    param([string]$WorkspaceDir, [string]$OutDir, [string]$Step4Agent)
    # P1+P4：排除集（与 Save 同源，保证双文件一致）。
    $exclude = @(".git",".hg",".svn","node_modules",".venv","__pycache__",".pytest_cache",
                 ".idea",".vs","dist","build","target",".next",".harness")
    $ctx = Get-Step4PathContext -WorkspaceDir $WorkspaceDir -OutDir $OutDir
    $ws = $ctx.Workspace; $outRel = $ctx.OutRel
    $changed = New-Object System.Collections.Generic.List[string]
    $known = New-Object 'System.Collections.Generic.HashSet[System.String]'
    $manifest = @{}   # P2: rel -> before-hash，回退前校验备份完整性
    Get-Content -LiteralPath (Join-Path $OutDir "pre-step4.sha256") -Encoding utf8 | ForEach-Object {
        if (-not $_.Trim()) { return }
        $p = $_ -split "`t"; $rel = $p[0]; $before = $p[1]
        [void]$known.Add($rel)
        $manifest[$rel] = $before
        $cur = Join-Path $WorkspaceDir $rel
        $after = if (Test-Path -LiteralPath $cur) { (Get-FileHash -LiteralPath $cur -Algorithm SHA256).Hash } else { "<MISSING>" }
        if ($after -ne $before) { $changed.Add($rel) }
    }
    $files = @(Get-ChildItem -LiteralPath $WorkspaceDir -Recurse -File -Force)
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($ws.Length).TrimStart('\')
        if (-not $rel) { continue }
        # P4：路径任一级段命中排除集即跳过（与 Save 同源）。
        $segs = $rel -split '\\'
        $skip = $false
        foreach ($s in $segs) { if ($exclude -contains $s) { $skip = $true; break } }
        if ($skip) { continue }
        if ($outRel -and ($rel -eq $outRel -or $rel.StartsWith($outRel + '\'))) { continue }
        if (-not $known.Contains($rel)) { $changed.Add($rel) }
    }
    if ($changed.Count -gt 0) {
        foreach ($rel in $changed) {   # 自动回退
            $src = Join-Path (Join-Path $OutDir "pre-step4-backup") $rel
            $dst = Join-Path $WorkspaceDir $rel
            if (Test-Path -LiteralPath $src) {
                $beforeHash = $manifest[$rel]
                if ($beforeHash -and ((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash -eq $beforeHash)) {
                    Copy-Item -LiteralPath $src -Destination $dst -Force
                } else {
                    # P2：备份存在但与 manifest 不一致——备份不可信，保留工作区原文件并告警，不得覆盖/删除。
                    Write-Output "WARNING(step4 guard): 备份校验失败，保留工作区原文件未回退: $rel"
                }
            } elseif ($known.Contains($rel)) {
                # P2：受监控文件但备份缺失——不得删除工作区原文件（修复「无备份→删原文件」数据丢失）。
                Write-Output "WARNING(step4 guard): 备份缺失，保留工作区原文件未回退: $rel"
            } else {
                # step4 越权新建的文件：正确回退即删除（无「原文件」可保留）。
                Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
            }
        }
        # 记录违规（强制触发点）
        $reason = "step4 越权写文件（sha256 比对拦截并回退）：" + ($changed -join ", ")
        & (Join-Path (Split-Path -Parent $PSCommandPath) "manage_binding.ps1") -RecordViolation `
            -Id ("V-{0}-step4-write" -f (Get-Date -Format "yyyy-MM-dd")) -By $Step4Agent -Reason $reason
    }
    return @($changed)
}
