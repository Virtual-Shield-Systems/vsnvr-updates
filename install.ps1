<#
.SYNOPSIS
    VS NVR installer for Windows 11: the Linux appliance in a WSL2 distro.

.DESCRIPTION
    Prepares Windows, then runs the same install.sh a Linux box uses inside a dedicated
    WSL2 distro named vs-nvr, so VS NVR behaves as it does on Linux.

    What it changes on Windows; -Uninstall removes VS NVR's own pieces and puts back the
    settings, whose prior values %ProgramData%\VS-NVR\state.json records:
      - %USERPROFILE%\.wslconfig: [wsl2] networkingMode=mirrored and [experimental]
        hostAddressLoopback=true (both apply to every distro)
      - three inbound WSL firewall rules (VS-NVR-*), which apply to every WSL distro
      - the scheduled task "VS-NVR", which keeps the distro running from boot
      - a Start menu shortcut and an entry in Settings > Apps, which can uninstall it
      - optionally, sleep while plugged in turned off
    Storage: a fixed-size virtual disk <drive>:\VS-NVR\vs-nvr.vhdx holds the whole distro,
    so its space is reserved up front and Windows filling the drive cannot starve it.

.EXAMPLE
    # In an admin PowerShell:
    irm https://vsnvr.com/install.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://vsnvr.com/install.ps1))) -Drive D -SizeGB 500

.EXAMPLE
    & ([scriptblock]::Create((irm https://vsnvr.com/install.ps1))) -Uninstall
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Best-effort probes keep their fallback value.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Script-private helpers, not cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Read by the functions below.')]
param(
    [string]$Drive = "",
    [ValidateRange(0, 1048576)]
    [int]$SizeGB = 0,
    [ValidateSet('', 'Yes', 'No')]
    [string]$DisableSleep = "",
    [string]$InstallScript = "https://vsnvr.com/install.sh",
    [switch]$Yes,
    [switch]$Uninstall,
    [ValidateSet('', 'Keep', 'Delete')]
    [string]$Footage = ""
)

$ErrorActionPreference = "Stop"

$Distro = 'vs-nvr'
$TaskName = 'VS-NVR'
$StateDir = Join-Path $env:ProgramData 'VS-NVR'
$StatePath = Join-Path $StateDir 'state.json'
$WslCreator = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$RuleNames = @('VS-NVR-HTTP-In', 'VS-NVR-WebRTC-In', 'VS-NVR-Discovery-In')
$WslConfig = Join-Path $env:USERPROFILE '.wslconfig'
$ShortcutPath = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\VS NVR.lnk'
$AppKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VS-NVR'
$IconPath = Join-Path $StateDir 'vs-nvr.ico'
$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
# Mirrored networking puts the distro on the LAN with the PC's address and MAC; host
# loopback lets Windows itself reach it at that address, which the media plane
# advertises to browsers.
$WslSettings = @(
    @{ Section = 'wsl2'; Key = 'networkingMode'; Value = 'mirrored' },
    @{ Section = 'experimental'; Key = 'hostAddressLoopback'; Value = 'true' }
)
# Room inside the disk for Debian, Docker's images and the database; the rest is footage.
$SystemGB = 20
$MinSizeGB = 64

function Write-Step($m) { Write-Host "`n== $m ==" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[ok] $m" -ForegroundColor Green }
function Write-Note($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
# throw, not exit: under `irm ... | iex` the script runs in the user's own session,
# where `exit` would close their shell.
function Fail($m)       { throw $m }
function ConvertTo-EncodedCommand([string]$command) { return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command)) }

function Write-Banner([string]$line) {
    Write-Host ""
    Write-Host "  VS NVR for Windows" -ForegroundColor White
    Write-Host ("  " + ([string][char]0x2500 * 46)) -ForegroundColor Cyan
    Write-Host "  $line" -ForegroundColor Gray
    Write-Host ""
}

# Slow steps show one live status line. The programs under it write to $LogPath, and
# the last lines of one that fails are printed if the step then fails.
$LogPath = Join-Path $env:TEMP 'vs-nvr-install.log'
$AnsiCode = "$([char]27)\[[0-9;?]*[A-Za-z]"
$script:Status = $null
$script:FailTail = @()

function Get-LineWidth { try { return [math]::Max(1, [Console]::WindowWidth - 1) } catch { return 100 } }
function Format-Elapsed($clock) { return '{0}:{1:00}' -f [int][math]::Floor($clock.Elapsed.TotalMinutes), $clock.Elapsed.Seconds }

function Show-Status {
    $s = $script:Status
    $width = 20
    if ($s.Percent -ge 0) {
        $filled = [int][math]::Floor($width * [math]::Min(100.0, $s.Percent) / 100)
        $bar = ([string][char]0x2588 * $filled) + ([string][char]0x2591 * ($width - $filled))
        $pct = '{0,3}%' -f [int]$s.Percent
    } else {
        $span = $width - 4
        $pos = $s.Frame % (2 * $span)
        if ($pos -gt $span) { $pos = 2 * $span - $pos }
        $bar = ([string][char]0x2591 * $pos) + ([string][char]0x2588 * 4) + ([string][char]0x2591 * ($span - $pos))
        $pct = '    '
    }
    $s.Frame++
    $text = " $pct  $(Format-Elapsed $s.Clock)  $($s.Label)"
    if ($s.Detail) { $text += ": $($s.Detail)" }
    $max = [math]::Max(0, (Get-LineWidth) - $width)
    if ($text.Length -gt $max) { $text = $text.Substring(0, $max) }
    Write-Host ("`r" + $bar.Substring(0, [math]::Min($width, (Get-LineWidth)))) -NoNewline -ForegroundColor Cyan
    Write-Host $text.PadRight($max) -NoNewline
}
function Start-Status([string]$label) {
    $script:Status = @{ Label = $label; Detail = ''; Percent = -1; Frame = 0; Clock = [Diagnostics.Stopwatch]::StartNew() }
    $script:FailTail = @()
    try { [Console]::CursorVisible = $false } catch { }
    Show-Status
}
# Clears the status line and returns how long the step took.
function Stop-Status {
    if (-not $script:Status) { return '' }
    Write-Host ("`r" + ''.PadRight((Get-LineWidth)) + "`r") -NoNewline
    try { [Console]::CursorVisible = $true } catch { }
    $elapsed = Format-Elapsed $script:Status.Clock
    $script:Status = $null
    return $elapsed
}
function Complete-Status([string]$done) { $t = Stop-Status; Write-Ok "$done ($t)" }

# Clicking a classic console window starts a text selection (QuickEdit), and while it
# lasts every write to the console blocks, pausing the whole install behind the
# status line. Returns the mode to restore, or $null when there is no console.
function Disable-QuickEdit {
    try {
        # A type lasts for the session; a re-run in the same console reuses it.
        if (-not ('VsNvr.ConsoleMode' -as [type])) { Add-Type -Namespace VsNvr -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int handle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr handle, out uint mode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr handle, uint mode);
'@ }
        $in = [VsNvr.ConsoleMode]::GetStdHandle(-10)
        $mode = [uint32]0
        if (-not [VsNvr.ConsoleMode]::GetConsoleMode($in, [ref]$mode)) { return $null }
        # Clear ENABLE_QUICK_EDIT_MODE (0x40); ENABLE_EXTENDED_FLAGS (0x80) makes it stick.
        [void][VsNvr.ConsoleMode]::SetConsoleMode($in, [uint32](($mode -band 4294967231) -bor 0x80))
        return $mode
    } catch { return $null }
}
function Restore-ConsoleMode($mode) {
    if ($null -ne $mode) { [void][VsNvr.ConsoleMode]::SetConsoleMode([VsNvr.ConsoleMode]::GetStdHandle(-10), [uint32]$mode) }
}

# Runs a program with its output captured: logged, kept for a failure report if it
# fails, and handed line by line to $OnLine, which can update the status line, as
# can $OnTick, called about once a second.
function Invoke-Process([string]$Exe, [string]$Arguments, [byte[]]$Stdin = $null, [scriptblock]$OnLine = $null, [scriptblock]$OnTick = $null) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo $Exe
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = [bool]$Stdin
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    # wsl.exe prints UTF-16 unless told otherwise.
    $psi.EnvironmentVariables['WSL_UTF8'] = '1'
    # The stdin writer takes the console's input encoding and, for UTF-8, opens with a
    # BOM that breaks a script's first line.
    $consoleEncoding = [Console]::InputEncoding
    [Console]::InputEncoding = $utf8
    try { $p = [System.Diagnostics.Process]::Start($psi) } finally { [Console]::InputEncoding = $consoleEncoding }
    # Written while the output is drained: bash runs a script as it reads it, so a
    # blocking write could wait on a command that waits on a full output pipe.
    $writing = if ($Stdin) { $p.StandardInput.BaseStream.WriteAsync($Stdin, 0, $Stdin.Length) } else { $null }
    $tail = New-Object System.Collections.Generic.Queue[string]
    $readers = @($p.StandardOutput, $p.StandardError)
    $pending = @($readers[0].ReadLineAsync(), $readers[1].ReadLineAsync())
    $log = [System.IO.File]::AppendText($LogPath)
    $clock = [Diagnostics.Stopwatch]::StartNew(); $lastTick = 0; $lastDraw = 0
    try {
        while ($pending[0] -or $pending[1]) {
            $busy = $false
            if ($writing -and $writing.IsCompleted) { try { $p.StandardInput.Close() } catch { }; $writing = $null }
            for ($i = 0; $i -lt 2; $i++) {
                while ($pending[$i] -and $pending[$i].IsCompleted) {
                    $line = $pending[$i].Result
                    if ($null -eq $line) { $pending[$i] = $null; break }
                    $busy = $true
                    $line = $line -replace $AnsiCode, ''
                    $log.WriteLine($line)
                    if ($line.Trim()) {
                        $tail.Enqueue($line)
                        if ($tail.Count -gt 15) { [void]$tail.Dequeue() }
                        if ($OnLine) { & $OnLine $line | Out-Null }
                    }
                    $pending[$i] = $readers[$i].ReadLineAsync()
                }
            }
            $ms = $clock.ElapsedMilliseconds
            if ($OnTick -and $ms - $lastTick -ge 1000) { $lastTick = $ms; & $OnTick | Out-Null }
            if ($script:Status -and $ms - $lastDraw -ge 100) { $lastDraw = $ms; Show-Status }
            if (-not $busy) { Start-Sleep -Milliseconds 50 }
        }
        $p.WaitForExit()
    } finally {
        $log.Close()
        if (-not $p.HasExited) { $p.Kill() }
    }
    if ($p.ExitCode -ne 0) { $script:FailTail = @($tail) }
    return $p.ExitCode
}
function Invoke-Wsl([string]$Arguments, [scriptblock]$OnLine = $null) { return Invoke-Process 'wsl.exe' $Arguments $null $OnLine }

function Read-Default([string]$prompt, [string]$default) {
    $a = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return $a.Trim()
}
function Confirm-Yes([string]$prompt, [bool]$default) {
    $a = Read-Host ($prompt + $(if ($default) { ' [Y/n]' } else { ' [y/N]' }))
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return ($a.Trim() -match '^(y|yes)$')
}

function Get-State {
    if (Test-Path $StatePath) { return (Get-Content $StatePath -Raw | ConvertFrom-Json) }
    return $null
}
function Save-State($s) {
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    [System.IO.File]::WriteAllText($StatePath, ($s | ConvertTo-Json -Depth 5))
}

# Windows PowerShell 5.1 turns a native command's redirected stderr into a terminating
# error under ErrorActionPreference Stop, so a probe that only wants the exit code runs
# here, under Continue.
function Invoke-Probe([scriptblock]$Command) {
    $ErrorActionPreference = 'Continue'
    & $Command
}

function Get-Distros {
    $prev = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    try { $names = @(Invoke-Probe { wsl.exe --list --quiet 2>$null }); $ok = ($LASTEXITCODE -eq 0) } finally { [Console]::OutputEncoding = $prev }
    # With no distros, wsl.exe prints a message and fails.
    if (-not $ok) { return @() }
    return @($names | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

# Runs a bash script as root in a distro. The script goes in on stdin byte for byte:
# PowerShell's own pipe would append CRLF, and wsl.exe mangles backslashes in arguments.
function Invoke-Linux([string]$Name, [string]$Script, [string[]]$ScriptArgs = @(), [scriptblock]$OnLine = $null, [scriptblock]$OnTick = $null) {
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes(($Script -replace "`r", '') + "`n")
    $quoted = @($ScriptArgs | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" })
    return Invoke-Process 'wsl.exe' ((@('-d', $Name, '-u', 'root', '--', 'bash', '-s', '--') + $quoted) -join ' ') $bytes $OnLine $OnTick
}

# This PC's time zone as an IANA name, converted by the ICU that ships with Windows.
function Get-HostTimeZone {
    try {
        if (-not ('VsNvr.Icu' -as [type])) { Add-Type -Namespace VsNvr -Name Icu -MemberDefinition @'
[DllImport("icu.dll", CharSet = CharSet.Unicode)]
public static extern int ucal_getTimeZoneIDForWindowsID(string winid, int len, [MarshalAs(UnmanagedType.LPStr)] string region, System.Text.StringBuilder id, int cap, ref int status);
'@ }
        $win = [System.TimeZoneInfo]::Local.Id
        $id = New-Object System.Text.StringBuilder 64
        $status = 0
        $n = [VsNvr.Icu]::ucal_getTimeZoneIDForWindowsID($win, $win.Length, $null, $id, $id.Capacity, [ref]$status)
        if ($status -le 0 -and $n -gt 0 -and $n -le $id.Capacity) { return $id.ToString(0, $n) }
    } catch { }
    return ""
}

function Get-AcStandbySeconds {
    $out = powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Out-String
    $m = [regex]::Match($out, 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)')
    if ($m.Success) { return [Convert]::ToInt32($m.Groups[1].Value, 16) }
    return -1
}
function Set-AcStandbySeconds([int]$seconds) {
    powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE $seconds
    powercfg /setactive SCHEME_CURRENT
}

# A key's value in a .wslconfig section, or $null when unset.
function Get-WslConfigValue([string]$section, [string]$key) {
    if (-not (Test-Path $WslConfig)) { return $null }
    $current = ''
    foreach ($line in [System.IO.File]::ReadAllLines($WslConfig)) {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') { $current = $Matches[1].Trim().ToLowerInvariant(); continue }
        if ($current -eq $section -and $t -match "^$key\s*=\s*(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}
# Sets a key in a .wslconfig section, or removes it when $value is $null; other lines are kept.
function Set-WslConfigValue([string]$section, [string]$key, $value) {
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path $WslConfig) { $lines.AddRange([string[]][System.IO.File]::ReadAllLines($WslConfig)) }
    $current = ''; $sectionAt = -1; $keyAt = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].Trim()
        if ($t -match '^\[(.+)\]$') { $current = $Matches[1].Trim().ToLowerInvariant(); if ($current -eq $section) { $sectionAt = $i }; continue }
        if ($current -eq $section -and $t -match "^$key\s*=") { $keyAt = $i }
    }
    if ($null -eq $value) {
        if ($keyAt -ge 0) { $lines.RemoveAt($keyAt) }
    } elseif ($keyAt -ge 0) {
        $lines[$keyAt] = "$key=$value"
    } elseif ($sectionAt -ge 0) {
        $lines.Insert($sectionAt + 1, "$key=$value")
    } else {
        $lines.Add("[$section]"); $lines.Add("$key=$value")
    }
    [System.IO.File]::WriteAllText($WslConfig, (($lines -join "`r`n") + "`r`n"))
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail "Run this from an admin PowerShell (right-click PowerShell, Run as administrator)."
    }
}

function Assert-Prerequisites {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    # The distro, .wslconfig and the startup task belong to one Windows account; an
    # admin elevating for someone else would set them up for the wrong user.
    $console = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($console -and $console -ne "$env:USERDOMAIN\$env:USERNAME") {
        Fail "This PowerShell runs as $env:USERDOMAIN\$env:USERNAME but $console is signed in. Run the installer as the signed-in user, from their own admin PowerShell."
    }
    $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
    if ($build -lt 22621) { Fail "VS NVR needs Windows 11 version 22H2 or newer (this is build $build). Update Windows, then re-run." }
    if (-not (Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue)) {
        Fail "This Windows has no WSL firewall support (New-NetFirewallHyperVRule). Update Windows, then re-run."
    }
    Invoke-Probe { wsl.exe --version *> $null }
    if ($LASTEXITCODE -ne 0) {
        Write-Step "Installing WSL"
        wsl.exe --install --no-distribution
        if ($LASTEXITCODE -ne 0) { Fail "Could not install WSL. Make sure virtualization is enabled in the PC's firmware settings, then re-run." }
        Write-Note "WSL is installed. Restart Windows, then run this installer again."
        return $false
    }
    $owner = $id.User.Value
    $state = Get-State
    if ($state -and $state.Owner -ne $owner) { Fail "VS NVR on this PC belongs to another Windows account ($($state.Owner))." }
    if (-not $state -and (Get-Distros) -contains $Distro) {
        Fail "A WSL distro named $Distro already exists and this installer did not create it. Remove or rename it, then re-run."
    }
    return $true
}

function Set-WslNetworking($state) {
    $changes = @($WslSettings | Where-Object { (Get-WslConfigValue $_.Section $_.Key) -ne $_.Value })
    if ($changes.Count -eq 0) { Write-Ok "WSL networking is already set up"; return }
    $others = @(Get-Distros | Where-Object { $_ -ne $Distro })
    if ($others.Count -gt 0) {
        Write-Note "This PC already uses WSL ($($others -join ', ')). VS NVR changes WSL's networking settings (mirrored networking, host loopback), which apply to every distro, and restarts WSL once, stopping them."
        if (-not $Yes -and -not (Confirm-Yes "Continue?" $false)) { Fail "Stopped; nothing was changed." }
    }
    if (-not $state.WslConfig) { $state | Add-Member -NotePropertyName WslConfig -NotePropertyValue ([pscustomobject]@{}) -Force }
    foreach ($c in $changes) {
        $record = $state.WslConfig.($c.Key)
        if (-not ($record -and $record.Set)) {
            $state.WslConfig | Add-Member -NotePropertyName $c.Key -NotePropertyValue ([pscustomobject]@{ Set = $true; Prior = (Get-WslConfigValue $c.Section $c.Key) }) -Force
        }
    }
    Save-State $state
    foreach ($c in $changes) { Set-WslConfigValue $c.Section $c.Key $c.Value }
    Start-Status "Restarting WSL"
    if ((Invoke-Wsl '--shutdown') -ne 0) { Fail "Could not restart WSL to apply its networking settings. Run wsl --shutdown, then re-run the installer." }
    Complete-Status "WSL networking set up"
}

# Free space less a margin for Windows: 10% of the drive, at least 20 GB.
function Get-MarginGB($vol) { return [math]::Max(20, [math]::Ceiling($vol.Size / 1GB * 0.1)) }
function Get-ReservableGB($vol) { return [math]::Floor($vol.SizeRemaining / 1GB) - (Get-MarginGB $vol) }

function Select-Storage {
    $vols = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystemType -eq 'NTFS' } | Sort-Object SizeRemaining -Descending)
    $fits = @($vols | Where-Object { (Get-ReservableGB $_) -ge $MinSizeGB } | ForEach-Object { [string]$_.DriveLetter })
    if ($fits.Count -eq 0) { Fail "No drive has room for VS NVR. It needs $MinSizeGB GB, plus 10% of the drive (at least 20 GB) left free for Windows. Free up space or add a drive, then re-run." }
    if (-not $Drive) {
        Write-Host "Drives:"
        foreach ($v in $vols) {
            $note = if ($fits -contains [string]$v.DriveLetter) { '' } else { '  (not enough space)' }
            Write-Host (("  {0}:  {1:N0} GB free of {2:N0} GB" -f $v.DriveLetter, ($v.SizeRemaining / 1GB), ($v.Size / 1GB)) + $note)
        }
    }
    while ($true) {
        $letter = if ($Drive) { $Drive } else { Read-Default "Which drive should hold VS NVR and its recordings?" $fits[0] }
        $letter = $letter.TrimEnd(':', '\').ToUpperInvariant()
        $vol = $vols | Where-Object { [string]$_.DriveLetter -eq $letter } | Select-Object -First 1
        if ($fits -contains $letter) { break }
        $problem = if ($vol) { "Drive ${letter}: doesn't have room. It has $([math]::Floor($vol.SizeRemaining / 1GB)) GB free, and VS NVR needs $MinSizeGB GB plus $(Get-MarginGB $vol) GB left free for Windows." } else { "Drive $letter is not a fixed NTFS drive on this PC." }
        if ($Drive) { Fail $problem }
        Write-Note $problem
    }
    $maxGB = Get-ReservableGB $vol
    $sizeProblem = "Pick a size between $MinSizeGB and $maxGB GB."
    $size = $SizeGB
    if ($size -ne 0) {
        if ($size -lt $MinSizeGB -or $size -gt $maxGB) { Fail $sizeProblem }
    } else {
        Write-Host "VS NVR reserves its space now, so Windows filling the drive later can't stop recording."
        while ($true) {
            $answer = Read-Default "How many GB should it reserve on ${letter}: (up to $maxGB)?" ([string]$maxGB)
            if ([int]::TryParse($answer, [ref]$size) -and $size -ge $MinSizeGB -and $size -le $maxGB) { break }
            Write-Note $sizeProblem
        }
    }
    return @{ Path = "$($letter.ToUpperInvariant()):\VS-NVR\vs-nvr.vhdx"; SizeGB = $size }
}

# Builds the distro on a fixed-size VHDX: a temporary Debian formats it and copies
# itself in, with the WSL settings, the recordings filesystem and its mount.
function New-NvrDistro($state) {
    # A disk this installer started and never finished holds no recordings (a kept
    # install stays registered as a distro and never reaches here). It goes before
    # the space check, which it would otherwise fail.
    if ($state.Vhdx -and -not $state.DistroCreated -and -not $state.FootageKept -and (Test-Path $state.Vhdx)) { Remove-Item $state.Vhdx -Force }
    $storage = Select-Storage
    $vhdx = $storage.Path
    $dir = Split-Path $vhdx
    New-Item -ItemType Directory -Force $dir | Out-Null
    if (Test-Path $vhdx) { Fail "$vhdx already exists. Move it away, then re-run." }
    $state | Add-Member -NotePropertyName Vhdx -NotePropertyValue $vhdx -Force
    Save-State $state

    # Windows writes out the whole reservation once: minutes per 100 GB on an SSD.
    $where = Split-Path -Qualifier $vhdx
    Start-Status "Reserving $($storage.SizeGB) GB on $where"
    $dp = Join-Path $env:TEMP 'vs-nvr-diskpart.txt'
    [System.IO.File]::WriteAllText($dp, "create vdisk file=`"$vhdx`" maximum=$($storage.SizeGB * 1024) type=fixed`r`n")
    $finished = $false
    try {
        $rc = Invoke-Process 'diskpart.exe' "/s `"$dp`"" $null { param($l) if ($l -match '(\d+) percent') { $script:Status.Percent = [int]$Matches[1] } }
        $finished = $true
    } finally {
        Remove-Item $dp -Force -ErrorAction SilentlyContinue
        # Interrupted (Ctrl+C): the Virtual Disk service keeps writing the file after
        # diskpart is gone, until the service stops.
        if (-not $finished) {
            [void](Stop-Status)
            Write-Note "Cancelling the reservation..."
            Stop-Service vds -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            Remove-Item $vhdx -Force -ErrorAction SilentlyContinue
        }
    }
    if ($rc -ne 0 -or -not (Test-Path $vhdx)) { Fail "Could not create $vhdx." }
    # WSL starts the distro as this user, who needs access to the disk file.
    icacls $dir /grant "$env:USERDOMAIN\${env:USERNAME}:(OI)(CI)F" /T | Out-Null
    Complete-Status "Reserved $($storage.SizeGB) GB on $where"

    Start-Status "Creating the $Distro distro"
    $setup = 'vs-nvr-setup'
    if ((Get-Distros) -contains $setup) { Invoke-Wsl "--unregister $setup" | Out-Null }
    $script:Status.Detail = 'downloading Debian'
    $rc = Invoke-Wsl "--install Debian --name $setup --no-launch" { param($l) if ($l -match '(\d+(\.\d+)?)%') { $script:Status.Percent = [double]$Matches[1] } }
    if ($rc -ne 0) { Fail "Could not download Debian for WSL." }
    $script:Status.Percent = -1
    $script:Status.Detail = 'setting up the disk'
    $tar = Join-Path $env:TEMP 'vs-nvr-rootfs.tar'
    try {
        if ((Invoke-Wsl "--export $setup `"$tar`"") -ne 0) { Fail "Could not export the Debian image." }
        if ((Invoke-Wsl "--mount --vhd `"$vhdx`" --bare") -ne 0) { Fail "Could not attach $vhdx to WSL." }
        $footageGB = $storage.SizeGB - $SystemGB
        $fill = @'
set -e
size=$1; tar=$(wslpath "$2"); footage=$3
dev=$(lsblk -dbno NAME,SIZE,FSTYPE | awk -v s="$size" '$2 >= s-4194304 && $2 <= s && $3 == "" {print $1}')
[ "$(printf '%s\n' "$dev" | grep -c .)" = 1 ] || { echo "could not find the new disk" >&2; exit 1; }
mkfs.ext4 -q -L vs-nvr "/dev/$dev"
r=$(mktemp -d)
mount "/dev/$dev" "$r"
tar -C "$r" -xpf "$tar" 2>/dev/null
cat > "$r/etc/wsl.conf" <<'EOF'
[boot]
systemd=true
[user]
default=root
# The recorder must never see the Windows drives.
[automount]
enabled=false
mountFsTab=true
[interop]
enabled=false
appendWindowsPath=false
EOF
# No Debian shell in the Start menu or Windows Terminal; VS NVR adds its own shortcut.
cat > "$r/etc/wsl-distribution.conf" <<'EOF'
[shortcut]
enabled=false
[windowsterminal]
enabled=false
EOF
# WSL leaves / private; Docker needs the recording parent to propagate (rshared).
cat > "$r/etc/systemd/system/vs-nvr-rshared.service" <<'EOF'
[Unit]
Description=Shared mount propagation for VS NVR recordings
DefaultDependencies=no
Before=local-fs-pre.target docker.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/mount --make-rshared /
[Install]
WantedBy=local-fs-pre.target
EOF
mkdir -p "$r/etc/systemd/system/local-fs-pre.target.wants" "$r/var/lib/vs-nvr" "$r/srv/vs-nvr/recordings"
ln -sf /etc/systemd/system/vs-nvr-rshared.service "$r/etc/systemd/system/local-fs-pre.target.wants/vs-nvr-rshared.service"
img="$r/var/lib/vs-nvr/recordings.img"
fallocate -l "${footage}G" "$img"
mkfs.ext4 -q -F -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 -L vs-nvr-rec "$img"
m=$(mktemp -d)
mount -o loop "$img" "$m"
chown 65531:65531 "$m"
umount "$m"
echo '/var/lib/vs-nvr/recordings.img /srv/vs-nvr/recordings ext4 loop,nofail,X-fstrim.notrim 0 2' >> "$r/etc/fstab"
umount "$r"
'@
        # Hand over the fixed VHDX's virtual size, not the file length (it carries a footer).
        $bytes = [string]([int64]$storage.SizeGB * 1GB)
        $rc = Invoke-Linux $setup $fill @($bytes, $tar.Replace('\', '/'), [string]$footageGB)
        Invoke-Wsl "--unmount `"$vhdx`"" | Out-Null
        if ($rc -ne 0) { Fail "Could not prepare the VS NVR disk." }
    } finally {
        Invoke-Wsl "--unregister $setup" | Out-Null
        Remove-Item $tar -Force -ErrorAction SilentlyContinue
    }
    if ((Invoke-Wsl "--import-in-place $Distro `"$vhdx`"") -ne 0) { Fail "Could not register the $Distro distro." }
    $state | Add-Member -NotePropertyName DistroCreated -NotePropertyValue $true -Force
    Save-State $state
    Complete-Status "Created the $Distro distro on $vhdx"
}

function Set-FirewallRules {
    $range = ((wsl.exe -d $Distro -u root -- cat /proc/sys/net/ipv4/ip_local_port_range) -join ' ').Trim() -split '\s+'
    if ($range.Count -ne 2) { Fail "Could not read the distro's port range." }
    foreach ($n in $RuleNames) { Remove-NetFirewallHyperVRule -Name $n -ErrorAction SilentlyContinue }
    $common = @{ VMCreatorId = $WslCreator; Direction = 'Inbound'; Action = 'Allow' }
    New-NetFirewallHyperVRule @common -Name 'VS-NVR-HTTP-In' -DisplayName 'VS NVR web app' -Protocol TCP -LocalPorts 8080 -RemoteAddresses LocalSubnet | Out-Null
    New-NetFirewallHyperVRule @common -Name 'VS-NVR-WebRTC-In' -DisplayName 'VS NVR remote playback' -Protocol UDP -LocalPorts 8556 | Out-Null
    # Camera discovery and router (UPnP) replies come back from arbitrary source ports
    # to the distro's ephemeral ports.
    New-NetFirewallHyperVRule @common -Name 'VS-NVR-Discovery-In' -DisplayName 'VS NVR camera discovery replies' -Protocol UDP -LocalPorts "$($range[0])-$($range[1])" -RemoteAddresses LocalSubnet | Out-Null
    Write-Ok "Firewall rules added"
}

function Set-SleepSetting($state) {
    $current = Get-AcStandbySeconds
    if ($current -eq 0) { Write-Ok "Sleep while plugged in is already off"; return }
    $off = if ($DisableSleep) { $DisableSleep -eq 'Yes' } else { Confirm-Yes "Turn off sleep while plugged in? VS NVR stops recording while the PC sleeps." $true }
    if (-not $off) { Write-Note "Sleep left on: recording stops whenever this PC sleeps."; return }
    $state | Add-Member -NotePropertyName Sleep -NotePropertyValue @{ Set = $true; Prior = $current } -Force
    Save-State $state
    Set-AcStandbySeconds 0
    Write-Ok "Sleep while plugged in turned off"
}

# WSL stops a distro soon after its last wsl.exe exits, so this task keeps one
# attached from boot, signed in or not. The loop starts the distro again when WSL
# stops it: Task Scheduler's own restart doesn't fire when the program just exits.
function Register-KeepaliveTask {
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $loop = "while (`$true) { & `"$env:SystemRoot\System32\wsl.exe`" -d $Distro -u root -- sleep infinity; Start-Sleep -Seconds 5 }"
    $action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $(ConvertTo-EncodedCommand $loop)"
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew -RestartCount 9999 -RestartInterval (New-TimeSpan -Minutes 1)
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Trigger (New-ScheduledTaskTrigger -AtStartup) -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Ok "Startup task $TaskName registered"
}

# The Start menu shortcut and the Settings > Apps entry, whose Uninstall runs -Uninstall
# from vsnvr.com in an elevated window that stays open to show the outcome.
function Register-App($state) {
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri 'https://vsnvr.com/favicon.ico' -OutFile $IconPath } catch { Remove-Item $IconPath -Force -ErrorAction SilentlyContinue }
    $icon = Test-Path $IconPath
    # Start hides .url shortcuts to web addresses, so this is a .lnk that hands the URL to the browser.
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = "$env:SystemRoot\explorer.exe"
    $shortcut.Arguments = 'http://localhost:8080/'
    if ($icon) { $shortcut.IconLocation = "$IconPath,0" }
    $shortcut.Save()

    $uninstall = "try { & ([scriptblock]::Create((irm https://vsnvr.com/install.ps1))) -Uninstall } catch { Write-Host `"[x] `$_`" -ForegroundColor Red } finally { Read-Host 'Press Enter to close' }"
    $elevate = "Start-Process '$PowerShellExe' -Verb RunAs -WindowStyle Normal -ArgumentList '-NoProfile -EncodedCommand $(ConvertTo-EncodedCommand $uninstall)'"
    New-Item $AppKey -Force | Out-Null
    $values = [ordered]@{
        DisplayName = 'VS NVR'
        Publisher = 'Virtual Shield Systems'
        URLInfoAbout = 'https://vsnvr.com/'
        InstallLocation = Split-Path $state.Vhdx
        UninstallString = "`"$PowerShellExe`" -NoProfile -WindowStyle Hidden -EncodedCommand $(ConvertTo-EncodedCommand $elevate)"
    }
    if ($icon) { $values.DisplayIcon = $IconPath }
    foreach ($k in $values.Keys) { New-ItemProperty $AppKey -Name $k -Value $values[$k] -PropertyType String | Out-Null }
    # Settings shows the reserved disk's size, from KB in a DWORD.
    New-ItemProperty $AppKey -Name EstimatedSize -Value ([int][math]::Min([double][int]::MaxValue, (Get-Item $state.Vhdx).Length / 1KB)) -PropertyType DWord | Out-Null
    foreach ($k in 'NoModify', 'NoRepair') { New-ItemProperty $AppKey -Name $k -Value 1 -PropertyType DWord | Out-Null }
    Write-Ok "Added to the Start menu and Settings > Apps"
}

# Download size of the images install.sh pulls, read from their registry manifests
# (the image names come from install.sh's own defaults); 0 when unknown.
function Get-ImageBytes([string]$installScript) {
    $refs = @([regex]::Matches($installScript, 'VS_NVR(?:_AIDETECT|_MEDIADC)?_IMAGE:-([^}"]+)\}') | ForEach-Object { $_.Groups[1].Value })
    $refs += @([regex]::Matches($installScript, 'COSIGN_IMAGE="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $total = [int64]0
    foreach ($ref in $refs) {
        $json = New-Object System.Text.StringBuilder
        $rc = Invoke-Linux $Distro 'docker manifest inspect -v "$1"' @($ref) { param($l) [void]$json.AppendLine($l) }
        if ($rc -ne 0) { return 0 }
        # Windows PowerShell hands back a JSON array as one object; piping a variable unrolls it.
        $entries = $json.ToString() | ConvertFrom-Json
        $entry = $entries | Where-Object { -not $_.Descriptor.platform -or ($_.Descriptor.platform.os -eq 'linux' -and $_.Descriptor.platform.architecture -eq $arch) } | Select-Object -First 1
        if (-not $entry) { continue }
        $manifest = if ($entry.OCIManifest) { $entry.OCIManifest } else { $entry.SchemaV2Manifest }
        $total += [int64]($manifest.layers | Measure-Object size -Sum).Sum
    }
    return $total
}

# Bytes in Docker's download store, which grows as image layers arrive. (The
# distro's network counters don't move during a download under mirrored networking.)
function Get-DownloadedBytes {
    $out = @(wsl.exe -d $Distro -u root -- sh -c 'du -sb /var/lib/containerd/io.containerd.content.v1.content 2>/dev/null')
    if ($out.Count -gt 0 -and $out[0] -match '^(\d+)') { return [int64]$Matches[1] }
    return [int64]0
}

function Invoke-LinuxInstall {
    $tz = Get-HostTimeZone
    if ($tz) {
        $rc = Invoke-Linux $Distro 'test -e "/usr/share/zoneinfo/$1" && ln -sf "/usr/share/zoneinfo/$1" /etc/localtime' @($tz)
        if ($rc -eq 0) { Write-Ok "Time zone $tz" } else { Write-Note "Could not set the time zone $tz; pick it in Settings." }
    }
    if ((Invoke-Linux $Distro 'command -v docker >/dev/null') -eq 0) {
        Write-Ok "Docker Engine is already installed"
    } else {
        # Docker Engine from Docker's apt repository, as install.sh's get.docker.com would,
        # minus that script's 20-second pause telling WSL users to get Docker Desktop.
        # apt's status lines drive the bar: downloads the first half, unpacking the second.
        Start-Status "Installing Docker Engine"
        $rc = Invoke-Linux $Distro @'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates >/dev/null
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq -o APT::Status-Fd=1 docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker >/dev/null 2>&1 || true
'@ @() {
            param($l)
            if ($l -match '^dlstatus:[^:]*:([\d.]+):') { $script:Status.Percent = [double]$Matches[1] / 2 }
            elseif ($l -match '^pmstatus:[^:]*:([\d.]+):') { $script:Status.Percent = 50 + [double]$Matches[1] / 2 }
        }
        if ($rc -ne 0) { Fail "Could not install Docker Engine in $Distro." }
        Complete-Status "Installed Docker Engine"
    }

    $script =if ($InstallScript -match '^https?://') { (Invoke-WebRequest -UseBasicParsing -Uri $InstallScript).Content } else { Get-Content -Raw $InstallScript }
    if ($script -is [byte[]]) { $script = [System.Text.Encoding]::UTF8.GetString($script) }
    Start-Status "Installing VS NVR"
    $script:Status.Detail = 'checking the download size'
    # Downloading the images is most of the wait: it fills the bar to 90%, by bytes
    # downloaded against their download size, and each later install.sh step adds 2%.
    $dl = @{ Total = (Get-ImageBytes $script); Start = (Get-DownloadedBytes); Step = ''; Pulled = $false }
    $warnings = New-Object System.Collections.Generic.List[string]
    $onLine = {
        param($l)
        if ($l -match '^== (.+) ==$') {
            $h = $Matches[1]
            if ($h -match '^Downloading (.+)$') { $dl.Step = "downloading $($Matches[1])"; $dl.Pulled = $true }
            else {
                $dl.Step = $h
                if ($dl.Total -gt 0 -and $dl.Pulled) { $script:Status.Percent = [math]::Min(99.0, [math]::Max(90.0, $script:Status.Percent) + 2) }
            }
            $script:Status.Detail = $dl.Step
        } elseif ($l -match '^\[!\] (.+)$') { $warnings.Add($Matches[1]) }
    }
    $onTick = {
        if ($dl.Total -le 0 -or -not $dl.Pulled -or $dl.Step -notmatch '^downloading') { return }
        $got = [math]::Min($dl.Total, [math]::Max(0, (Get-DownloadedBytes) - $dl.Start))
        $script:Status.Percent = [math]::Max($script:Status.Percent, 90 * $got / $dl.Total)
        $script:Status.Detail = '{0}, {1:0} of {2:0} MB' -f $dl.Step, [math]::Floor($got / 1e6), [math]::Floor($dl.Total / 1e6)
    }
    $rc = Invoke-Linux $Distro $script @('--recording-mount', '/srv/vs-nvr/recordings') $onLine $onTick
    if ($rc -ne 0) { Fail "install.sh failed (exit $rc). Fix the error above, then re-run this installer." }
    Complete-Status "Installed VS NVR"
    foreach ($w in $warnings) { Write-Note $w }
}

function Install-Nvr {
    Write-Banner "Sets up the VS NVR recorder in its own WSL distro. About 10 minutes."
    if (-not (Assert-Prerequisites)) { return }
    $state = Get-State
    if (-not $state) { $state = [pscustomobject]@{ Owner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } }
    Save-State $state

    Set-WslNetworking $state
    if (-not ((Get-Distros) -contains $Distro)) {
        New-NvrDistro $state
    } else {
        Write-Ok "Using the existing $Distro distro ($($state.Vhdx))"
    }
    if ($state.FootageKept) { $state.FootageKept = $false; Save-State $state }

    Register-KeepaliveTask
    Set-FirewallRules
    Set-SleepSetting $state
    Invoke-LinuxInstall
    Register-App $state

    # Mirrored networking gives the distro this PC's own LAN address.
    $ip = "<this PC's IP>"
    try { $ip = @((Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1).IPv4Address)[0].IPAddress } catch { }
    Write-Host ""
    Write-Host "  VS NVR is running." -ForegroundColor Green
    Write-Host "    On this PC:     http://localhost:8080, or VS NVR in the Start menu"
    Write-Host "    Other devices:  http://${ip}:8080"
    Write-Host ""
    Write-Host "  To remove it later, uninstall VS NVR in Settings > Apps." -ForegroundColor Gray
    Write-Host ""
    try { Start-Process 'http://localhost:8080' } catch { }
}

function Uninstall-Nvr {
    Write-Banner "Removes VS NVR from this PC."
    $state = Get-State
    if (-not $state) { Fail "VS NVR is not installed on this PC (no $StatePath)." }
    if ($state.Owner -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { Fail "VS NVR on this PC belongs to another Windows account." }
    $registered = (Get-Distros) -contains $Distro

    $keep = if ($Footage) { $Footage -eq 'Keep' } elseif ($registered) { Confirm-Yes "Keep your recordings and settings, so a reinstall picks them back up?" $true } else { $false }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    if ($registered) {
        wsl.exe -d $Distro -u root -- systemctl stop vs-nvr | Out-Null
        wsl.exe --terminate $Distro | Out-Null
    }
    foreach ($n in $RuleNames) { Remove-NetFirewallHyperVRule -Name $n -ErrorAction SilentlyContinue }
    Remove-Item $ShortcutPath -Force -ErrorAction SilentlyContinue
    Write-Ok "Stopped; startup task, firewall rules and Start menu shortcut removed"

    # Revert only what the installer changed, and only if nobody has changed it since.
    foreach ($c in $WslSettings) {
        $record = if ($state.WslConfig) { $state.WslConfig.($c.Key) } else { $null }
        if (-not ($record -and $record.Set)) { continue }
        if ((Get-WslConfigValue $c.Section $c.Key) -eq $c.Value) { Set-WslConfigValue $c.Section $c.Key $record.Prior; Write-Ok "WSL setting $($c.Key) restored (applies after WSL next restarts)" }
        $record.Set = $false
    }
    if ($state.Sleep -and $state.Sleep.Set) {
        if ((Get-AcStandbySeconds) -eq 0) { Set-AcStandbySeconds ([int]$state.Sleep.Prior); Write-Ok "Sleep setting restored" }
        $state.Sleep.Set = $false
    }

    if ($keep) {
        $state | Add-Member -NotePropertyName FootageKept -NotePropertyValue $true -Force
        Save-State $state
        # Stays in Settings > Apps, where uninstalling again can delete the kept disk.
        if (Test-Path $AppKey) { Set-ItemProperty $AppKey -Name DisplayName -Value 'VS NVR (stopped, recordings kept)' }
        Write-Ok "Recordings and settings kept in $($state.Vhdx) (the stopped $Distro distro). Reinstalling picks them back up; uninstall again and choose not to keep them to delete them."
        return
    }
    # Unregistering deletes the distro's disk, recordings included.
    if ($registered) { wsl.exe --unregister $Distro | Out-Null }
    if ($state.Vhdx) {
        Remove-Item $state.Vhdx -Force -ErrorAction SilentlyContinue
        $dir = Split-Path $state.Vhdx
        if ((Test-Path $dir) -and -not (Get-ChildItem $dir -Force)) { Remove-Item $dir -Force }
    }
    Remove-Item $AppKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $IconPath -Force -ErrorAction SilentlyContinue
    Remove-Item $StatePath -Force
    if (-not (Get-ChildItem $StateDir -Force)) { Remove-Item $StateDir -Force }
    Write-Ok "VS NVR removed, recordings included."
}

$consoleMode = Disable-QuickEdit
try {
    Remove-Item $LogPath -Force -ErrorAction SilentlyContinue
    Assert-Admin
    if ($Uninstall) { Uninstall-Nvr } else { Install-Nvr }
} catch {
    $inStep = [bool]$script:Status
    [void](Stop-Status)
    if ($inStep) {
        foreach ($l in $script:FailTail) { Write-Host "  $l" -ForegroundColor DarkGray }
    }
    Write-Host "[x] $($_.Exception.Message)" -ForegroundColor Red
    if ($inStep) { Write-Host "Full output: $LogPath" -ForegroundColor Gray }
    # Run as a file, report the failure in the exit code; under `irm | iex`, exit would
    # close the user's shell.
    if ($PSCommandPath) { exit 1 }
} finally {
    [void](Stop-Status)
    Restore-ConsoleMode $consoleMode
}
