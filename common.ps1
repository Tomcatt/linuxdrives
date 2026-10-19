# common.ps1 - shared helpers, dot-sourced by linuxdrives.ps1 and make-test-arrays.ps1
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'   # wsl.exe prints UTF-16 otherwise, which garbles the log

$Root = $PSScriptRoot
$ConfigPath = Join-Path $Root 'linuxdrives.json'
if (-not (Test-Path $ConfigPath)) {
    throw "linuxdrives.json not found - copy linuxdrives.example.json to linuxdrives.json and list your disks (see README.md)"
}
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$Distro = $Config.distro
$LogDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force $LogDir | Out-Null

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Relaunch the calling script elevated in its own window, passing the same arguments.
function Invoke-Elevated([string]$Script, [hashtable]$BoundParams) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Script`"")
    foreach ($k in $BoundParams.Keys) {
        $v = $BoundParams[$k]
        if ($v -is [switch]) { if ($v) { $a += "-$k" } } else { $a += "-$k", "`"$v`"" }
    }
    Start-Process (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $a
}

function ConvertTo-WslPath([string]$p) {
    $full = [IO.Path]::GetFullPath($p)
    '/mnt/' + $full.Substring(0, 1).ToLower() + ($full.Substring(2) -replace '\\', '/')
}

# Run a linuxdrives.sh (or other) subcommand as root inside the distro; throws on failure.
function Invoke-Wsl([string]$ScriptName, [string[]]$Arguments, [switch]$AllowFail) {
    $sh = ConvertTo-WslPath (Join-Path $Root $ScriptName)
    & wsl.exe -d $Distro -u root -- bash $sh @Arguments 2>&1 | ForEach-Object { "$_" } | Out-Host
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) { throw "$ScriptName $($Arguments -join ' ') failed (exit $LASTEXITCODE)" }
    $LASTEXITCODE
}

# Resolve a target from linuxdrives.json into wsl --mount arguments, with safety checks.
function Get-Members([string]$Target) {
    $t = $Config.targets.$Target
    if (-not $t) { throw "unknown target '$Target' (see linuxdrives.json)" }
    $members = @()
    foreach ($s in @($t.serials | Where-Object { $_ })) {
        $d = @(Get-Disk | Where-Object { "$($_.SerialNumber)".Trim() -eq $s })
        if ($d.Count -ne 1) { throw "disk with serial $s not found (found $($d.Count))" }
        $d = $d[0]
        if ($d.IsBoot -or $d.IsSystem -or $d.Number -eq 0) { throw "refusing disk $($d.Number): it is a Windows boot/system disk" }
        $members += [pscustomobject]@{ Name = "disk $($d.Number) ($s)"; Path = "\\.\PHYSICALDRIVE$($d.Number)"; Vhd = $false; Disk = $d.Number }
    }
    foreach ($v in @($t.vhds | Where-Object { $_ })) {
        $p = Join-Path $Root $v
        if (-not (Test-Path $p)) { throw "$p not found - run make-test-arrays.ps1 first" }
        $members += [pscustomobject]@{ Name = $v; Path = (Resolve-Path $p).Path; Vhd = $true }
    }
    $members
}

# Windows services that hold Linux partitions (Paragon LinuxFS) and would block wsl --mount.
# Returns the ones that were running, so Restore-Holders can start them again.
function Stop-Holders {
    $stopped = @()
    foreach ($n in @($Config.stopServices | Where-Object { $_ })) {
        $s = Get-Service $n -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') {
            Write-Host "pausing service $n"
            Stop-Service $n -Force
            $stopped += $n
        }
    }
    $stopped
}

function Restore-Holders([string[]]$Services) {
    foreach ($n in $Services) {
        $s = Get-Service $n -ErrorAction SilentlyContinue
        if (-not $s -or $s.StartType -eq 'Disabled') { continue }   # uninstalled or disabled
        Write-Host "restarting service $n"
        Start-Service $n -ErrorAction Continue
    }
}

# Offline = Windows dismounts its volumes (D:/E:/F:) and stops using the disk; writes nothing.
function Set-MemberOffline($m, [bool]$Offline) {
    if ($m.Vhd) { return }
    $d = Get-Disk -Number $m.Disk
    if ($d.IsOffline -ne $Offline) { Set-Disk -Number $m.Disk -IsOffline $Offline }
}

function Mount-Member($m) {
    $a = @('--mount', $m.Path, '--bare')
    if ($m.Vhd) { $a = @('--mount', $m.Path, '--vhd', '--bare') }
    & wsl.exe @a 2>&1 | ForEach-Object { "$_" } | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "wsl --mount failed for $($m.Name)" }
}

function Dismount-Member($m) {
    & wsl.exe --unmount $m.Path 2>&1 | ForEach-Object { "$_" } | Out-Host
}

# WSL stops the distro (and drops our mounts) when nothing is running in it.
function Start-KeepAlive {
    # the odd duration is how `linuxdrives.sh unmount` recognises and ends it
    $p = Start-Process wsl.exe -ArgumentList "-d $Distro -u root -- sleep 2147483647" -WindowStyle Hidden -PassThru
    $p.Id | Set-Content (Join-Path $LogDir 'keepalive.pid')
    $p
}

function Stop-KeepAlive {
    $f = Join-Path $LogDir 'keepalive.pid'
    if (Test-Path $f) {
        Stop-Process -Id (Get-Content $f) -ErrorAction SilentlyContinue
        Remove-Item $f
    }
}
