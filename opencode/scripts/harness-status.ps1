# harness-status.ps1 -TaskDir <路径>    # [P-05][F-05] 只读：汇总 .harness/<task>/ 下各步进度（供重连/编排一键恢复 todo 面板）
param([string]$TaskDir)
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ts = Join-Path $TaskDir "task-state.json"
if (Test-Path -LiteralPath $ts) {
    $s = Get-Content -LiteralPath $ts -Encoding UTF8 -Raw | ConvertFrom-Json
    foreach ($p in $s.PSObject.Properties) {
        $v = $p.Value
        # [F-05/F-06] 字段对齐：F-06 的 Write-TaskState 写 current_binding（无独立 agent 字段），此处回退兜底
        $agent = if ($null -ne $v.agent) { $v.agent } else { $v.current_binding }
        Write-Output ("{0}: status={1} exit={2} agent={3} out={4} at={5}" -f $p.Name, $v.status, $v.exit_code, $agent, $v.out_dir, $v.timestamp)
    }
} else {
    Write-Output "NO_TASK_STATE=$ts（尚无步骤完成；先跑任一步生成，见 F-06）"
}
