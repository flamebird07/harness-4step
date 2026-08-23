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
    $outRel = $null
    if (Test-Path -LiteralPath $OutDir) {
        $od = (Resolve-Path -LiteralPath $OutDir -ErrorAction SilentlyContinue).Path -replace '/', '\'
        # 严格包含（OutDir==Workspace 视为配置错误，不排除）
        if ($od.StartsWith($ws + '\')) { $outRel = $od.Substring($ws.Length).TrimStart('\') }
    }
    return [pscustomobject]@{ Workspace = $ws; OutRel = $outRel }
}
function Save-Step4Snapshot {
    param([string]$WorkspaceDir, [string]$OutDir)
    $exclude = @(".git","node_modules",".venv","__pycache__",".pytest_cache")
    $ctx = Get-Step4PathContext -WorkspaceDir $WorkspaceDir -OutDir $OutDir
    $ws = $ctx.Workspace; $outRel = $ctx.OutRel
    $snapDir = Join-Path $OutDir "pre-step4-backup"
    New-Item -ItemType Directory -Path $snapDir -Force | Out-Null
    $files = @(Get-ChildItem -LiteralPath $WorkspaceDir -Recurse -File -Force)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($ws.Length).TrimStart('\')      # 与 $outRel 同源（规范反斜杠）
        if (-not $rel) { continue }
        $first = ($rel -split '\\')[0]
        if ($exclude -contains $first) { continue }
        if ($outRel -and ($rel -eq $outRel -or $rel.StartsWith($outRel + '\'))) { continue }
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
    $exclude = @(".git","node_modules",".venv","__pycache__",".pytest_cache")
    $ctx = Get-Step4PathContext -WorkspaceDir $WorkspaceDir -OutDir $OutDir
    $ws = $ctx.Workspace; $outRel = $ctx.OutRel
    $changed = New-Object System.Collections.Generic.List[string]
    $known = New-Object 'System.Collections.Generic.HashSet[System.String]'
    Get-Content -LiteralPath (Join-Path $OutDir "pre-step4.sha256") -Encoding utf8 | ForEach-Object {
        if (-not $_.Trim()) { return }
        $p = $_ -split "`t"; $rel = $p[0]; $before = $p[1]
        [void]$known.Add($rel)
        $cur = Join-Path $WorkspaceDir $rel
        $after = if (Test-Path -LiteralPath $cur) { (Get-FileHash -LiteralPath $cur -Algorithm SHA256).Hash } else { "<MISSING>" }
        if ($after -ne $before) { $changed.Add($rel) }
    }
    $files = @(Get-ChildItem -LiteralPath $WorkspaceDir -Recurse -File -Force)
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($ws.Length).TrimStart('\')
        if (-not $rel) { continue }
        $first = ($rel -split '\\')[0]
        if ($exclude -contains $first) { continue }
        if ($outRel -and ($rel -eq $outRel -or $rel.StartsWith($outRel + '\'))) { continue }
        if (-not $known.Contains($rel)) { $changed.Add($rel) }
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
