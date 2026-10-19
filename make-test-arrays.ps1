<#
.SYNOPSIS
    Build the two RAID10 test arrays (md+XFS, Btrfs) on 1 GiB VHDX files, then run
    linuxdrives.ps1 -Verify against both. Touches nothing but test\*.vhdx.
#>
param([switch]$Rebuild)
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not (Test-Admin)) {
    Invoke-Elevated $PSCommandPath $PSBoundParameters
    exit
}

$log = Join-Path $LogDir ("test-{0:yyyy-MM-dd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $log | Out-Null
$results = @{}

try {
    $testDir = Join-Path $Root 'test'
    foreach ($kind in 'md', 'btrfs') {
        $target = "test-$kind"
        $vhds = @($Config.targets.$target.vhds | ForEach-Object { Join-Path $Root $_ })
        if ($Rebuild -or ($vhds | Where-Object { -not (Test-Path $_) })) {
            Write-Host "`n=== building $target ===" -ForegroundColor Cyan
            $vhds | Where-Object { Test-Path $_ } | Remove-Item
            $dp = Join-Path $env:TEMP 'linuxdrives-diskpart.txt'
            $vhds | ForEach-Object { "create vdisk file=`"$_`" maximum=1024 type=expandable" } | Set-Content $dp -Encoding ascii
            diskpart /s $dp | Out-Host
            Remove-Item $dp

            $members = @(Get-Members $target)
            Invoke-Wsl linuxdrives.sh prepare | Out-Null
            try {
                $members | ForEach-Object { Mount-Member $_ }
                Invoke-Wsl test/make-test.sh $kind | Out-Null
            }
            finally {
                Invoke-Wsl linuxdrives.sh unmount -AllowFail | Out-Null
                $members | ForEach-Object { Dismount-Member $_ }
            }
        }

        Write-Host "`n=== verifying $target (read-only) ===" -ForegroundColor Cyan
        & (Join-Path $Root 'linuxdrives.ps1') -Target $target -Verify -NoPause
        $results[$target] = (Select-String -Path (Get-ChildItem $LogDir "linuxdrives-*-$target.log" | Sort-Object LastWriteTime | Select-Object -Last 1).FullName -Pattern "RESULT $target`: PASS" -Quiet)
    }
}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
}
finally {
    Write-Host "`n=== summary ===" -ForegroundColor Cyan
    foreach ($k in 'test-md', 'test-btrfs') {
        $r = if ($results[$k]) { 'PASS' } else { 'FAIL' }
        Write-Host "  $k : $r" -ForegroundColor $(if ($results[$k]) { 'Green' } else { 'Red' })
    }
    Stop-Transcript | Out-Null
    Read-Host 'Press Enter to close' | Out-Null
}
