<#
.SYNOPSIS
    Mount Linux disks (md RAID, Btrfs RAID, XFS, ext4, ...) READ-ONLY through WSL.
.DESCRIPTION
    Attaches the disks of a target from linuxdrives.json to WSL with `wsl --mount --bare`,
    locks them read-only at the block layer, assembles/mounts read-only, and opens Explorer
    at \\wsl.localhost\<distro>\mnt\wsl\linuxdrives. Press Enter in the window to unmount.
.EXAMPLE
    .\linuxdrives.ps1                     # first target in linuxdrives.json
    .\linuxdrives.ps1 -Target test-md     # test array
    .\linuxdrives.ps1 -Unmount            # clean up after a closed window / crash
    .\linuxdrives.ps1 -Boot               # try mode: boot the install in a VM, changes kept in an overlay
    .\linuxdrives.ps1 -Boot -Fresh        # same, but throw the last try-mode session away first
#>
param(
    [string]$Target,   # default: the first target in linuxdrives.json
    [switch]$Unmount,
    # try mode: boot the disks in a QEMU VM inside WSL; guest writes go to an overlay kept
    # between sessions (dropped automatically once the disks change, e.g. after a native boot)
    [switch]$Boot,
    [switch]$Fresh,
    # test runs: hash every member before/after, check MANIFEST.sha256, prove writes fail
    [switch]$Verify,
    [switch]$NoPause
)
. (Join-Path $PSScriptRoot 'common.ps1')
if (-not $Target) { $Target = @($Config.targets.PSObject.Properties.Name)[0] }

if (-not (Test-Admin)) {
    Invoke-Elevated $PSCommandPath $PSBoundParameters
    exit
}

# Another session (or one that crashed) still has disks attached. Starting anyway would
# fail to attach and then this run's cleanup would tear the other session down.
if (-not $Unmount) {
    & wsl.exe -d $Distro -u root -e test -e /run/linuxdrives/new
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'Another linuxdrives session is still active (or crashed without cleaning up).' -ForegroundColor Yellow
        Write-Host 'Close it first, or run: linuxdrives.ps1 -Unmount'
        if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
        exit 1
    }
}

$log = Join-Path $LogDir ("linuxdrives-{0:yyyy-MM-dd_HHmmss}-$Target.log" -f (Get-Date))
Start-Transcript -Path $log | Out-Null
$members = @(Get-Members $Target)
$attached = @()
$paused = @()
$ok = $false

try {
    if ($Unmount) {
        Invoke-Wsl linuxdrives.sh unmount -AllowFail | Out-Null
        $members | ForEach-Object { Dismount-Member $_ }
        $members | ForEach-Object { Set-MemberOffline $_ $false }
        Restore-Holders @($Config.stopServices | Where-Object { $_ })
        Stop-KeepAlive
        $ok = $true
        return
    }

    $what = if ($Boot) { 'TRY-MODE boot (disks untouched, changes kept in an overlay)' } else { 'READ-ONLY mount' }
    Write-Host "Target '$Target' - $what of:" -ForegroundColor Cyan
    $members | ForEach-Object { Write-Host "  $($_.Name)" }
    Start-KeepAlive | Out-Null
    Invoke-Wsl linuxdrives.sh prepare | Out-Null
    $paused = @(Stop-Holders)
    foreach ($m in $members) {
        $attached += $m
        Set-MemberOffline $m $true
        Mount-Member $m
    }
    Invoke-Wsl linuxdrives.sh protect, $members.Count | Out-Null

    if ($Verify) { Invoke-Wsl linuxdrives.sh hash, /run/linuxdrives/hash-before | Out-Null }

    if ($Boot) {
        if ($Verify) {
            $bootRc = Invoke-Wsl linuxdrives.sh boot, $Target, --selftest -AllowFail
            Invoke-Wsl linuxdrives.sh hash, /run/linuxdrives/hash-after | Out-Null
            $cmpRc = Invoke-Wsl linuxdrives.sh compare, /run/linuxdrives/hash-before, /run/linuxdrives/hash-after -AllowFail
            $ok = ($bootRc -eq 0) -and ($cmpRc -eq 0)
            Write-Host ("RESULT {0} boot selftest: {1}" -f $Target, $(if ($ok) { 'PASS' } else { 'FAIL' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
            return
        }
        Write-Host 'Starting the VM - close its window (or shut the guest down) to finish.' -ForegroundColor Green
        $bootArgs = @('boot', $Target) + $(if ($Fresh) { '--fresh' } else { @() })
        $ok = (Invoke-Wsl linuxdrives.sh $bootArgs -AllowFail) -eq 0
        return
    }

    $mountRc = Invoke-Wsl linuxdrives.sh mount -AllowFail
    $share = "\\wsl.localhost\$Distro\mnt\wsl\linuxdrives"

    if ($Verify) {
        $verifyRc = Invoke-Wsl linuxdrives.sh verify -AllowFail
        # after assembling, mounting and reading, every member must be byte-identical
        Invoke-Wsl linuxdrives.sh release | Out-Null
        Invoke-Wsl linuxdrives.sh hash, /run/linuxdrives/hash-after | Out-Null
        $cmpRc = Invoke-Wsl linuxdrives.sh compare, /run/linuxdrives/hash-before, /run/linuxdrives/hash-after -AllowFail
        $ok = ($mountRc -eq 0) -and ($verifyRc -eq 0) -and ($cmpRc -eq 0)
        Write-Host ("RESULT {0}: {1}" -f $Target, $(if ($ok) { 'PASS' } else { 'FAIL' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
        return
    }

    if ($mountRc -ne 0) { Write-Host "Some filesystems failed to mount - see above." -ForegroundColor Yellow }
    Start-Process explorer.exe $share
    Write-Host "`nMounted read-only at $share" -ForegroundColor Green
    Write-Host 'Leave this window open while you use the drives.'
    Read-Host 'Press Enter to unmount' | Out-Null
    $ok = $true
}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
}
finally {
    if (-not $Unmount) {
        Invoke-Wsl linuxdrives.sh unmount -AllowFail | Out-Null
        $attached | ForEach-Object { Dismount-Member $_ }
        $attached | ForEach-Object { Set-MemberOffline $_ $false }
        Restore-Holders $paused
        Stop-KeepAlive
        Write-Host 'Unmounted. Disks are back with Windows.'
    }
    Stop-Transcript | Out-Null
    if (-not $NoPause -and -not $ok) { Read-Host 'Something went wrong - press Enter to close' | Out-Null }
}
if (-not $ok) { exit 1 }
