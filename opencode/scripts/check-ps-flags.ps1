<#
.SYNOPSIS
[F-07] powershell.exe 调用点 flag 门：断言 opencode/scripts/*.ps1 与 opencode/agents/*.md 内每条
powershell.exe 子进程调用（-File / -Command 两种形式）均带 -NoLogo -NonInteractive，缺失即 fail-closed。

背景：PS 5.1 在非交互管道下缺这两 flag 会间歇挂死（Popen 立即返回 PID 但 stdout/stderr 永不输出，
exit 0 也不退出，须 kill）——见 opencode/SKILL.md v13.0.41 与 Pitfall 5/7。

判定规则：
  - 范围仅 opencode/scripts/*.ps1 与 opencode/agents/*.md（dsh/shared/其它平台本轮不查）；
  - 只识别子进程调用形式：行内须含 `-File` 或 `-Command`，两者皆无则不是调用点，跳过；
  - .ps1 的块注释与行注释不在执行路径，跳过（避免把规则说明/用法示例文字误判为调用点）；
  - 每条命中行必须同时含 `-NoLogo` 与 `-NonInteractive`，缺任一即 fail-closed 退出 1。

用法：
    powershell.exe -NoProfile -NonInteractive -NoLogo -File opencode/scripts/check-ps-flags.ps1 [-RepoRoot <根>]
#>
param(
    [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$failed = $false
$checked = 0
$scopes = @(
    (Join-Path $RepoRoot "opencode\scripts"),
    (Join-Path $RepoRoot "opencode\agents")
)
foreach ($dir in $scopes) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @(".ps1", ".md") } |
        ForEach-Object {
            $file = $_
            $lines = Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
            $isPs = ($file.Extension -eq ".ps1")
            $inBlock = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($isPs) {
                    # [F-07] 跳过 <# ... #> 块注释与 # 行注释（不在执行路径，避免把用法示例文字误判为调用点）
                    if ($inBlock) { if ($line -match '#>') { $inBlock = $false }; continue }
                    if ($line -match '<#') {
                        $code = ($line -split '<#', 2)[0]
                        if ($line -match '#>') { $code += ($line -split '#>', 2)[1] } else { $inBlock = $true }
                    } else {
                        $code = ($line -split '#', 2)[0]
                    }
                } else {
                    $code = $line
                }
                if ($code -notmatch 'powershell\.exe') { continue }
                if ($code -notmatch '(-File|-Command)') { continue }   # 仅子进程调用（-File/-Command）两种形式
                $checked++
                if ($code -notmatch '-NoLogo' -or $code -notmatch '-NonInteractive') {
                    Write-Output ("PS_FLAGS_MISSING={0}:{1} :: {2}" -f $file.FullName, ($i + 1), $line.Trim())
                    $failed = $true
                }
            }
        }
}
if ($failed) { Write-Output "PS_FLAGS_FAIL checked=$checked"; exit 1 }
Write-Output "PS_FLAGS_OK_ALL checked=$checked"
exit 0

