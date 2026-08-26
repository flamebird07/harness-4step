param(
    [Parameter(Mandatory=$true)][string[]]$Files
)
$ErrorActionPreference = "Continue"
$failed = $false
foreach ($file in $Files) {
    $path = [System.IO.Path]::GetFullPath($file)
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Output "BOM_MISSING=$path"
        $failed = $true
        continue
    }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Write-Output "BOM_OK=$path"
    } else {
        Write-Output "BOM_MISSING=$path"
        $failed = $true
    }
}
if ($failed) { exit 1 }
exit 0
