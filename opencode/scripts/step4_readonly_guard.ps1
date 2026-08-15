# step4_readonly_guard.ps1 — P-08 Step 4 只读技术强制（Layer B）
# 导出：
#   Save-Step4Snapshot -WorkspaceDir <dir> -OutDir <dir>
#   Assert-Step4ReadOnly -WorkspaceDir <dir> -OutDir <dir> -Step4Agent <agent> -ViolationsLog
<#
.SYNOPSIS
Step 4 只读技术强制（P-08）：step4 运行前对受监控文件做 sha256 快照 + 内容备份，
运行后比对，越权写文件即自动回退 + 记录违规 + 返回差异列表。
#>
function Save-Step4Snapshot {
    param([string]$WorkspaceDir, [string]$OutDir)
    $exclude = @(".git","node_modules",".venv","__pycache__",".pytest_cache")
    $outRel = $OutDir.Substring($WorkspaceDir.Length).TrimStart('\')
    $snapDir = Join-Path $OutDir "pre-step4-backup"
    New-Item -ItemType Directory -Path $snapDir -Force | Out-Null
    # P-08 修复（自迭代发现）：先把文件列表物化到数组，再逐一处理，避免在管道中
    # 边枚举边把备份写入 OutDir（位于 WorkspaceDir 内）导致 Get-ChildItem -Recurse
    # 无限重枚举而挂死。备份目录也一并排除，双保险。
    $outRel = $OutDir.Substring($WorkspaceDir.Length).TrimStart('\')
    $files = @(Get-ChildItem -LiteralPath $WorkspaceDir -Recurse -File -Force)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($WorkspaceDir.Length).TrimStart('\')
        if (-not $rel) { continue }
        $first = ($rel -split '\\')[0]
        if ($exclude -contains $first) { continue }
        if ($rel -eq $outRel -or $rel.StartsWith($outRel + '\')) { continue }  # 排除 OutDir 自身及其所有产物
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        $lines.Add("$rel`t$hash`t$($f.Length)")
        $dst = Join-Path $snapDir $rel
        $d = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
    }
    $lines | Out-File -LiteralPath (Join-Path $OutDir "pre-step4.sha256") -Encoding utf8
}
function Assert-Step4ReadOnly {
    param([string]$WorkspaceDir, [string]$OutDir, [string]$Step4Agent)
    # 与 Save-Step4Snapshot 完全一致的排除规则
    $exclude = @(".git","node_modules",".venv","__pycache__",".pytest_cache")
    $outRel = $OutDir.Substring($WorkspaceDir.Length).TrimStart('\')
    $changed = New-Object System.Collections.Generic.List[string]
    # 载入快照：同时建立"快照内已知相对路径"集合，并比对快照内文件
    $known = New-Object 'System.Collections.Generic.HashSet[System.String]'
    Get-Content -LiteralPath (Join-Path $OutDir "pre-step4.sha256") -Encoding utf8 | ForEach-Object {
        if (-not $_.Trim()) { return }
        $p = $_ -split "`t"; $rel = $p[0]; $before = $p[1]
        [void]$known.Add($rel)
        $cur = Join-Path $WorkspaceDir $rel
        $after = if (Test-Path -LiteralPath $cur) { (Get-FileHash -LiteralPath $cur -Algorithm SHA256).Hash } else { "<MISSING>" }
        if ($after -ne $before) { $changed.Add($rel) }
    }
    # P-09 修复（双向比对）：后置枚举当前全部受监控文件，找出快照之外的新建文件（含新建目录内文件）
    $files = @(Get-ChildItem -LiteralPath $WorkspaceDir -Recurse -File -Force)
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($WorkspaceDir.Length).TrimStart('\')
        if (-not $rel) { continue }
        $first = ($rel -split '\\')[0]
        if ($exclude -contains $first) { continue }
        if ($rel -eq $outRel -or $rel.StartsWith($outRel + '\')) { continue }  # 排除 OutDir 自身及其所有产物
        if (-not $known.Contains($rel)) { $changed.Add($rel) }   # 新建文件：计入违规/回退列表
    }
    if ($changed.Count -gt 0) {
        foreach ($rel in $changed) {   # 自动回退
            $src = Join-Path (Join-Path $OutDir "pre-step4-backup") $rel
            $dst = Join-Path $WorkspaceDir $rel
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dst -Force }
            else { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
        }
        # 记录违规（强制触发点）
        $reason = "step4 越权写文件（sha256 比对拦截并回退）：" + ($changed -join ", ")
        & (Join-Path (Split-Path -Parent $PSCommandPath) "manage_binding.ps1") -RecordViolation `
            -Id ("V-{0}-step4-write" -f (Get-Date -Format "yyyy-MM-dd")) -By $Step4Agent -Reason $reason
    }
    return @($changed)
}
