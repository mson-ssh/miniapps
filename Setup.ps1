# =========================================================================
# MINIAZ SETUP SCRIPT - All-in-One Windows Deployment Tool
# =========================================================================
# Self-contained: Config, Disk partitioning and Hardware Info are embedded.
# Usage: irm https://raw.githubusercontent.com/mson-ssh/miniapps/main/Setup.ps1 | iex
# =========================================================================

# First possible line of output: "irm | iex" has to finish downloading this
# whole file before any of it can run, so nothing can be shown during that
# fetch - this line at least fires the instant execution starts, instead of
# leaving a blank console all the way through UAC elevation too.
#
# One line, printed once, and left standing until the menu clears the screen.
# It stood at three staged percentages before, which read as progress the
# script could not honour: the stages are not evenly spaced, the longest wait
# by far falls after the last of them, and the elevated window never reached
# the third at all.
Write-Host "Loading ..." -ForegroundColor Cyan

# Configure TLS 1.2 to prevent GitHub downloads from being blocked
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# Single source of truth for self-relaunch during UAC elevation
$SelfUrl = "https://raw.githubusercontent.com/mson-ssh/miniapps/main/Setup.ps1"

# Derived from $SelfUrl rather than written out again, so repo and branch still
# live on exactly one line. Feeds the "Update" stamp in the menu header.
$CommitApiUrl = $SelfUrl -replace '^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/.*$', 'https://api.github.com/repos/$1/$2/commits/$3'

# Two ways to get info.exe onto a machine, tried in that order by
# Publish-InfoExe. The prebuilt binary is the normal route; the source is only
# fetched when R2 cannot be reached and the exe has to be compiled on the spot.
# Both are rebuilt from info-app/ in the repo, so that folder stays canonical.
$InfoExeUrl    = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/info.exe"
$InfoSourceUrl = "https://raw.githubusercontent.com/mson-ssh/miniapps/main/info-app/Info.ps1"

function Get-NoCacheUrl {
    # raw.githubusercontent.com sits behind Fastly with "cache-control:
    # max-age=300", so for five minutes after a push an edge can still hand back
    # the previous file. That is how a machine ends up running yesterday's script
    # and reporting a bug that was fixed hours ago - and it hits every place this
    # file fetches itself, including the elevation relaunch and every feature
    # window.
    #
    # A unique query string misses the cached object and is served from origin.
    # raw ignores parameters it does not recognise. Only the two URLs carrying
    # code that changes often go through here: the app installers are
    # third-party binaries that do not move, and busting their cache would throw
    # away the CDN on 400MB of downloads for nothing.
    param([string]$Url)
    $sep = if ($Url -match '\?') { '&' } else { '?' }
    return ("{0}{1}_={2}" -f $Url, $sep, [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
}

# =========================================================================
# UI FOUNDATION - encoding, terminal capability detection, glyph set
# Set first so even elevation errors render correctly.
# =========================================================================
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# When output is piped/redirected there is no console buffer, so
# SetCursorPosition throws "handle is invalid". Detect once, guard everywhere.
$Script:CanReposition = $false
try { $Script:CanReposition = -not [Console]::IsOutputRedirected } catch { }

# Bump the console font size. Registry font settings only apply to new
# console windows, so the running one is resized directly via the Win32
# console font API. Best effort: only classic conhost supports this -
# Windows Terminal manages its own font and ignores/rejects the call.
if ($Script:CanReposition) {
    try {
        $fontCode = @'
    using System;
    using System.Runtime.InteropServices;
    public class Win32Font {
        [StructLayout(LayoutKind.Sequential)]
        public struct COORD { public short X; public short Y; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct CONSOLE_FONT_INFO_EX {
            public uint cbSize;
            public uint nFont;
            public COORD dwFontSize;
            public int FontFamily;
            public int FontWeight;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string FaceName;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetStdHandle(int nStdHandle);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetCurrentConsoleFontEx(IntPtr hOut, bool bMax, ref CONSOLE_FONT_INFO_EX info);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetCurrentConsoleFontEx(IntPtr hOut, bool bMax, ref CONSOLE_FONT_INFO_EX info);
    }
'@
        Add-Type -TypeDefinition $fontCode -ErrorAction SilentlyContinue
        $stdOut = [Win32Font]::GetStdHandle(-11)
        $fontInfo = New-Object Win32Font+CONSOLE_FONT_INFO_EX
        $fontInfo.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($fontInfo)
        if ([Win32Font]::GetCurrentConsoleFontEx($stdOut, $false, [ref]$fontInfo)) {
            # Built as a standalone variable, not "$fontInfo.dwFontSize.X = 0":
            # COORD is a value type, so mutating a field through a chained
            # property access edits a discarded copy and never sticks.
            $coord = New-Object Win32Font+COORD
            # Width 0 lets the TrueType font (Consolas by default) scale its
            # own width to match the requested height instead of distorting it.
            $coord.X = 0
            $coord.Y = 20
            $fontInfo.dwFontSize = $coord
            [Win32Font]::SetCurrentConsoleFontEx($stdOut, $false, [ref]$fontInfo) | Out-Null
        }
    } catch { }
}

# Enlarge the console window/buffer so the boxed UI has more room. Best
# effort: some hosts (Windows Terminal in particular) reject buffer/window
# resize requests outright, so this must never break the rest of the script.
if ($Script:CanReposition) {
    try {
        $rawUI = $Host.UI.RawUI
        $newWidth = 100
        $newHeight = 32
        # Buffer must be at least as large as the window on both axes, and
        # has to grow before the window is resized or this throws.
        $buffer = $rawUI.BufferSize
        if ($buffer.Width -lt $newWidth) { $buffer.Width = $newWidth }
        if ($buffer.Height -lt $newHeight) { $buffer.Height = $newHeight }
        $rawUI.BufferSize = $buffer
        $rawUI.WindowSize = New-Object System.Management.Automation.Host.Size($newWidth, $newHeight)
    } catch { }
}

# Use rich glyphs only when the console can also reposition (a real terminal);
# otherwise fall back to plain ASCII that renders anywhere.
$Script:Glyph = if ($Script:CanReposition) {
    @{ Ok = "$([char]0x2714)"; Fail = "$([char]0x2717)"; Skip = "$([char]0x2298)"; Run = "$([char]0x25CF)"
       Wait = "$([char]0x25CB)"; Full = "$([char]0x2588)"; Empty = "$([char]0x2591)"
       H = "$([char]0x2500)"; V = "$([char]0x2502)"
       TL = "$([char]0x256D)"; TR = "$([char]0x256E)"; BL = "$([char]0x2570)"; BR = "$([char]0x256F)" }
} else {
    @{ Ok = "[OK]"; Fail = "[X]"; Skip = "[-]"; Run = "*"; Wait = "."; Full = "#"; Empty = "."
       H = "-"; V = "|"; TL = "+"; TR = "+"; BL = "+"; BR = "+" }
}


# =========================================================================
# AUTO-ELEVATE TO ADMINISTRATOR (UAC PROMPT)
# =========================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($PSCommandPath) {
        # Running from a real file: relaunch that exact file
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    }
    else {
        # Running from memory (irm | iex): no way to read own source, so re-fetch
        $tempScript = "$env:TEMP\MiniApp\Setup_elevated.ps1"
        try {
            # -OutFile does not create parent dirs; MiniApp does not exist yet here
            $parent = Split-Path $tempScript -Parent
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Invoke-WebRequest -Uri (Get-NoCacheUrl $SelfUrl) -OutFile $tempScript -UseBasicParsing -ErrorAction Stop
            Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
        }
        catch {
            Write-Host "[ERROR] Could not download the script for elevation: $_" -ForegroundColor Red
            Write-Host "        Please run PowerShell as Administrator and try again." -ForegroundColor Yellow
        }
    }
    exit
}

# =========================================================================
# EMBEDDED: SYSTEM CONFIGURATION (was config/Config.ps1)
# Runs as a background job. Emits "[Config] <item>: OK|FAILED" lines.
# =========================================================================
$ConfigScript = {
    $ProgressPreference = 'SilentlyContinue'
    $PrimaryDNS = "1.1.1.1"
    $SecondaryDNS = "8.8.8.8"
    $TimezoneID = "SE Asia Standard Time"

    # 1. SMB CLIENT SETTING
    try {
        Set-SmbClientConfiguration -RequireSecuritySignature $false -Force -ErrorAction Stop
        Write-Output "[Config] SMB signature: OK"
    }
    catch { Write-Output "[Config] SMB signature: FAILED - $($_.Exception.Message)" }

    # 2. DESKTOP ICONS (This PC, Control Panel, User Files)
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        $icons = @(
            "{20D04FE0-3AEA-1069-A2D8-08002B30309D}",
            "{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}",
            "{59031a47-3f72-44a7-89c5-5595fe6b30ee}"
        )
        foreach ($icon in $icons) {
            New-ItemProperty -Path $regPath -Name $icon -Value 0 -PropertyType DWord -Force | Out-Null
        }
        # Refresh desktop immediately without restarting Explorer
        $code = @'
    using System;
    using System.Runtime.InteropServices;
    public class Win32Shell {
        [DllImport("shell32.dll")]
        public static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);
    }
'@
        Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
        [Win32Shell]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)
        Write-Output "[Config] Desktop icons: OK"
    }
    catch { Write-Output "[Config] Desktop icons: FAILED - $($_.Exception.Message)" }

    # 3. PASSWORD POLICY - never expire
    try {
        net accounts /maxpwage:unlimited | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Output "[Config] Password expiry: OK" }
        else { Write-Output "[Config] Password expiry: FAILED - exit code $LASTEXITCODE" }
    }
    catch { Write-Output "[Config] Password expiry: FAILED - $($_.Exception.Message)" }

    # 4. POWER MANAGEMENT - no sleep, no monitor timeout
    try {
        powercfg /change monitor-timeout-ac 0 | Out-Null
        powercfg /change monitor-timeout-dc 0 | Out-Null
        powercfg /change standby-timeout-ac 0 | Out-Null
        powercfg /change standby-timeout-dc 0 | Out-Null
        Write-Output "[Config] Power timeouts: OK"
    }
    catch { Write-Output "[Config] Power timeouts: FAILED - $($_.Exception.Message)" }

    # Disable Fast Startup
    try {
        $powerRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
        New-ItemProperty -Path $powerRegPath -Name "HiberbootEnabled" -Value 0 -PropertyType DWord -Force | Out-Null
        Write-Output "[Config] Fast Startup disabled: OK"
    }
    catch { Write-Output "[Config] Fast Startup disabled: FAILED - $($_.Exception.Message)" }

    # 5. DNS CONFIGURATION on all active physical adapters
    try {
        $adapters = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
        if (-not $adapters) {
            Write-Output "[Config] DNS ($PrimaryDNS): FAILED - no active physical adapter"
        }
        else {
            $ok = 0
            foreach ($adapter in $adapters) {
                try {
                    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($PrimaryDNS, $SecondaryDNS) -ErrorAction Stop
                    $ok++
                }
                catch { }
            }
            if ($ok -gt 0) { Write-Output "[Config] DNS ($PrimaryDNS): OK on $ok adapter(s)" }
            else { Write-Output "[Config] DNS ($PrimaryDNS): FAILED on all adapters" }
        }
    }
    catch { Write-Output "[Config] DNS ($PrimaryDNS): FAILED - $($_.Exception.Message)" }

    # 6. TIMEZONE
    try {
        Set-TimeZone -Id $TimezoneID -ErrorAction Stop
        Write-Output "[Config] Timezone ($TimezoneID): OK"
    }
    catch { Write-Output "[Config] Timezone ($TimezoneID): FAILED - $($_.Exception.Message)" }

    # 7. UAC - suppress consent prompts
    try {
        $sysPolicy = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
        Set-ItemProperty -Path $sysPolicy -Name "ConsentPromptBehaviorAdmin" -Value 0 -Force -ErrorAction Stop
        Set-ItemProperty -Path $sysPolicy -Name "PromptOnSecureDesktop" -Value 0 -Force -ErrorAction Stop
        Write-Output "[Config] UAC prompts disabled: OK"
    }
    catch { Write-Output "[Config] UAC prompts disabled: FAILED - $($_.Exception.Message)" }

    # 8. SYSTEM RESTORE - disable and reclaim shadow copy space
    try {
        Disable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore" -Name "DisableSR" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        vssadmin delete shadows /all /quiet | Out-Null
        Write-Output "[Config] System Restore disabled: OK"
    }
    catch { Write-Output "[Config] System Restore disabled: FAILED - $($_.Exception.Message)" }
}

# =========================================================================
# EMBEDDED: AUTO DISK PARTITION (was config/disk.ps1)
# Safety interlocks: skips if disk > 1100GB, skips if D:/E: already exist,
# skips unrecognised capacity classes, aborts if C: would drop below 30GB.
# Emits "[Disk] ..." status lines.
# =========================================================================
$DiskScript = {
    $ProgressPreference = 'SilentlyContinue'
    $LabelC = "OS"
    $LabelD = "LOCAL I"
    $LabelE = "LOCAL II"

    # Precision partitioning rules (.1GB padding counteracts NTFS overhead
    # so This PC shows crisp round numbers)
    $Config256GB = @{ SizeD = 50.1GB;  SizeE = 0GB;     HasE = $false }
    $Config500GB = @{ SizeD = 200.1GB; SizeE = 0GB;     HasE = $false }
    $Config1TB   = @{ SizeD = 400.1GB; SizeE = 200.1GB; HasE = $true  }

    try {
        # STEP 1: Safe relabel of C: (no formatting, zero data loss risk)
        try {
            Set-Volume -DriveLetter C -NewFileSystemLabel $LabelC -ErrorAction Stop
            Write-Output "[Disk] Relabel C: to '$LabelC': OK"
        }
        catch { Write-Output "[Disk] Relabel C: to '$LabelC': FAILED - $($_.Exception.Message)" }

        # STEP 2: Decrypt BitLocker - it pins files at the end of the volume
        # and blocks shrinking
        try {
            if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
                $bde = Get-BitLockerVolume -MountPoint C: -ErrorAction Stop
                if ($bde -and ($bde.VolumeStatus -ne 'FullyDecrypted')) {
                    Write-Output "[Disk] BitLocker active on C:, decrypting (this can take a while)..."
                    Disable-BitLocker -MountPoint C: -ErrorAction SilentlyContinue | Out-Null
                    manage-bde -off C: | Out-Null
                    # Bounded wait: a stuck decryption must not hang the job (and
                    # with it the Wait-Job at the end of the install run) forever.
                    $bdeDeadline = (Get-Date).AddMinutes(60)
                    $bdeDone = $false
                    while ((Get-Date) -lt $bdeDeadline) {
                        $bdeStatus = (Get-BitLockerVolume -MountPoint C: -ErrorAction SilentlyContinue).VolumeStatus
                        if (-not $bdeStatus -or $bdeStatus -eq 'FullyDecrypted') { $bdeDone = $true; break }
                        Start-Sleep -Seconds 5
                    }
                    if ($bdeDone) {
                        Write-Output "[Disk] BitLocker decryption: OK"
                    }
                    else {
                        Write-Output "[Disk] ABORTED - BitLocker still decrypting after 60 min, partitioning skipped"
                        return
                    }
                }
            }
        }
        catch { }

        # STEP 3: Detect capacity and apply safety interlocks
        $osPartition = Get-Partition -DriveLetter C -ErrorAction Stop
        $osDisk = Get-Disk -Number $osPartition.DiskNumber -ErrorAction Stop
        $totalGB = [Math]::Round($osDisk.Size / 1GB, 1)

        if ($totalGB -gt 1100) {
            Write-Output "[Disk] SKIPPED - disk is $totalGB GB (over the 1100GB safety limit)"
            return
        }

        $plan = $null; $planName = ""
        if ($totalGB -ge 200 -and $totalGB -le 300) {
            $plan = $Config256GB; $planName = "256GB class (C: remaining, D: 50.1GB)"
        }
        elseif ($totalGB -ge 400 -and $totalGB -le 600) {
            $plan = $Config500GB; $planName = "500GB class (C: remaining, D: 200.1GB)"
        }
        elseif ($totalGB -ge 800 -and $totalGB -le 1100) {
            $plan = $Config1TB; $planName = "1TB class (C: remaining, D: 400.1GB, E: 200.1GB)"
        }
        else {
            Write-Output "[Disk] SKIPPED - $totalGB GB does not match any known capacity class"
            return
        }

        # Never re-partition a disk that already has D: or E:
        $existingD = Get-Partition -DriveLetter D -ErrorAction SilentlyContinue
        $existingE = Get-Partition -DriveLetter E -ErrorAction SilentlyContinue
        if ($existingD -or $existingE) {
            Write-Output "[Disk] SKIPPED - D: or E: already exists, disk left untouched"
            return
        }

        # STEP 4: Shrink C:
        $totalShrink = $plan.SizeD + $plan.SizeE
        $targetCSize = $osPartition.Size - $totalShrink
        if ($targetCSize -le 30GB) {
            Write-Output "[Disk] ABORTED - C: would shrink below 30GB, no changes made"
            return
        }

        # Clear hiberfil.sys, an unmovable file that blocks shrinking
        try { powercfg /h off | Out-Null } catch { }

        Resize-Partition -DriveLetter C -Size $targetCSize -ErrorAction Stop
        Write-Output "[Disk] Plan: $planName"

        # STEP 5: Create and format D:
        if ($plan.HasE) {
            # 1TB: D: takes an exact size so E: gets the rest
            $partD = New-Partition -DiskNumber $osDisk.Number -Size $plan.SizeD -AssignDriveLetter -ErrorAction Stop
        }
        else {
            # 256GB/500GB: D: is the last partition, consume all freed space
            $partD = New-Partition -DiskNumber $osDisk.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
        }

        Start-Sleep -Seconds 3
        Update-HostStorageCache
        $formattedD = $false
        $lastErrD = "no attempt made"
        for ($i = 0; $i -lt 10; $i++) {
            try {
                # Format-Volume has NO -Quick parameter: passing it throws a parameter
                # binding error and the format never runs, leaving the volume RAW.
                # Quick format is the default; -Full is the opposite.
                # Bind by -Partition because a freshly created RAW partition is not
                # always resolvable through Get-Volume yet.
                $currentPart = Get-Partition -DiskNumber $osDisk.Number -PartitionNumber $partD.PartitionNumber -ErrorAction Stop
                Format-Volume -Partition $currentPart -FileSystem NTFS -NewFileSystemLabel $LabelD -Force -Confirm:$false -ErrorAction Stop | Out-Null
                Update-HostStorageCache
                $vol = Get-Partition -DiskNumber $osDisk.Number -PartitionNumber $partD.PartitionNumber | Get-Volume -ErrorAction Stop
                if ($vol.FileSystem -match "NTFS") { $formattedD = $true; break }
                $lastErrD = "volume reports FileSystem='$($vol.FileSystem)'"
            }
            catch { $lastErrD = $_.Exception.Message; Start-Sleep -Seconds 3 }
        }
        if (-not $formattedD) { throw "Failed to format D: - $lastErrD" }

        if ($partD.DriveLetter -ne 'D') {
            Set-Partition -DiskNumber $osDisk.Number -PartitionNumber $partD.PartitionNumber -NewDriveLetter D -ErrorAction SilentlyContinue
        }
        Write-Output "[Disk] Created D: '$LabelD': OK"

        # STEP 6: Create and format E: (1TB class only)
        if ($plan.HasE) {
            $partE = New-Partition -DiskNumber $osDisk.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop

            Start-Sleep -Seconds 3
            Update-HostStorageCache
            $formattedE = $false
            $lastErrE = "no attempt made"
            for ($i = 0; $i -lt 10; $i++) {
                try {
                    $currentPartE = Get-Partition -DiskNumber $osDisk.Number -PartitionNumber $partE.PartitionNumber -ErrorAction Stop
                    Format-Volume -Partition $currentPartE -FileSystem NTFS -NewFileSystemLabel $LabelE -Force -Confirm:$false -ErrorAction Stop | Out-Null
                    Update-HostStorageCache
                    $volE = Get-Partition -DiskNumber $osDisk.Number -PartitionNumber $partE.PartitionNumber | Get-Volume -ErrorAction Stop
                    if ($volE.FileSystem -match "NTFS") { $formattedE = $true; break }
                    $lastErrE = "volume reports FileSystem='$($volE.FileSystem)'"
                }
                catch { $lastErrE = $_.Exception.Message; Start-Sleep -Seconds 3 }
            }
            if (-not $formattedE) { throw "Failed to format E: - $lastErrE" }

            if ($partE.DriveLetter -ne 'E') {
                Set-Partition -DiskNumber $osDisk.Number -PartitionNumber $partE.PartitionNumber -NewDriveLetter E -ErrorAction SilentlyContinue
            }
            Write-Output "[Disk] Created E: '$LabelE': OK"
        }
    }
    catch {
        Write-Output "[Disk] FAILED - $($_.Exception.Message)"
    }
}

# =========================================================================
# EMBEDDED: OFFICE FORCE REMOVAL (was config/Remove-Office.ps1)
# Runs only when the machine has no Office licence and WPS Office is taking
# the Office slot. Uses Office Tool Plus's own "toolbox /rmoffice" console
# command (direct registry/component cleanup) to force-remove Office.
# NOTE: this used to run Microsoft's own GetHelpCmd.exe (OfficeScrubScenario)
# instead - the official, Microsoft-supported removal path. Switched to
# Office Tool Plus after GetHelpCmd repeatedly failed in real testing
# (rejected arguments on one build, then errored outright on a machine
# with a freshly installed Office 2024), while "toolbox /rmoffice" worked.
# Trade-off: this now depends on a third-party binary (not Microsoft's own),
# downloaded from officetool.plus rather than an aka.ms link, and it does
# its own direct component/registry cleanup rather than going through the
# officially supported removal flow.
# =========================================================================
$RemoveOfficeScript = {
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Scan first: skip the download/run entirely when there is no Office to
    # remove (common - a WPS machine often never had Office installed at
    # all). Click-to-Run (2016+ retail/volume, Microsoft 365) registers its
    # product list under its own Configuration key; anything else (older
    # MSI-based Office) shows up in the standard "Programs and Features"
    # Uninstall registry - the same mechanism Windows itself and Intune
    # detection rules use to check whether an application is installed.
    Write-Output "[Office] Scanning for an existing Office installation..."
    $officeFound = $false
    $c2rConfig = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction SilentlyContinue
    if ($c2rConfig -and $c2rConfig.ProductReleaseIds) { $officeFound = $true }
    if (-not $officeFound) {
        $uninstallRoots = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        foreach ($root in $uninstallRoots) {
            $match = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
                     Where-Object { $_.Publisher -eq 'Microsoft Corporation' -and $_.DisplayName -match 'Office|365 Apps' }
            if ($match) { $officeFound = $true; break }
        }
    }
    if (-not $officeFound) {
        Write-Output "[Office] Scan: no Office installation found - nothing to remove."
        return
    }
    Write-Output "[Office] Scan: an Office installation was found - proceeding with removal."

    $OfficeProcesses = "lync", "winword", "excel", "msaccess", "mstore", "infopath", "setlang", "msouc", "ois", "onenote", "outlook", "powerpnt", "mspub", "groove", "visio", "winproj", "graph", "teams"
    $stopped = @()
    foreach ($name in $OfficeProcesses) {
        $running = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($running) {
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            $stopped += $name
        }
    }
    if ($stopped.Count -gt 0) {
        Write-Output "[Office] Stopped running process(es): $($stopped -join ', ')"
    }
    else {
        Write-Output "[Office] No running Office processes found."
    }

    # "Runtime" build (bundles its own .NET Desktop Runtime) so this doesn't
    # depend on .NET being pre-installed on the target machine. Pre-repacked
    # as .zip (Expand-Archive can't extract .7z, the upstream release format)
    # and mirrored on our own R2 bucket - falls back to the GitHub release
    # (also .zip) if that mirror is ever unavailable.
    $OTP_R2_URL     = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/OTP.zip"
    $OTP_GITHUB_URL = "https://github.com/YerongAI/Office-Tool/releases/download/v11.6.6.0/Office_Tool_with_runtime_v11.6.6.0_x64.zip"
    $OTP_ZIP = "$env:TEMP\OfficeToolPlus.zip"
    $OTP_DIR = "$env:TEMP\OfficeToolPlus"
    $OTP_OUT = "$env:TEMP\OfficeToolPlus_stdout.log"
    $OTP_ERR = "$env:TEMP\OfficeToolPlus_stderr.log"

    try {
        if (Test-Path $OTP_ZIP) { Remove-Item $OTP_ZIP -Force -ErrorAction SilentlyContinue }
        if (Test-Path $OTP_DIR) { Remove-Item $OTP_DIR -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $OTP_DIR -ItemType Directory -Force | Out-Null

        $downloaded = $false
        foreach ($url in @($OTP_R2_URL, $OTP_GITHUB_URL)) {
            try {
                Write-Output "[Office] Downloading Office Tool Plus from $url ..."
                Start-BitsTransfer -Source $url -Destination $OTP_ZIP -ErrorAction Stop
                $downloaded = $true
                break
            }
            catch {
                Write-Output "[Office] Download failed from $url - $($_.Exception.Message)"
            }
        }
        if (-not $downloaded) {
            Write-Output "[Office] Force removal: FAILED - could not download Office Tool Plus from any source"
            return
        }
        $zipSizeMB = [math]::Round((Get-Item $OTP_ZIP).Length / 1MB, 2)
        Write-Output "[Office] Downloaded $zipSizeMB MB -> $OTP_ZIP"

        Write-Output "[Office] Extracting archive to $OTP_DIR ..."
        Expand-Archive -Path $OTP_ZIP -DestinationPath $OTP_DIR -Force

        $exe = Get-ChildItem -Path $OTP_DIR -Filter "Office Tool Plus.Console.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($exe) {
            Write-Output "[Office] Found Office Tool Plus.Console.exe at $($exe.FullName)"
            Write-Output "[Office] Running: toolbox /rmoffice"

            if (Test-Path $OTP_OUT) { Remove-Item $OTP_OUT -Force -ErrorAction SilentlyContinue }
            if (Test-Path $OTP_ERR) { Remove-Item $OTP_ERR -Force -ErrorAction SilentlyContinue }
            $proc = Start-Process -FilePath $exe.FullName -ArgumentList @('toolbox', '/rmoffice') -Wait -PassThru -NoNewWindow `
                                   -RedirectStandardOutput $OTP_OUT -RedirectStandardError $OTP_ERR
            Write-Output "[Office] Office Tool Plus exit code: $($proc.ExitCode)"

            foreach ($line in (Get-Content -Path $OTP_OUT -ErrorAction SilentlyContinue)) {
                if ($line) { Write-Output "[Office][stdout] $line" }
            }
            foreach ($line in (Get-Content -Path $OTP_ERR -ErrorAction SilentlyContinue)) {
                if ($line) { Write-Output "[Office][stderr] $line" }
            }

            # Office Tool Plus doesn't publicly document its exit codes for
            # toolbox commands, so 0 is treated as success and anything else
            # as failure - check the stdout/stderr lines above for the reason.
            if ($proc.ExitCode -eq 0) {
                Write-Output "[Office] Force removal: OK"
            }
            else {
                Write-Output "[Office] Force removal: FAILED - Office Tool Plus exit code $($proc.ExitCode)"
            }
        }
        else {
            Write-Output "[Office] Force removal: FAILED - download did not produce Office Tool Plus.Console.exe"
        }
    }
    catch { Write-Output "[Office] Force removal: FAILED - $($_.Exception.Message)" }
    finally {
        if (Test-Path $OTP_ZIP) { Remove-Item $OTP_ZIP -Force -ErrorAction SilentlyContinue }
        if (Test-Path $OTP_DIR) { Remove-Item $OTP_DIR -Recurse -Force -ErrorAction SilentlyContinue }
        # $OTP_OUT / $OTP_ERR are deliberately kept (not deleted) so
        # Invoke-RemoveOffice can open the raw, unmangled text afterwards.
    }
}

# =========================================================================
# EMBEDDED: DEBLOATWARE
# Job form of Invoke-Debloatware, used by Optimize Install so the debloat pass
# runs while apps install. Win11Debloat's own chatter is swallowed so it cannot
# scribble over the live install table; only the outcome line survives.
# =========================================================================
$DebloatScript = {
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        & ([scriptblock]::Create((Invoke-RestMethod "https://debloat.raphi.re/"))) -RunDefaults -Silent *>&1 | Out-Null
        Write-Output "[Debloat] Win11Debloat (-RunDefaults -Silent): OK"
    }
    catch { Write-Output "[Debloat] Win11Debloat: FAILED - $($_.Exception.Message)" }
}

# =========================================================================
# APP CATALOG
# TimeoutSec is per-app: interactive Office needs far longer than a silent MSI.
# =========================================================================
$R2 = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev"

$AppCatalog = @(
    @{ Name = "EVKey";        Url = "$R2/EVKey.exe";           WingetId = "";                                Args = "-s";                                       MatchName = "";                              TimeoutSec = 300 },
    @{ Name = "Chrome";       Url = "$R2/chrome.exe";          WingetId = "Google.Chrome";                   Args = "/silent /install";                         MatchName = "Google Chrome";                 TimeoutSec = 300 },
    @{ Name = "Klite";        Url = "$R2/klite.exe";           WingetId = "CodecGuide.K-LiteCodecPack.Mega"; Args = "/verysilent /norestart /suppressmsgboxes"; MatchName = "K-Lite Codec Pack";             TimeoutSec = 300 },
    @{ Name = "Telegram";     Url = "$R2/tele.exe";            WingetId = "Telegram.TelegramDesktop";        Args = "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES"; MatchName = "Telegram Desktop";              TimeoutSec = 300 },
    @{ Name = "Ultraview";    Url = "$R2/ultrav.exe";          WingetId = "DucFabulous.UltraViewer";         Args = "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES"; MatchName = "UltraViewer";                   TimeoutSec = 300 },
    @{ Name = "WinRAR";       Url = "$R2/winrar.exe";          WingetId = "RARLab.WinRAR";                   Args = "/S";                                       MatchName = "WinRAR";                        TimeoutSec = 300 },
    @{ Name = "Zalo";         Url = "$R2/zalo.exe";            WingetId = "VNGCorp.Zalo";                    Args = "/S";                                       MatchName = "Zalo";                          TimeoutSec = 300 },
    @{ Name = "Zoom";         Url = "$R2/zoom.exe";            WingetId = "Zoom.Zoom";                       Args = "/silent";                                  MatchName = "Zoom";                          TimeoutSec = 300 },
    @{ Name = "Office 2024";  Url = "$R2/OfficeSetup.exe";     WingetId = "";                                Args = "";                                         MatchName = "Microsoft Office|Microsoft 365"; TimeoutSec = 1800 },
    @{ Name = "VCRedist x64"; Url = "$R2/VC_redist.x64.exe";   WingetId = "Microsoft.VCRedist.2015+.x64";    Args = "/install /quiet /norestart";               MatchName = "Microsoft Visual C\+\+.*x64";   TimeoutSec = 300 },
    @{ Name = "VCRedist x86"; Url = "$R2/VC_redist.x86.exe";   WingetId = "Microsoft.VCRedist.2015+.x86";    Args = "/install /quiet /norestart";               MatchName = "Microsoft Visual C\+\+.*x86";   TimeoutSec = 300 }
)

# Stand-in for the Office 2024 slot on machines without an Office licence.
# NSIS 3.05 installer, so /S is the silent switch. It installs per-user under
# %LOCALAPPDATA%\Kingsoft\WPS Office and registers under HKCU Uninstall, which
# Test-IsInstalled already scans.
$WpsOffice = @{ Name = "WPS Office"; Url = "$R2/wps.exe"; WingetId = "Kingsoft.WPSOffice"; Args = "/S"; MatchName = "WPS Office"; TimeoutSec = 600 }

# Installer exit codes treated as success: 0 = ok, 3010 = reboot required,
# -1978335201 = already installed (winget/VC Redist)
$SuccessExitCodes = @(0, 3010, -1978335201)

# Winget has its own "nothing to do" results that are NOT failures. Without
# these, an app already present on the machine gets reported as failed.
#   -1978335189 (0x8A15002B) no applicable update / already newest
#   -1978335212 (0x8A150014) package already installed
#   -1978335216 (0x8A150010) no applicable installer, already current
#   -1978334972 (0x8A150104) another install in progress (retryable, not fatal)
$WingetSuccessExitCodes = $SuccessExitCodes + @(
    -1978335189, -1978335212, -1978335216
)

# Download resilience. Attempts are spent on the same direct link, never on a
# different source, so every machine ends up with the same artifact.
$Script:MaxDlTries = 3

# WebClient exposes no Timeout property, and an async download against a
# half-open connection never completes nor faults - the loop would spin forever.
# So progress is watched instead: if the byte count does not move for this long,
# the transfer is treated as dead and cancelled. Measuring stall rather than
# total time keeps slow-but-alive downloads (Office on a weak line) safe.
$Script:DlStallSec = 90

# Upper bound on the Config/Disk background jobs. BitLocker decryption is the
# slow one, and it has its own 60-minute cap inside $DiskScript.
$Script:JobTimeoutSec = 3600

# Apps sharing a serial group never install at the same time as each other;
# everything else installs fully in parallel. Both VC Redist bundles wrap MSI
# and contend for the Windows Installer _MSIExecute mutex, so running them
# together fails with 1618. Order inside a group follows $AppCatalog order.
$SerialGroups = @{
    "VCRedist x64" = "vcredist"
    "VCRedist x86" = "vcredist"
}

function Test-IsInstalled {
    param([string]$Pattern)
    if (-not $Pattern) { return $false }
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $installed = Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $Pattern }
    if ($installed) { return $true }

    # These install into the user profile and skip the uninstall registry
    if ($Pattern -match "Zalo" -and (Test-Path "$env:LOCALAPPDATA\Programs\Zalo\Zalo.exe")) { return $true }
    if ($Pattern -match "Telegram" -and (Test-Path "$env:APPDATA\Telegram Desktop\Telegram.exe")) { return $true }
    return $false
}

# Winget older than this is not trusted. Older clients carry a pinned
# certificate list that no longer matches the live Microsoft endpoints, so their
# commands die with 0x8A15005E (APPINSTALLER_CLI_ERROR_PINNED_CERTIFICATE_MISMATCH)
# no matter what arguments they are given.
$Script:MinWingetVersion = [version]"1.6"

function Get-WingetVersion {
    # Major.minor of the installed client, or $null when winget is absent or its
    # banner cannot be parsed. "winget --version" prints e.g. "v1.29.280".
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $null }
    try { $raw = & winget --version 2>&1 } catch { return $null }
    if ("$raw" -match '(\d+)\.(\d+)') { return [version]("{0}.{1}" -f $Matches[1], $Matches[2]) }
    return $null
}

$Script:WingetRelease = "https://github.com/microsoft/winget-cli/releases/latest/download"

function Get-WingetVersionText {
    # The banner as winget prints it ("v1.29.290"), for showing a before/after.
    # Get-WingetVersion above deliberately narrows to major.minor for comparing;
    # that is too coarse to show someone whether anything actually changed.
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return "not installed" }
    try { return "$(& winget --version 2>&1)".Trim() } catch { return "not installed" }
}

function Get-WingetLatestTag {
    # The current release tag as GitHub states it ("v1.29.290"), or "" when the
    # API cannot be reached. Time-boxed: nothing here is worth stalling a run.
    try {
        return "$((Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/winget-cli/releases/latest" `
                    -Headers @{ 'User-Agent' = 'MiniApp' } -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop).tag_name)"
    }
    catch { return "" }
}

function Test-WingetIsCurrent {
    # $true when the installed client already matches the current release.
    # Absent counts as not current, and so does an unreachable API: both callers
    # want a working winget more than they want to save the download, and the
    # alternative is silently skipping an upgrade that was needed.
    $local = Get-WingetVersionText
    if ($local -eq "not installed") { return $false }
    $latest = Get-WingetLatestTag
    if (-not $latest) { return $false }
    return ($local.TrimStart('v') -eq $latest.TrimStart('v'))
}

function Get-WingetTargetArch {
    # x64 / x86 / arm64, matching the folder names inside the dependency zip.
    # PROCESSOR_ARCHITECTURE reports the *process* architecture, so a 32-bit
    # PowerShell on 64-bit Windows says x86 - PROCESSOR_ARCHITEW6432 is what the
    # OS actually is in that case.
    $raw = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($raw) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        'x86'   { return 'x86' }
        default { return 'x64' }
    }
}

function Install-WingetDependencies {
    # App Installer refuses to register when a framework it declares is missing
    # or too old, and that single failure is the whole of winget-cli issues
    # #5559 and #5772 - both still open.
    #
    # So the list is read from the release itself at run time instead of URLs
    # being pinned in this file. The pinned ones had already rotted twice over:
    # Microsoft.UI.Xaml 2.8 stopped being a dependency at all when App Installer
    # moved from WinUI 2 to WinUI 3 (1.12.350 onward) and became
    # Microsoft.WindowsAppRuntime, and aka.ms/Microsoft.VCLibs.x64.14.00.Desktop
    # .appx serves 14.0.33321.0 against the 14.0.33728.0 the current release
    # asks for - which is #5772 exactly.
    param([string]$WorkDir)

    $arch = Get-WingetTargetArch
    $deps = (Invoke-RestMethod -Uri "$Script:WingetRelease/DesktopAppInstaller_Dependencies.json" `
                               -UseBasicParsing -ErrorAction Stop).Dependencies

    # Anything already registered at or above the declared version is left
    # alone. This is what keeps the ~93MB dependency download off the machines
    # that do not need it.
    $missing = @()
    foreach ($dep in $deps) {
        $need = [version]$dep.Version
        $have = Get-AppxPackage -Name $dep.Name -ErrorAction SilentlyContinue |
                Where-Object { "$($_.Architecture)" -eq $arch -or "$($_.Architecture)" -eq 'Neutral' } |
                Where-Object { [version]$_.Version -ge $need }
        if ($have) { Write-Host "   [-] $($dep.Name) $($dep.Version) already present" -ForegroundColor DarkGray }
        else       { $missing += $dep }
    }
    if ($missing.Count -eq 0) { return }

    Write-Host ("   [+] Fetching {0} framework package(s) (~93MB)..." -f $missing.Count) -ForegroundColor Gray
    $zip = Join-Path $WorkDir "WingetDeps.zip"
    $out = Join-Path $WorkDir "WingetDeps"
    Invoke-WebRequest -Uri "$Script:WingetRelease/DesktopAppInstaller_Dependencies.zip" `
                      -OutFile $zip -UseBasicParsing -ErrorAction Stop
    if (Test-Path $out) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue }
    Expand-Archive -LiteralPath $zip -DestinationPath $out -Force -ErrorAction Stop

    foreach ($dep in $missing) {
        # The underscore in the filter is load-bearing: without it
        # "Microsoft.VCLibs.140.00_*" would also match the .UWPDesktop package,
        # and the two are separate dependencies at different versions.
        $file = Get-ChildItem -Path (Join-Path $out $arch) -Filter "$($dep.Name)_*.appx" -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if (-not $file) { throw "$($dep.Name) is not in the $arch dependency package" }
        Write-Host "   [+] $($dep.Name) $($dep.Version)" -ForegroundColor Gray
        Add-AppxPackage -Path $file.FullName -ErrorAction Stop
    }
}

function Install-AppInstaller {
    # Registers the current App Installer, frameworks first. Serves both a
    # missing winget and one too old to trust. Emits nothing - callers read the
    # result back with Get-WingetVersion, so this cannot leak a return value
    # into the output of whatever called it.
    $tempDir = "$env:TEMP\MiniApp"
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
    $bundle = "$tempDir\Winget.msixbundle"

    try {
        Write-Host "-> Checking App Installer dependencies..." -ForegroundColor Gray
        Install-WingetDependencies -WorkDir $tempDir

        Write-Host "-> Downloading App Installer (~207MB)..." -ForegroundColor Gray
        Invoke-WebRequest -Uri "$Script:WingetRelease/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" `
                          -OutFile $bundle -UseBasicParsing -ErrorAction Stop

        # -ForceApplicationShutdown is what makes this an upgrade path and not
        # just a first install: replacing an already registered App Installer
        # fails while anything still holds it open.
        Write-Host "-> Registering App Installer..." -ForegroundColor Gray
        Add-AppxPackage -Path $bundle -ForceApplicationShutdown -ErrorAction Stop
    }
    catch {
        # Reported, not swallowed. Every Add-AppxPackage here used to carry
        # -ErrorAction SilentlyContinue, so a machine missing a framework came
        # out of this function looking successful and with no winget on it.
        Write-Host "-> Winget install failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    finally {
        Remove-Item $bundle, "$tempDir\WingetDeps.zip" -Force -ErrorAction SilentlyContinue
        Remove-Item "$tempDir\WingetDeps" -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-Winget {
    # Winget is needed both for the Winget menu option and as the fallback path
    $ver = Get-WingetVersion

    if ($null -eq $ver -or $ver -lt $Script:MinWingetVersion) {
        if ($null -eq $ver) {
            Write-Host "-> Winget not found. Starting silent Winget initialization..." -ForegroundColor Yellow
        }
        else {
            Write-Host "-> Winget $ver is older than $($Script:MinWingetVersion). Upgrading (~200MB)..." -ForegroundColor Yellow
        }

        Install-AppInstaller
        $ver = Get-WingetVersion

        if ($null -eq $ver) {
            Write-Host "-> Winget initialization did not complete. Fallback will be unavailable." -ForegroundColor Yellow
            return $false
        }
        # An upgrade that did not take is not fatal. The community repo is not
        # certificate-pinned, so the old client is still worth running.
        if ($ver -lt $Script:MinWingetVersion) {
            Write-Host "-> Winget is still $ver. Continuing with it anyway." -ForegroundColor Yellow
        }
        else {
            Write-Host "-> Winget $ver initialized successfully." -ForegroundColor Gray
        }
    }

    # Refresh the community repo only. A bare "winget source update" also pulls
    # msstore - the one source winget certificate-pins - which fails with
    # 0x8A15005E behind SSL inspection, a proxy, or an outdated client, and takes
    # the whole command down with it.
    & winget source update --name winget --disable-interactivity 2>&1 | Out-Null
    return $true
}

function Invoke-WingetRescue {
    # Opt-in second pass for apps whose direct link exhausted its retries.
    # Runs sequentially: rescues are rare and winget serializes internally.
    param(
        [Parameter(Mandatory)][object[]]$Apps,
        [Parameter(Mandatory)][hashtable]$States
    )

    if (-not (Initialize-Winget)) {
        Write-Host "  [!] Winget could not be initialized. Nothing was retried." -ForegroundColor Red
        return
    }

    foreach ($app in $Apps) {
        Write-Host ("  {0} Retrying {1} via Winget..." -f $Script:Glyph.Run, $app.Name) -ForegroundColor Cyan
        $wingetArgs = "install --id $($app.WingetId) --exact --source winget --silent " +
                      "--disable-interactivity --accept-package-agreements --accept-source-agreements"
        try {
            $proc = Start-Process winget -ArgumentList $wingetArgs -PassThru -WindowStyle Hidden -Wait
            $code = try { $proc.ExitCode } catch { $null }
            if ($null -eq $code -or $WingetSuccessExitCodes -contains $code) {
                $States[$app.Name] = "Done (Winget)"
                Write-Host ("  {0} {1} installed via Winget." -f $Script:Glyph.Ok, $app.Name) -ForegroundColor Green
            }
            else {
                $States[$app.Name] = "Failed (Winget: $code)"
                Write-Host ("  {0} {1} failed on Winget too (exit {2})." -f $Script:Glyph.Fail, $app.Name, $code) -ForegroundColor Red
            }
        }
        catch {
            $States[$app.Name] = "Failed (Winget launch)"
            Write-Host ("  {0} Could not launch Winget for {1}." -f $Script:Glyph.Fail, $app.Name) -ForegroundColor Red
        }
    }
}

# =========================================================================
# UI HELPERS - shared rendering primitives (glyphs, colors, boxes, bars)
# =========================================================================
$Script:UiWidth = 76

function Get-StatusColor {
    param([string]$State)
    if ($State -like "Failed*")   { return "Red" }
    if ($State -like "Done*")     { return "Green" }
    if ($State -like "Already*")  { return "DarkGray" }
    if ($State -like "Retrying*" -or $State -like "Stalled*") { return "Magenta" }
    if ($State -like "Installing*" -or $State -like "Downloading*") { return "Cyan" }
    return "Yellow"
}

function Get-StatusGlyph {
    param([string]$State)
    if ($State -like "Failed*")   { return $Script:Glyph.Fail }
    if ($State -like "Done*")     { return $Script:Glyph.Ok }
    if ($State -like "Already*")  { return $Script:Glyph.Skip }
    if ($State -like "Installing*" -or $State -like "Retrying*") { return $Script:Glyph.Run }
    return $Script:Glyph.Wait
}

function Get-ProgressBar {
    param([int]$Percent, [int]$Width = 22)
    if ($Percent -lt 0) { $Percent = 0 } elseif ($Percent -gt 100) { $Percent = 100 }
    $filled = [int][math]::Round($Width * $Percent / 100)
    return ($Script:Glyph.Full * $filled) + ($Script:Glyph.Empty * ($Width - $filled))
}

function Write-BoxLine {
    # A single framed line, padded to the box interior width
    param([string]$Text = "", [string]$Color = "Gray")
    $inner = $Script:UiWidth - 2
    if ($Text.Length -gt $inner) { $Text = $Text.Substring(0, $inner) }
    Write-Host ("{0}{1}{0}" -f $Script:Glyph.V, $Text.PadRight($inner)) -ForegroundColor $Color
}

function Write-BoxCenter {
    # Same frame as Write-BoxLine, text centred in the box interior
    param([string]$Text = "", [string]$Color = "Gray")
    $inner = $Script:UiWidth - 2
    if ($Text.Length -lt $inner) { $Text = (" " * [int](($inner - $Text.Length) / 2)) + $Text }
    Write-BoxLine $Text $Color
}

function Write-BoxTop    { Write-Host ($Script:Glyph.TL + ($Script:Glyph.H * ($Script:UiWidth - 2)) + $Script:Glyph.TR) -ForegroundColor Cyan }
function Write-BoxBottom { Write-Host ($Script:Glyph.BL + ($Script:Glyph.H * ($Script:UiWidth - 2)) + $Script:Glyph.BR) -ForegroundColor Cyan }
function Write-BoxSep    { Write-Host ($Script:Glyph.V + ($Script:Glyph.H * ($Script:UiWidth - 2)) + $Script:Glyph.V) -ForegroundColor DarkCyan }

function Format-HeaderCell {
    # One label+value cell of the menu header, padded to a fixed width so the
    # cells below it line up. A value too long for its cell ends in ".." rather
    # than being cut silently: the serial number is read off this screen and
    # copied onto a job sheet, and a shortened one would be wrong without
    # looking wrong.
    param([string]$Label, [string]$Value, [int]$LabelWidth, [int]$CellWidth)

    # Two columns of the cell are held back as a gutter so a value that fills it
    # still has clear air before the next label. Without that, a clipped value
    # runs its ".." straight into the label beside it - "Notebo..Serial:".
    $max = $CellWidth - 2
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = "-" }
    if ($Value.Length -gt $max) { $Value = $Value.Substring(0, $max - 2) + ".." }
    return ($Label + ":").PadRight($LabelWidth) + $Value.PadRight($CellWidth)
}

function Set-CursorTop {
    # Reposition only when a real console buffer exists
    param([int]$Top)
    if ($Script:CanReposition) { try { [Console]::SetCursorPosition(0, $Top) } catch { } }
}

# Staff-only sign on the way into the menu, not a lock. The value sits in
# plaintext in a file anyone can fetch from the raw GitHub URL, so it turns away
# someone who opened the wrong window - not someone who went looking. Kept plain
# for exactly that reason: hashing a secret that is readable two lines above
# would only make it look like something it is not.
$Script:AccessPassword   = '@z'
$Script:MaxPasswordTries = 3

function Read-MaskedLine {
    # Read-Host echoes what is typed, and -AsSecureString has to be marshalled
    # straight back to plaintext to compare against the value above - ceremony
    # with nothing behind it. So keys are taken one at a time and echoed as
    # asterisks. Backspace rubs out a character; Esc clears the line.
    $sb = New-Object System.Text.StringBuilder
    while ($true) {
        $key = [System.Console]::ReadKey($true)
        switch ($key.Key) {
            'Enter' {
                Write-Host ""
                return $sb.ToString()
            }
            'Backspace' {
                if ($sb.Length -gt 0) {
                    [void]$sb.Remove($sb.Length - 1, 1)
                    # Back up over the asterisk, paint a space on it, back up again.
                    Write-Host "`b `b" -NoNewline
                }
            }
            'Escape' {
                while ($sb.Length -gt 0) {
                    [void]$sb.Remove($sb.Length - 1, 1)
                    Write-Host "`b `b" -NoNewline
                }
            }
            default {
                # Arrows, F-keys and modifiers land here too, carrying KeyChar 0 -
                # only what would print is taken.
                if ([int]$key.KeyChar -ge 32) {
                    [void]$sb.Append($key.KeyChar)
                    Write-Host "*" -NoNewline
                }
            }
        }
    }
}

function Assert-AccessPassword {
    # Asked once, on the way into the menu. Feature windows re-run this file with
    # $MiniAppAction set and return before this point, so a technician is asked
    # once per session and not once per window.
    #
    # Three wrong answers close PowerShell.

    # ReadKey throws rather than prompts when there is no console to read from,
    # so a piped or redirected session is let through instead of crashing on the
    # doorstep. Nothing is protected by failing here that is not already readable
    # in the file itself.
    $canPrompt = $true
    try { $canPrompt = -not [Console]::IsInputRedirected } catch { }
    if (-not $canPrompt) { return }

    for ($try = 1; $try -le $Script:MaxPasswordTries; $try++) {
        Clear-Host
        Write-BoxTop
        Write-BoxCenter "MINIAPP  -  Windows Setup Tool" "White"
        Write-BoxSep
        Write-BoxLine "  Internal tool - authorised technicians only." "White"
        Write-BoxLine "  Please enter the password to continue." "Yellow"
        if ($try -gt 1) {
            $left = $Script:MaxPasswordTries - $try + 1
            Write-BoxSep
            Write-BoxLine ("  Wrong password. {0} attempt(s) left." -f $left) "Red"
        }
        Write-BoxBottom
        Write-Host ""
        Write-Host "  Password: " -NoNewline -ForegroundColor Cyan

        # Case-sensitive on purpose: -eq would let "@Z" through.
        if ((Read-MaskedLine) -ceq $Script:AccessPassword) {
            Clear-Host
            return
        }
    }

    Clear-Host
    Write-Host "Too many failed attempts. Closing PowerShell." -ForegroundColor Red
    # Long enough to read before the window goes.
    Start-Sleep -Seconds 2
    exit
}

function Read-OfficeChoice {
    # Office 2024 is only allowed on licensed machines; everything else gets
    # WPS Office. Asked once, before a single byte is downloaded.
    # Same navigation as the main menu: arrows + Enter, or a number key.
    # Returns 'Office', 'Wps', or 'Cancel'. Strings, not a bool: cancel is a
    # third outcome, and squeezing it into a bool compares wrong - PowerShell
    # casts a non-empty string to $true, so $true -eq 'Cancel' is True.
    $options = @(
        @{ Label = "Yes - install Office 2024"; Desc = "Customer / model holds an Office licence" },
        @{ Label = "No  - install WPS Office";  Desc = "No licence - WPS Office takes the Office slot" },
        @{ Label = "Cancel";                    Desc = "Change nothing and go back to the menu" }
    )
    $results = @('Office', 'Wps', 'Cancel')

    if (-not $Script:CanReposition) {
        # Non-interactive (piped/redirected): never block, keep the old default
        Write-Host "`n[Office] Non-interactive session - defaulting to Office 2024." -ForegroundColor DarkGray
        return 'Office'
    }

    $selected = 0
    $choice = $null
    while ($true) {
        Clear-Host
        Write-BoxTop
        Write-BoxLine "  OFFICE SUITE" "White"
        Write-BoxSep
        Write-BoxLine "  Does this customer / model have an Office licence?" "Yellow"
        Write-BoxBottom
        Write-Host ""

        for ($i = 0; $i -lt $options.Count; $i++) {
            $num = $i + 1
            if ($i -eq $selected) {
                Write-Host ("  {0} {1}. {2}" -f $Script:Glyph.Run, $num, $options[$i].Label.PadRight(28)) -ForegroundColor Black -BackgroundColor Cyan
                Write-Host ("       {0}" -f $options[$i].Desc) -ForegroundColor DarkGray
            }
            else {
                Write-Host ("    {0}. {1}" -f $num, $options[$i].Label) -ForegroundColor White
            }
        }
        Write-Host ""
        Write-Host "  Up/Down + Enter, a number key, or Esc to cancel." -ForegroundColor DarkGray

        switch ([System.Console]::ReadKey($true).Key) {
            'UpArrow'   { $selected = ($selected - 1 + $options.Count) % $options.Count }
            'DownArrow' { $selected = ($selected + 1) % $options.Count }
            'Enter'     { $choice = $selected }
            'D1'        { $choice = 0 }
            'NumPad1'   { $choice = 0 }
            'D2'        { $choice = 1 }
            'NumPad2'   { $choice = 1 }
            'D3'        { $choice = 2 }
            'NumPad3'   { $choice = 2 }
            # Escape cancels, the same way it exits the main menu
            'Escape'    { $choice = 2 }
        }

        if ($null -ne $choice) {
            # Clear so the install table starts at the top of a clean screen
            Clear-Host
            return $results[$choice]
        }
    }
}

# =========================================================================
# MAIN INSTALL ENGINE
# Downloads run fully in parallel; installs run one at a time from a queue
# so concurrent installers never fight over the Windows Installer service.
# =========================================================================
function Install-NecessaryApps {
    param(
        [ValidateSet('Installer', 'Winget')][string]$Method = 'Installer',
        # Empty means "nobody asked yet, ask now"; the rest are what
        # Read-OfficeChoice returns. Kept out of [bool] so cancelling stays a
        # state of its own instead of being read as "no licence".
        [ValidateSet('', 'Office', 'Wps', 'Cancel')][string]$OfficeChoice = '',
        # Optimize Install wants the desktop icons put out the moment the office
        # suite is on disk. Menu 2 never made icons and still does not.
        [switch]$WithOfficeShortcuts
    )

    # WPS Office takes over the Office 2024 slot when the machine has no licence
    $catalog = $AppCatalog
    if ($Method -eq 'Installer') {
        if (-not $OfficeChoice) { $OfficeChoice = Read-OfficeChoice }
        # Bail before the first Start-Job: cancel has to leave the machine
        # exactly as it was, and Config/Disk repartition C: the moment they run.
        if ($OfficeChoice -eq 'Cancel') {
            Write-Host "`n[Cancelled] Nothing was installed or changed." -ForegroundColor Yellow
            return
        }
        if ($OfficeChoice -eq 'Wps') {
            $catalog = @($AppCatalog | ForEach-Object { if ($_.Name -eq "Office 2024") { $WpsOffice } else { $_ } })
        }
    }

    Write-Host "`n[System] Starting Config and Disk setup in the background..." -ForegroundColor Magenta
    $configJob = Start-Job -ScriptBlock $ConfigScript
    $diskJob = Start-Job -ScriptBlock $DiskScript
    $backgroundJobs = @($configJob, $diskJob)

    # No Office licence: WPS took the Office slot above, and the machine's
    # existing Office install (if any) gets force-removed too, so the
    # customer never ends up with both WPS and a stale Office.
    if ($OfficeChoice -eq 'Wps') {
        $removeOfficeJob = Start-Job -ScriptBlock $RemoveOfficeScript
        $backgroundJobs += $removeOfficeJob
        Write-Host "-> Background jobs activated (Config, Disk, Office Removal)." -ForegroundColor Gray
    }
    else {
        Write-Host "-> Background jobs activated (Config, Disk)." -ForegroundColor Gray
    }

    # Winget is brought up to date alongside the installs rather than as its own
    # errand. It joins $backgroundJobs, which are collected *before* the winget
    # rescue pass at the end of this function - so the rescue never fires
    # through a client that is being replaced underneath it.
    #
    # Winget mode is excluded: Initialize-Winget already owns that path there,
    # and two things registering App Installer at once helps nobody.
    if ($Method -eq 'Installer') {
        $wingetFunctions = (Get-Command Get-WingetVersion, Get-WingetVersionText, Get-WingetLatestTag,
                                        Test-WingetIsCurrent, Get-WingetTargetArch,
                                        Install-WingetDependencies, Install-AppInstaller |
            ForEach-Object { "function $($_.Name) { $($_.ScriptBlock) }" }) -join "`n"

        $wingetJob = Start-Job -ArgumentList $wingetFunctions, $Script:WingetRelease -ScriptBlock {
            param([string]$FunctionDefs, [string]$ReleaseUrl)
            . ([scriptblock]::Create($FunctionDefs))
            $Script:WingetRelease = $ReleaseUrl
            $ProgressPreference = 'SilentlyContinue'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

            $before = Get-WingetVersionText

            # The version is checked before anything is fetched. Registering App
            # Installer is a ~207MB download, and a run that already has the
            # current client would otherwise pay it on top of the ~400MB of apps
            # this engine is pulling at the same time. Same check the DCU tool
            # makes, from the same function, so the two cannot drift apart.
            if (Test-WingetIsCurrent) {
                Write-Output "[Winget] already at ${before}: SKIPPED"
                return
            }

            # Its progress narration is written for a console this job does not
            # have, and the engine's progress table owns the one it would land
            # on. Only the before/after matters here.
            Install-AppInstaller *>&1 | Out-Null

            $after = Get-WingetVersionText
            if ($after -eq "not installed") {
                Write-Output "[Winget] update: FAILED - winget is still unavailable"
            }
            elseif ($after -eq $before) {
                # Not a failure: an unreachable GitHub API above means the check
                # was skipped, so ending where it started is the likely case.
                Write-Output "[Winget] unchanged at ${after}: SKIPPED"
            }
            else {
                Write-Output "[Winget] $before -> $after : OK"
            }
        }
        $backgroundJobs += $wingetJob
        Write-Host "-> Winget refresh running in the background." -ForegroundColor Gray
    }

    # Initialize-Winget is the Winget option's own bootstrap, and only its.
    # Installer mode does refresh winget - in the background job started above -
    # but that job checks the installed version against the current release
    # first and downloads nothing when there is nothing to gain. This path is
    # unconditional and blocking, which is right for a mode that cannot run
    # without winget and wrong for one that only wants it for a rescue pass.
    $wingetReady = $false
    if ($Method -eq 'Winget') {
        $wingetReady = Initialize-Winget
        if (-not $wingetReady) {
            Write-Host "`n[ERROR] Winget is unavailable, so the Winget method cannot run." -ForegroundColor Red
            Write-Host "        Use option 1 (Installer) instead." -ForegroundColor Yellow
            Wait-Job $backgroundJobs -Timeout $Script:JobTimeoutSec | Out-Null
            foreach ($j in $backgroundJobs) {
                if ($j.State -eq 'Running') { Stop-Job -Job $j -ErrorAction SilentlyContinue }
            }
            Receive-Job $backgroundJobs | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray }
            Remove-Job $backgroundJobs -Force | Out-Null
            return
        }
    }

    $tempDir = "$env:TEMP\MiniApp"
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

    # Win32 helper to pull interactive installers (Office) to the foreground
    $uiCode = @'
    using System;
    using System.Runtime.InteropServices;
    public class Win32UI {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
    }
'@
    Add-Type -TypeDefinition $uiCode -ErrorAction SilentlyContinue

    $appStates     = @{}   # Name -> display status
    $downloadTasks = @{}   # Name -> async download Task
    $webClients    = @{}   # Name -> WebClient (disposed on completion)
    $installMode   = @{}   # Name -> 'Installer' | 'Winget'
    $pending       = @()   # Names downloaded and waiting for a launch slot
    $running       = @{}   # Name -> @{ Proc = <Process>; Deadline = <DateTime> }
    # ArrayList, not @(): $startDownload appends from a child scope, where
    # "+=" on a plain array would silently write to a throwaway copy.
    $dlEvents      = New-Object System.Collections.ArrayList
    $dlTries       = @{}   # Name -> download attempts spent so far
    $retryAt       = @{}   # Name -> earliest time to start the next attempt
    $dlStall       = @{}   # Name -> @{ Bytes = <last seen>; Since = <DateTime> }

    # Shared across download progress-event handlers running on other threads
    $dlProgress = [hashtable]::Synchronized(@{})   # Name -> @{ Pct; Recv; Total }

    $overallStart = Get-Date
    Write-Host ""
    $startTop = if ($Script:CanReposition) { [Console]::CursorTop } else { 0 }

    $renderTable = {
        Set-CursorTop $startTop
        $done = 0; $fail = 0
        foreach ($a in $catalog) {
            $state = $appStates[$a.Name]
            if ($state -like "Done*" -or $state -like "Already*") { $done++ }
            if ($state -like "Failed*") { $fail++ }

            $detail = $state
            if ($state -like "Downloading*" -and $dlProgress[$a.Name]) {
                $p = $dlProgress[$a.Name]
                $detail = "Downloading {0,3}%  {1}MB / {2}MB" -f $p.Pct, $p.Recv, $p.Total
            }
            $glyph = Get-StatusGlyph $state
            $color = Get-StatusColor $state
            $line = "  {0} {1}  {2}" -f $glyph, $a.Name.PadRight(14), $detail
            Write-Host $line.PadRight($Script:UiWidth - 2) -ForegroundColor $color
        }
        # Overall progress line
        $total = $catalog.Count
        $pct = if ($total) { [int](($done + $fail) * 100 / $total) } else { 0 }
        $elapsed = (Get-Date) - $overallStart
        $bar = Get-ProgressBar -Percent $pct -Width 22
        $failTxt = if ($fail -gt 0) { "$fail failed" } else { "0 failed" }
        $summary = "  {0} {1}/{2}  {3}  {4:mm\:ss}" -f $bar, ($done + $fail), $total, $failTxt, $elapsed
        Write-Host $summary.PadRight($Script:UiWidth - 2) -ForegroundColor White
    }

    # Starts (or restarts) a direct download. A faulted WebClient cannot be
    # reused, so every attempt builds a fresh client and event subscription.
    $startDownload = {
        param($app)
        $tempExe = Join-Path $tempDir ($app.Url.Split('/')[-1])
        $wc = New-Object System.Net.WebClient
        $webClients[$app.Name] = $wc
        $dlProgress[$app.Name] = @{ Pct = 0; Recv = 0; Total = 0 }
        $ev = Register-ObjectEvent -InputObject $wc -EventName DownloadProgressChanged `
            -MessageData @{ Table = $dlProgress; Name = $app.Name } -Action {
                $d = $Event.MessageData
                $d.Table[$d.Name] = @{
                    Pct   = $EventArgs.ProgressPercentage
                    Recv  = [math]::Round($EventArgs.BytesReceived / 1MB, 1)
                    Total = [math]::Round($EventArgs.TotalBytesToReceive / 1MB, 1)
                }
            }
        $null = $dlEvents.Add($ev)
        $dlTries[$app.Name] = $dlTries[$app.Name] + 1
        $dlStall[$app.Name] = @{ Bytes = -1; Since = (Get-Date) }
        $downloadTasks[$app.Name] = $wc.DownloadFileTaskAsync($app.Url, $tempExe)
    }

    foreach ($app in $catalog) {
        if ($app.MatchName -and (Test-IsInstalled $app.MatchName)) {
            $appStates[$app.Name] = "Already Installed"
        }
        elseif ($app.Name -eq "EVKey" -and (Test-Path "C:\EVKey")) {
            $appStates[$app.Name] = "Already Installed"
        }
        elseif ($Method -eq 'Winget' -and $app.WingetId) {
            $appStates[$app.Name] = "Waiting to Install"
            $installMode[$app.Name] = 'Winget'
            $pending += $app.Name
        }
        else {
            # Direct download. WebClient streams to disk instead of buffering in RAM.
            $appStates[$app.Name] = "Downloading"
            $installMode[$app.Name] = 'Installer'
            $dlTries[$app.Name] = 0
            & $startDownload $app
        }
        Write-Host ("   [+] {0} - {1}" -f $app.Name.PadRight(13), $appStates[$app.Name]) -ForegroundColor Yellow
    }

    # --- Office desktop icons, fired the moment the suite is on disk ---
    # New-DesktopShortcuts probes Program Files, so it cannot run before the
    # installer finishes - but there is no reason for it to wait on the rest of
    # the run either.
    $officeSlot  = ""
    $officeReady = $false
    $shortcutJob = $null
    if ($WithOfficeShortcuts) {
        $officeSlot = if ($OfficeChoice -eq 'Wps') { "WPS Office" } else { "Office 2024" }
        # A suite that was already on the machine still wants its icons, and no
        # install is going to come along later to trigger them.
        if ($appStates[$officeSlot] -eq "Already Installed") { $officeReady = $true }
    }

    # Catalog order decides who goes first inside a serial group
    $orderIndex = @{}
    for ($i = 0; $i -lt $catalog.Count; $i++) { $orderIndex[$catalog[$i].Name] = $i }

    # $retryAt must be part of the condition: an app awaiting its backoff is in
    # none of the other collections, so the loop would exit before it retries.
    while ($downloadTasks.Count -gt 0 -or $pending.Count -gt 0 -or
           $running.Count -gt 0 -or $retryAt.Count -gt 0) {
        $dirty = $false

        # --- 0. Kill downloads that stopped moving ---
        # CancelAsync makes the task transition to canceled, which the harvest
        # step below already treats like a fault, so the retry path is reused.
        foreach ($key in @($downloadTasks.Keys)) {
            if ($downloadTasks[$key].IsCompleted) { continue }
            $seen = if ($dlProgress[$key]) { $dlProgress[$key].Recv } else { 0 }
            $st = $dlStall[$key]
            if ($seen -ne $st.Bytes) {
                # Progress moved: reset the stall clock
                $st.Bytes = $seen
                $st.Since = Get-Date
            }
            elseif (((Get-Date) - $st.Since).TotalSeconds -ge $Script:DlStallSec) {
                $appStates[$key] = "Stalled - cancelling"
                try { $webClients[$key].CancelAsync() } catch { }
                $st.Since = Get-Date   # do not fire again while it unwinds
                $dirty = $true
            }
        }

        # --- 1. Harvest finished downloads ---
        $finished = @()
        foreach ($key in @($downloadTasks.Keys)) {
            if ($downloadTasks[$key].IsCompleted) {
                $finished += $key
                if ($downloadTasks[$key].IsFaulted -or $downloadTasks[$key].IsCanceled) {
                    # Retry the same direct link. Most failures here are
                    # transient (DNS hiccup, dropped connection), so retrying
                    # the original source keeps every machine on the same
                    # artifact instead of silently switching package managers.
                    if ($dlTries[$key] -lt $Script:MaxDlTries) {
                        $waitSec = 2 * $dlTries[$key]          # 2s, then 4s
                        $retryAt[$key] = (Get-Date).AddSeconds($waitSec)
                        $appStates[$key] = "Retrying ({0}/{1})" -f ($dlTries[$key] + 1), $Script:MaxDlTries
                    }
                    else {
                        $appStates[$key] = "Failed (Download)"
                    }
                }
                else {
                    $appStates[$key] = "Waiting to Install"
                    $pending += $key
                }
                $dirty = $true
            }
        }
        foreach ($key in $finished) {
            $downloadTasks.Remove($key)
            $webClients[$key].Dispose()
            $webClients.Remove($key)
        }

        # --- 1b. Fire off scheduled retries once their backoff has elapsed ---
        foreach ($key in @($retryAt.Keys)) {
            if ((Get-Date) -ge $retryAt[$key]) {
                $retryAt.Remove($key)
                $appStates[$key] = "Downloading"
                & $startDownload ($catalog | Where-Object { $_.Name -eq $key })
                $dirty = $true
            }
        }

        # --- 2. Watch every running install ---
        foreach ($key in @($running.Keys)) {
            $proc = $running[$key].Proc
            $done = $false

            if ($proc.HasExited) {
                # A null ExitCode means Windows would not hand it back; the process
                # did exit, so trust it rather than reporting a false failure.
                $code = try { $proc.ExitCode } catch { $null }
                # Winget reports "already installed" with its own codes, which are
                # successes, not failures.
                $okCodes = if ($installMode[$key] -eq 'Winget') { $WingetSuccessExitCodes }
                           else { $SuccessExitCodes }
                if ($null -eq $code -or $okCodes -contains $code) {
                    $appStates[$key] = "Done"
                }
                else {
                    # No automatic switch to Winget: a bad exit code is reported
                    # as-is. The user is offered a Winget rescue pass afterwards.
                    $appStates[$key] = "Failed (ExitCode: $code)"
                }
                $done = $true
            }
            elseif ((Get-Date) -gt $running[$key].Deadline) {
                # Hung installer: kill it so its serial group is not blocked forever
                $proc | Stop-Process -Force -ErrorAction SilentlyContinue
                $appStates[$key] = "Failed (Timeout)"
                $done = $true
            }

            if ($done) {
                $running.Remove($key)
                # Only a suite that actually installed counts; a failed or timed
                # out one has nothing on disk to point a shortcut at.
                if ($key -eq $officeSlot -and $appStates[$key] -eq "Done") { $officeReady = $true }
                $dirty = $true
            }
        }

        # Fired once, as soon as the suite lands - not at the end of the run.
        if ($officeReady -and -not $shortcutJob) {
            $shortcutJob = Start-OfficeShortcutJob -OfficeChoice $OfficeChoice
            $backgroundJobs += $shortcutJob
        }

        # --- 3. Launch whatever is ready, in parallel ---
        # Sorted by catalog order so a serial group starts with its first member
        # (VC Redist x64 before x86).
        foreach ($key in @($pending | Sort-Object { $orderIndex[$_] })) {
            # Hold back if another member of the same serial group is installing
            $group = $SerialGroups[$key]
            if ($group) {
                $busy = @($running.Keys | Where-Object { $SerialGroups[$_] -eq $group })
                if ($busy.Count -gt 0) {
                    $appStates[$key] = "Waiting ($group busy)"
                    continue
                }
            }

            $pending = @($pending | Where-Object { $_ -ne $key })
            $app = $catalog | Where-Object { $_.Name -eq $key }
            $appStates[$key] = "Installing"
            $dirty = $true

            try {
                $proc = $null
                if ($installMode[$key] -eq 'Winget') {
                    # --source winget is not optional: without it winget resolves the id
                    # against every configured source, msstore included, and the pinned
                    # certificate check there fails with 0x8A15005E on some networks even
                    # though every id in the catalog lives in the community repo.
                    $wingetArgs = "install --id $($app.WingetId) --exact --source winget --silent --disable-interactivity --accept-package-agreements --accept-source-agreements"
                    # -WindowStyle Hidden, not -NoNewWindow: with -NoNewWindow the
                    # returned process object reports a null ExitCode even after exit.
                    $proc = Start-Process winget -ArgumentList $wingetArgs -PassThru -WindowStyle Hidden
                }
                elseif ($key -eq "EVKey") {
                    # WinRAR SFX: extracts to C:\EVKey and returns immediately,
                    # so there is no process worth tracking
                    Start-Process -FilePath (Join-Path $tempDir ($app.Url.Split('/')[-1])) -ArgumentList $app.Args -WindowStyle Hidden
                    $appStates[$key] = "Done"
                }
                elseif ([string]::IsNullOrWhiteSpace($app.Args)) {
                    # Interactive installer (Office) - surface its window to the user
                    $proc = Start-Process -FilePath (Join-Path $tempDir ($app.Url.Split('/')[-1])) -PassThru
                    $hwnd = [Win32UI]::FindWindow($null, "Microsoft Office")
                    if ($hwnd -ne [IntPtr]::Zero) { [Win32UI]::SetForegroundWindow($hwnd) | Out-Null }
                }
                else {
                    $proc = Start-Process -FilePath (Join-Path $tempDir ($app.Url.Split('/')[-1])) -ArgumentList $app.Args -PassThru
                }

                if ($proc) {
                    $running[$key] = @{
                        Proc     = $proc
                        Deadline = (Get-Date).AddSeconds($app.TimeoutSec)
                    }
                }
            }
            catch {
                $appStates[$key] = "Failed (Launch)"
            }
        }

        # Re-render on state change, or on a repositionable console whenever work
        # is in flight, so the download percentage animates and the elapsed clock
        # keeps ticking during a retry backoff (when nothing else is happening).
        $inFlight = $downloadTasks.Count -gt 0 -or $retryAt.Count -gt 0 -or $running.Count -gt 0
        if ($dirty -or ($Script:CanReposition -and $inFlight)) { & $renderTable }
        Start-Sleep -Milliseconds 200
    }
    & $renderTable

    # Tear down the download progress-event subscriptions
    foreach ($ev in $dlEvents) {
        Unregister-Event -SourceIdentifier $ev.Name -ErrorAction SilentlyContinue
        Remove-Job -Id $ev.Id -Force -ErrorAction SilentlyContinue
    }

    # A run where every app was skipped never entered the loop above, so the
    # fire point inside it never came round.
    if ($officeReady -and -not $shortcutJob) {
        $shortcutJob = Start-OfficeShortcutJob -OfficeChoice $OfficeChoice
        $backgroundJobs += $shortcutJob
    }

    # --- Wait for background jobs and report what they actually did ---
    # Bounded: a wedged job (disk/BitLocker) must not strand the whole run.
    Write-Host "`n[System] Waiting for background jobs to finish..." -ForegroundColor Cyan
    Wait-Job $backgroundJobs -Timeout $Script:JobTimeoutSec | Out-Null
    foreach ($job in $backgroundJobs) {
        if ($job.State -eq 'Running') {
            Write-Host ("   [!] Job '{0}' still running after {1} min - stopping it." -f
                $job.Name, [int]($Script:JobTimeoutSec / 60)) -ForegroundColor Red
            Stop-Job -Job $job -ErrorAction SilentlyContinue
        }
    }

    Write-Host "`n[Background Results]" -ForegroundColor Cyan
    foreach ($job in $backgroundJobs) {
        $lines = Receive-Job -Job $job
        foreach ($line in $lines) {
            $color = if ($line -match 'FAILED|ABORTED') { 'Red' }
                     elseif ($line -match 'SKIPPED') { 'Yellow' }
                     else { 'Gray' }
            Write-Host "   $line" -ForegroundColor $color
        }
        if ($job.State -eq 'Failed') {
            Write-Host "   [!] Job '$($job.Name)' crashed: $($job.ChildJobs[0].JobStateInfo.Reason.Message)" -ForegroundColor Red
        }
    }
    Remove-Job $backgroundJobs -Force | Out-Null

    # --- Optional Winget rescue pass (Installer mode, opt-in) ---
    # Nothing switches package managers without being asked. Only apps that
    # failed AND have a WingetId can be rescued.
    if ($Method -eq 'Installer') {
        $rescuable = @($catalog | Where-Object { $appStates[$_.Name] -like "Failed*" -and $_.WingetId })
        $unrescuable = @($catalog | Where-Object { $appStates[$_.Name] -like "Failed*" -and -not $_.WingetId })

        if ($rescuable.Count -gt 0) {
            Write-Host ""
            Write-BoxTop
            Write-BoxLine "  RETRY WITH WINGET?" "White"
            Write-BoxSep
            Write-BoxLine ("  {0} app(s) failed after {1} download attempts:" -f $rescuable.Count, $Script:MaxDlTries) "Yellow"
            foreach ($r in $rescuable) { Write-BoxLine ("      - {0}" -f $r.Name) "Yellow" }
            if ($unrescuable.Count -gt 0) {
                Write-BoxSep
                Write-BoxLine "  No Winget package, cannot retry:" "DarkGray"
                foreach ($r in $unrescuable) { Write-BoxLine ("      - {0}" -f $r.Name) "DarkGray" }
            }
            Write-BoxSep
            $wingetVer = Get-WingetVersion
            if ($null -eq $wingetVer) {
                Write-BoxLine "  Winget is NOT installed. Continuing will" "Yellow"
                Write-BoxLine "  download and install it (~200MB)." "Yellow"
            }
            elseif ($wingetVer -lt $Script:MinWingetVersion) {
                Write-BoxLine ("  Winget {0} is too old to trust. Continuing" -f $wingetVer) "Yellow"
                Write-BoxLine "  will download and upgrade it (~200MB)." "Yellow"
            }
            else {
                Write-BoxLine ("  Winget {0} is available on this machine." -f $wingetVer) "Gray"
            }
            Write-BoxBottom

            $answer = 'n'
            if ($Script:CanReposition) {
                Write-Host "`n  Retry these with Winget? [y/N] " -ForegroundColor Cyan -NoNewline
                try { $answer = [System.Console]::ReadKey($true).KeyChar } catch { $answer = 'n' }
                Write-Host $answer
            }
            else {
                # Non-interactive (piped/redirected): never prompt, never assume yes
                Write-Host "`n  Non-interactive session - skipping Winget retry." -ForegroundColor DarkGray
            }

            if ("$answer" -match '^[yY]$') {
                Invoke-WingetRescue -Apps $rescuable -States $appStates
            }
            else {
                Write-Host "  Skipped. Direct-link installers were left as-is." -ForegroundColor DarkGray
            }
        }
    }

    # --- Reclaim the ~400MB of installers ---
    Write-Host "`n[System] Cleaning up temporary installation files..." -ForegroundColor Cyan
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

    # Desktop shortcuts for whichever suite is now on disk - just installed
    # or already there before this run. $OfficeChoice is '' for the Winget
    # method (never asks), which falls back to detecting what is present.
    New-DesktopShortcuts -OfficeChoice $OfficeChoice

    # --- Summary card ---
    $installed = @($catalog | Where-Object { $appStates[$_.Name] -like "Done*" })
    $skipped   = @($catalog | Where-Object { $appStates[$_.Name] -like "Already*" })
    $failed    = @($catalog | Where-Object { $appStates[$_.Name] -like "Failed*" })
    $elapsed   = (Get-Date) - $overallStart

    Write-Host ""
    Write-BoxTop
    Write-BoxLine "  SUMMARY" "White"
    Write-BoxSep
    Write-BoxLine ("  {0} Installed : {1}" -f $Script:Glyph.Ok,   $installed.Count) "Green"
    Write-BoxLine ("  {0} Skipped   : {1}" -f $Script:Glyph.Skip, $skipped.Count)   "DarkGray"
    Write-BoxLine ("  {0} Failed    : {1}" -f $Script:Glyph.Fail, $failed.Count) $(if ($failed.Count) { "Red" } else { "Green" })
    foreach ($f in $failed) {
        Write-BoxLine ("      - {0}: {1}" -f $f.Name, $appStates[$f.Name]) "Red"
    }
    Write-BoxSep
    Write-BoxLine ("  Elapsed : {0:mm\:ss}" -f $elapsed) "Gray"
    Write-BoxBottom

    if ($failed.Count -gt 0) {
        Write-Host "`n[!] Finished with warnings. Re-run this option to retry failed apps." -ForegroundColor Yellow
    }
    else {
        Write-Host "`n[+] All apps installed and system setup complete." -ForegroundColor Green
    }
}

# =========================================================================
# MENU ACTIONS
# =========================================================================
function New-DesktopShortcuts {
    # Neither suite puts icons on the desktop on its own, so this covers it -
    # for whichever app ends up on disk, whether it was just installed or was
    # already there before this run. With a known licence answer, only that
    # suite's shortcuts go out - a WPS box must not also get Word/Excel/
    # PowerPoint icons, and vice versa. With no context (standalone menu
    # access, or the Winget method which never asks) fall back to detecting
    # what is actually on the machine, so a box carrying both suites gets
    # both sets.
    param(
        [ValidateSet('', 'Office', 'Wps')][string]$OfficeChoice = ''
    )
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $createOffice = ($OfficeChoice -ne 'Wps')
        $createWps    = ($OfficeChoice -ne 'Office')

        if ($createOffice) {
            $officeApps = @{ "WINWORD.EXE" = "Word"; "EXCEL.EXE" = "Excel"; "POWERPNT.EXE" = "PowerPoint" }
            $officeRoots = @(
                "C:\Program Files\Microsoft Office\root\Office16",
                "C:\Program Files (x86)\Microsoft Office\root\Office16"
            )
            $wshShell = New-Object -ComObject WScript.Shell
            $created = 0
            foreach ($root in $officeRoots) {
                foreach ($exe in $officeApps.Keys) {
                    $target = Join-Path $root $exe
                    $shortcutPath = Join-Path $desktop "$($officeApps[$exe]).lnk"
                    if ((Test-Path $target) -and -not (Test-Path $shortcutPath)) {
                        $shortcut = $wshShell.CreateShortcut($shortcutPath)
                        $shortcut.TargetPath = $target
                        $shortcut.Save()
                        $created++
                    }
                }
            }
            if ($created -gt 0) { Write-Host "[OK] Created $created Office desktop shortcut(s)." -ForegroundColor Green }
        }

        if ($createWps) {
            # WPS already ships finished shortcuts under Start Menu\Programs, so they
            # are copied out instead of being rebuilt from an exe path. Both hives are
            # checked: WPS installs per-user, but an all-users copy can exist too.
            # Only the three productivity apps (Writer/Spreadsheets/Presentation =
            # Docs/Sheet/Slide) are copied - not the WPS launcher, PDF, Cloud, etc.
            $startMenus = @(
                (Join-Path $env:APPDATA     "Microsoft\Windows\Start Menu\Programs"),
                (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs")
            )
            $wpsAppPattern = 'Writer|Spreadsheet|Presentation'
            $copied = 0
            foreach ($menu in $startMenus) {
                if (-not (Test-Path $menu)) { continue }
                # Match the folder name too: WPS files its shortcuts inside a "WPS
                # Office" folder, and some builds name them plain "Writer.lnk".
                $links = Get-ChildItem -Path $menu -Filter "*.lnk" -Recurse -ErrorAction SilentlyContinue |
                         Where-Object { ($_.Name -match 'WPS' -or $_.Directory.Name -match 'WPS') -and
                                        $_.Name -match $wpsAppPattern }
                foreach ($link in $links) {
                    $dest = Join-Path $desktop $link.Name
                    if (-not (Test-Path $dest)) {
                        Copy-Item -LiteralPath $link.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
                        if (Test-Path $dest) { $copied++ }
                    }
                }
            }
            if ($copied -gt 0) { Write-Host "[OK] Copied $copied WPS desktop shortcut(s)." -ForegroundColor Green }
        }
    }
    catch {
        Write-Host "[WARN] Could not create desktop shortcuts: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Start-OfficeShortcutJob {
    # New-DesktopShortcuts, run in the background. It prints, and the install
    # progress table is drawn with SetCursorPosition - a line arriving mid-frame
    # tears it - so its output is held inside the job and printed with the rest
    # of the background results once the table is finished.
    #
    # The live definition is shipped in because a job starts in a fresh session
    # holding none of this script's functions; duplicating it here would leave
    # two copies to keep in step by hand.
    param([ValidateSet('', 'Office', 'Wps')][string]$OfficeChoice = '')

    $defs = "function New-DesktopShortcuts { $((Get-Command New-DesktopShortcuts).ScriptBlock) }"
    return Start-Job -ArgumentList $defs, $OfficeChoice -ScriptBlock {
        param([string]$FunctionDefs, [string]$Choice)
        . ([scriptblock]::Create($FunctionDefs))
        # Every stream folded into one and stringified: Write-Host lines are the
        # whole of what this reports, and they are worth keeping.
        New-DesktopShortcuts -OfficeChoice $Choice *>&1 | ForEach-Object { "[Icons] $_" }
    }
}

function Show-SystemInfo {
    param(
        # '' = no known context (standalone menu access): detect whichever
        # suite is actually on disk, so a box carrying both gets both sets.
        # 'Office' / 'Wps' = only create shortcuts for that suite, matching
        # the licence answer from Read-OfficeChoice.
        [ValidateSet('', 'Office', 'Wps')][string]$OfficeChoice = '',
        # A build that already finished - Optimize Install compiles info.exe in
        # the background while the apps install. Empty means build it here.
        [string]$InfoExePath = ''
    )

    # Builds/places info.exe on the Desktop, then launches it as its own
    # process rather than rendering the same window inline in this console
    # (a previous version did that with ShowDialog(), which meant closing
    # the PowerShell window also killed the info window, since it lived in
    # the same process). Started detached, so it keeps running independently
    # even after Setup.ps1 exits.
    $infoExePath = $InfoExePath
    if ([string]::IsNullOrWhiteSpace($infoExePath)) { $infoExePath = Publish-InfoExe }
    # Two separate ifs, not "-and": PowerShell's -and always evaluates both
    # sides (it does not short-circuit), so Test-Path would still run - and
    # throw on a null/empty path - even when $infoExePath came back empty.
    $launched = $false
    if (-not [string]::IsNullOrWhiteSpace($infoExePath)) {
        if (Test-Path -LiteralPath $infoExePath) {
            try {
                Start-Process -FilePath $infoExePath -ErrorAction Stop
                $launched = $true
                Write-Host "[OK] Opened $infoExePath" -ForegroundColor Green
            }
            catch {
                Write-Host "[ERROR] Could not open $infoExePath : $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        else {
            Write-Host "[WARN] Expected info.exe at $infoExePath but it is not there." -ForegroundColor Yellow
        }
    }
    if (-not $launched) {
        Write-Host "[WARN] The info window was skipped." -ForegroundColor Yellow
    }

    New-DesktopShortcuts -OfficeChoice $OfficeChoice
}

function Update-Winget {
    # Menu action. Windows ships App Installer and updates it through the Store,
    # which is exactly what a freshly imaged machine has not done yet - and on a
    # box where the Store is broken or stripped, never will. This takes the same
    # package straight from Microsoft's GitHub releases instead.
    Write-Host "`n[Winget] Updating the Windows Package Manager..." -ForegroundColor Magenta
    $beforeText = Get-WingetVersionText
    $before     = Get-WingetVersion
    Write-Host "   Installed now: $beforeText" -ForegroundColor Gray

    Install-AppInstaller

    $afterText = Get-WingetVersionText
    $after     = Get-WingetVersion
    Write-Host ""
    if ($null -eq $after) {
        Write-Host "[ERROR] Winget is still not available on this machine." -ForegroundColor Red
        Write-Host "        The reason is printed above." -ForegroundColor DarkGray
        return
    }
    if ($null -ne $before -and $afterText -eq $beforeText) {
        Write-Host "[OK] Already current: $afterText" -ForegroundColor Green
    }
    else {
        Write-Host ("[OK] Winget {0} -> {1}" -f $beforeText, $afterText) -ForegroundColor Green
    }
}

# Where the MSYS2 winget package puts itself, and the toolchain folder the
# VS Code guide has you put on PATH. Both are fixed by MSYS2.MSYS2's own
# manifest ("--root C:\msys64"), not chosen here.
$Script:MsysRoot   = "C:\msys64"
$Script:MsysBinDir = "C:\msys64\ucrt64\bin"

function Invoke-WingetInstall {
    # One winget install, reported. --source winget is pinned for the reason it
    # is pinned everywhere else in this file: without it winget resolves the id
    # against every registered source including msstore, the one source that is
    # certificate-pinned, and that fails with 0x8A15005E behind SSL inspection
    # or on an old client - taking the command down over a package that never
    # needed the Store.
    param([string]$Id, [string[]]$ExtraArgs = @())

    $wgArgs = @('install', '--id', $Id, '--source', 'winget', '--exact',
                '--silent', '--accept-package-agreements', '--accept-source-agreements',
                '--disable-interactivity') + $ExtraArgs
    # -WindowStyle Hidden, not -NoNewWindow: the latter hands back a process
    # object whose ExitCode is null even after it has exited.
    $proc = Start-Process -FilePath 'winget' -ArgumentList $wgArgs -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
    $code = try { $proc.ExitCode } catch { $null }
    if ($null -eq $code -or $WingetSuccessExitCodes -contains $code) { return $true }
    Write-Host "      winget exit code $code" -ForegroundColor DarkGray
    return $false
}

function Get-VSCodeCli {
    # The code.cmd shim, wherever the install put it. Looked up by path rather
    # than called off PATH: the installer does add itself, but this process
    # already had its environment when it started and will not see it.
    $candidates = @(
        (Join-Path $env:ProgramFiles "Microsoft VS Code\bin\code.cmd"),
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft VS Code\bin\code.cmd"),
        (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd")
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Add-MachinePathEntry {
    # Machine PATH, not the per-account one the guide's click-through describes:
    # this runs elevated on a box being set up for someone else, and a compiler
    # only the technician's account can see is not a working environment.
    # Returns $true when it added the folder, $false when it was already there.
    param([string]$Folder)

    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = @($current -split ';' | Where-Object { $_ })
    if ($parts -contains $Folder) { return $false }

    [Environment]::SetEnvironmentVariable('Path', (($parts + $Folder) -join ';'), 'Machine')
    # A machine variable only reaches processes started after it - including
    # this one, which is why it is also pushed into the live environment so the
    # verification step below can actually find gcc.
    $env:Path = "$env:Path;$Folder"
    return $true
}

function Install-CppEnvironment {
    # Follows the VS Code C++ guide for Windows, MinGW-w64 flavour:
    #   https://code.visualstudio.com/docs/languages/cpp
    #   https://code.visualstudio.com/docs/cpp/config-mingw
    #
    # All four steps matter. The C/C++ extension ships neither a compiler nor a
    # debugger - "VS Code as an editor relies on command-line tools" - so a
    # machine given only the editor and the extension has a C++ setup that
    # cannot build anything.
    Write-Host "`n[C++] VS Code + MinGW-w64 (MSYS2) development environment" -ForegroundColor Magenta

    # Every step here goes through winget, so it is brought up before the first
    # one rather than failing four times over. This used to point at an "Update
    # Winget" tool in this same window, which was removed when the install engine
    # started refreshing winget on its own - leaving a dead end with no way out.
    if (-not (Test-WingetIsCurrent)) {
        Write-Host "      winget is missing or out of date - fixing that first (~207MB)..." -ForegroundColor Yellow
        Install-AppInstaller
    }
    if ($null -eq (Get-WingetVersion)) {
        Write-Host "`n[ERROR] Winget could not be installed, so nothing here can run." -ForegroundColor Red
        Write-Host "        The reason is printed above." -ForegroundColor DarkGray
        return
    }

    Write-Host "      This downloads roughly 2GB and adds $Script:MsysBinDir" -ForegroundColor DarkGray
    Write-Host "      to the machine PATH." -ForegroundColor DarkGray
    Write-Host "`n  Continue? [y/N] " -NoNewline -ForegroundColor Yellow
    if ("$([System.Console]::ReadKey($false).KeyChar)" -notmatch '^[yY]$') {
        Write-Host "`n[Cancelled] Nothing was installed." -ForegroundColor Yellow
        return
    }
    Write-Host "`n"

    $results = New-Object System.Collections.Specialized.OrderedDictionary

    # --- 1. The editor ---
    # --scope machine so every account on the box gets it, not just whoever the
    # technician happened to be logged in as.
    Write-Host "[1/4] Installing Visual Studio Code..." -ForegroundColor Cyan
    $results['VS Code'] = Invoke-WingetInstall -Id 'Microsoft.VisualStudioCode' -ExtraArgs @('--scope', 'machine')

    # --- 2. The toolchain host ---
    Write-Host "[2/4] Installing MSYS2..." -ForegroundColor Cyan
    $results['MSYS2'] = Invoke-WingetInstall -Id 'MSYS2.MSYS2'

    # --- 3. The compiler itself ---
    Write-Host "[3/4] Installing the MinGW-w64 toolchain (this is the slow one)..." -ForegroundColor Cyan
    $bash = Join-Path $Script:MsysRoot "usr\bin\bash.exe"
    if (-not (Test-Path -LiteralPath $bash)) {
        Write-Host "      MSYS2 is not at $Script:MsysRoot - skipping the toolchain." -ForegroundColor Yellow
        $results['MinGW-w64 toolchain'] = $false
    }
    else {
        # Called directly rather than through Start-Process so pacman's progress
        # is visible - this step is minutes long and a silent window looks hung.
        # --noconfirm is what the guide's "press Enter, then type Y" becomes
        # when nobody is at the keyboard.
        & $bash -lc "pacman -Syu --noconfirm"
        & $bash -lc "pacman -S --needed --noconfirm base-devel mingw-w64-ucrt-x86_64-toolchain"
        $results['MinGW-w64 toolchain'] = ($LASTEXITCODE -eq 0)
    }

    # --- 4. PATH and the extension ---
    Write-Host "[4/4] Setting PATH and installing the C/C++ extension..." -ForegroundColor Cyan
    if (Test-Path -LiteralPath $Script:MsysBinDir) {
        if (Add-MachinePathEntry -Folder $Script:MsysBinDir) {
            Write-Host "      Added $Script:MsysBinDir to the machine PATH." -ForegroundColor Gray
        }
        else {
            Write-Host "      $Script:MsysBinDir was already on the machine PATH." -ForegroundColor Gray
        }
        $results['PATH'] = $true
    }
    else {
        Write-Host "      $Script:MsysBinDir does not exist - PATH left alone." -ForegroundColor Yellow
        $results['PATH'] = $false
    }

    $codeCli = Get-VSCodeCli
    if ($codeCli) {
        # ms-vscode.cpptools is the extension id the guide names.
        & $codeCli --install-extension ms-vscode.cpptools --force 2>&1 | ForEach-Object {
            Write-Host "      $_" -ForegroundColor DarkGray
        }
        $results['C/C++ extension'] = ($LASTEXITCODE -eq 0)
    }
    else {
        Write-Host "      code.cmd not found - skipping the extension." -ForegroundColor Yellow
        $results['C/C++ extension'] = $false
    }

    # --- What actually ended up on the machine ---
    Write-Host "`n[C++ Results]" -ForegroundColor Cyan
    foreach ($k in $results.Keys) {
        if ($results[$k]) { Write-Host ("   {0} {1}" -f $Script:Glyph.Ok,   $k) -ForegroundColor Green }
        else              { Write-Host ("   {0} {1}" -f $Script:Glyph.Fail, $k) -ForegroundColor Red }
    }

    # The guide ends by having you run these in a *new* terminal, so they are run
    # here from the toolchain folder directly - the point is to prove the
    # compiler is really on disk, not that this console's PATH caught up.
    Write-Host "`n[Compiler check]" -ForegroundColor Cyan
    foreach ($exe in @('gcc', 'g++', 'gdb')) {
        $full = Join-Path $Script:MsysBinDir "$exe.exe"
        if (Test-Path -LiteralPath $full) {
            $line = try { (& $full --version 2>&1 | Select-Object -First 1) } catch { "could not be run" }
            Write-Host ("   {0} {1}" -f $Script:Glyph.Ok, $line) -ForegroundColor Green
        }
        else {
            Write-Host ("   {0} {1} not found in {2}" -f $Script:Glyph.Fail, $exe, $Script:MsysBinDir) -ForegroundColor Red
        }
    }
    Write-Host "`n   Open a NEW terminal before using gcc - PATH changes do not" -ForegroundColor DarkGray
    Write-Host "   reach terminals that were already running." -ForegroundColor DarkGray
}

function Get-DcuCli {
    # dcu-cli.exe, wherever the installer put it. The classic build lands under
    # Program Files (x86) and the Universal one under Program Files, and which
    # you get depends on the model - so both are checked rather than assumed.
    foreach ($p in @("$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe",
                     "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe")) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Get-DcuResultText {
    # dcu-cli's documented exit codes. Reading them is the whole difference
    # between "no updates were needed" and "it failed" - both leave the machine
    # unchanged, and only the number says which happened.
    param([int]$Code)
    switch ($Code) {
        0   { return @{ Ok = $true;  Text = "completed" } }
        1   { return @{ Ok = $true;  Text = "completed - a reboot is required" } }
        5   { return @{ Ok = $true;  Text = "a reboot was already pending before this ran" } }
        500 { return @{ Ok = $true;  Text = "no updates found - drivers are already current" } }
        2   { return @{ Ok = $false; Text = "unknown application error" } }
        default { return @{ Ok = $false; Text = "exit code $Code" } }
    }
}

# Dell Command Update is a WPF application. Without the .NET Desktop Runtime its
# installer stops partway and leaves nothing behind, so the runtime is a
# prerequisite rather than a nicety. 10.0.8 is the floor; winget installs the
# current 10.0.x, which is above it.
$Script:DotNetDesktopMin = [version]"10.0.8"

function Get-DotNetDesktopVersion {
    # Highest Microsoft.WindowsDesktop.App runtime installed, or $null.
    #
    # Read off the shared-framework folder rather than asking
    # "dotnet --list-runtimes": that needs the dotnet host on PATH, and a machine
    # that has the runtime but never had the SDK usually does not have it there -
    # which would report "missing" on a machine that is fine.
    $root = Join-Path $env:ProgramFiles "dotnet\shared\Microsoft.WindowsDesktop.App"
    if (-not (Test-Path -LiteralPath $root)) { return $null }

    $best = $null
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        # Preview folders carry a suffix ("10.0.0-preview.3.12345.6"). A preview
        # does not count as the release it precedes, so they are skipped rather
        # than trimmed down to a number they have not earned.
        if ($dir.Name -match '-') { continue }
        $v = $null
        if ([version]::TryParse($dir.Name, [ref]$v)) {
            if ($null -eq $best -or $v -gt $best) { $best = $v }
        }
    }
    return $best
}

function Test-RebootPending {
    # Three places Windows records that the machine owes a restart. Any one is
    # enough. Checked up front because dcu-cli will not apply while a reboot is
    # pending - it returns 5, but only after running the whole scan first.
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { return $true }
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { return $true }
    $sm = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" `
                           -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($sm -and $sm.PendingFileRenameOperations) { return $true }
    return $false
}

function Read-DcuReport {
    # DCUApplicableUpdates.xml as dcu-cli writes it: an <updates> root holding
    # <update> elements carrying type / name / version / Urgency.
    #
    # Returns Ok=$false when the file is missing or will not parse. That is not
    # the same as "no updates found", and the caller must not let one read as
    # the other - an unreadable report would otherwise look like a clean machine.
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Ok = $false; Reason = "no report at $Path"; Updates = @() }
    }
    try {
        [xml]$doc = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        # The Where-Object is load-bearing. A report with no <update> children
        # gives $null here, and @($null) is an array of length one - without the
        # filter an empty report announces "1 update found" and then prints a
        # blank row.
        return @{ Ok = $true; Reason = ""; Updates = @($doc.updates.update | Where-Object { $_ }) }
    }
    catch {
        return @{ Ok = $false; Reason = $_.Exception.Message; Updates = @() }
    }
}

function Invoke-DellCommandUpdate {
    # Installs Dell Command Update if it is missing, scans for driver updates,
    # shows exactly what it found, and applies them only after that is confirmed
    # - without letting the machine restart itself.
    Write-Host "`n[DCU] Dell Command Update - driver updates" -ForegroundColor Magenta

    $work = "$env:TEMP\MiniApp\DCU"
    if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
    $reportXml = Join-Path $work "DCUApplicableUpdates.xml"
    $scanLog   = Join-Path $work "dcu-scan.log"
    $applyLog  = Join-Path $work "dcu-apply.log"
    # A report left from a previous run would be read as this run's result.
    Remove-Item $reportXml -Force -ErrorAction SilentlyContinue

    # --- 1. Pre-flight. Each condition reports on its own, so a refusal always
    #        names the one thing that stopped it. ---
    Write-Host "`n[1/5] Checking this machine..." -ForegroundColor Cyan

    $vendor = try { "$((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Manufacturer)".Trim() } catch { "" }
    if ($vendor -notmatch '(?i)dell') {
        Write-Host "      Manufacturer reads '$vendor' - DCU only serves Dell hardware." -ForegroundColor Yellow
        return
    }
    Write-Host "      Manufacturer: $vendor" -ForegroundColor DarkGray

    # Setup.ps1 elevates at the top of the file, so this cannot fail from the
    # menu. It is here for the case where this function is lifted out and run on
    # its own, which is how the Office remover already gets used.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                   [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "      Not running as Administrator - dcu-cli needs it." -ForegroundColor Yellow
        return
    }
    Write-Host "      Administrator: yes" -ForegroundColor DarkGray

    if (Test-RebootPending) {
        Write-Host "`n[STOP] This machine has a restart pending." -ForegroundColor Yellow
        Write-Host "       dcu-cli refuses to apply anything until that is done." -ForegroundColor DarkGray
        Write-Host "       Reboot, then run this tool again." -ForegroundColor DarkGray
        return
    }
    Write-Host "      Reboot pending: no" -ForegroundColor DarkGray

    # --- 2. .NET Desktop Runtime, before anything tries to install DCU ---
    Write-Host "`n[2/5] Checking the .NET Desktop Runtime..." -ForegroundColor Cyan
    $dotnet = Get-DotNetDesktopVersion
    $needRuntime = ($null -eq $dotnet -or $dotnet -lt $Script:DotNetDesktopMin)
    if ($needRuntime) {
        $have = if ($dotnet) { "$dotnet" } else { "none installed" }
        Write-Host "      Found $have, need $($Script:DotNetDesktopMin) or newer." -ForegroundColor Yellow
    }
    else {
        Write-Host "      Found $dotnet - meets the $($Script:DotNetDesktopMin) minimum." -ForegroundColor DarkGray
    }

    $dcu = Get-DcuCli
    $needDcu = ($null -eq $dcu)

    # winget is prepared once, and only when something is actually going to be
    # fetched - a machine with both prerequisites already in place should not pay
    # a version check, let alone a 207MB upgrade, to be told it needs nothing.
    if ($needRuntime -or $needDcu) {
        Write-Host "      winget: $(Get-WingetVersionText)" -ForegroundColor DarkGray
        if (-not (Test-WingetIsCurrent)) {
            # An out-of-date client is the usual cause of a failed winget install,
            # so it is brought current first rather than diagnosed afterwards.
            Write-Host "      Out of date or missing - updating it first (~207MB)..." -ForegroundColor Yellow
            Install-AppInstaller
            Write-Host "      winget now: $(Get-WingetVersionText)" -ForegroundColor Gray
        }
        if ($null -eq (Get-WingetVersion)) {
            Write-Host "`n[ERROR] Winget is unavailable, so the prerequisites cannot be installed." -ForegroundColor Red
            return
        }
    }

    if ($needRuntime) {
        Write-Host "      Installing .NET Desktop Runtime..." -ForegroundColor Cyan
        Invoke-WingetInstall -Id 'Microsoft.DotNet.DesktopRuntime.10' | Out-Null
        $dotnet = Get-DotNetDesktopVersion
        if ($null -eq $dotnet -or $dotnet -lt $Script:DotNetDesktopMin) {
            # Stopping here on purpose. Letting the DCU install run without it is
            # exactly the failure this step exists to prevent: its installer quits
            # partway and leaves nothing to show for the wait.
            $have = if ($dotnet) { "$dotnet" } else { "still nothing" }
            Write-Host "`n[ERROR] .NET Desktop Runtime is $have after the install." -ForegroundColor Red
            Write-Host "        DCU's installer stops without it, so nothing further was attempted." -ForegroundColor DarkGray
            return
        }
        Write-Host "      Now $dotnet." -ForegroundColor Gray
    }

    # --- 3. The tool itself ---
    if ($needDcu) {
        Write-Host "`n[3/5] Dell Command Update is not installed - fetching it..." -ForegroundColor Cyan
        Invoke-WingetInstall -Id 'Dell.CommandUpdate' | Out-Null
        $dcu = Get-DcuCli
    }
    else {
        Write-Host "`n[3/5] Dell Command Update is already installed." -ForegroundColor Cyan
    }
    if (-not $dcu) {
        Write-Host "`n[ERROR] dcu-cli.exe is still not on this machine." -ForegroundColor Red
        Write-Host "        Some models ship the Universal build - try installing" -ForegroundColor DarkGray
        Write-Host "        Dell.CommandUpdate.Universal by hand and run this again." -ForegroundColor DarkGray
        return
    }
    Write-Host "      $dcu" -ForegroundColor DarkGray

    # --- 4. Scan, drivers only, with both artefacts written to disk ---
    # Called with & rather than Start-Process so dcu-cli's own progress reaches
    # the console; a scan runs for minutes and a hidden window reads as a hang.
    Write-Host "`n[4/5] Scanning for driver updates..." -ForegroundColor Cyan
    & $dcu /scan -updateType=driver -silent -report="$work" -outputLog="$scanLog"
    $scanCode = $LASTEXITCODE
    $scan = Get-DcuResultText -Code $scanCode
    Write-Host ("      Scan: {0}" -f $scan.Text) -ForegroundColor DarkGray

    if ($scanCode -eq 500) {
        Write-Host "`n[OK] Nothing to install - drivers are already current." -ForegroundColor Green
        Write-Host "     Log: $scanLog" -ForegroundColor DarkGray
        return
    }
    if (-not $scan.Ok) {
        Write-Host "`n[ERROR] The scan failed - nothing was applied." -ForegroundColor Red
        Write-Host "        Log: $scanLog" -ForegroundColor DarkGray
        return
    }

    $report = Read-DcuReport -Path $reportXml
    if (-not $report.Ok) {
        # Deliberately not treated as "no updates": a report that cannot be read
        # says nothing about the machine, and calling that clean would be a lie.
        Write-Host "`n[ERROR] The scan report could not be read - $($report.Reason)" -ForegroundColor Red
        Write-Host "        Nothing was applied. Log: $scanLog" -ForegroundColor DarkGray
        return
    }
    if ($report.Updates.Count -eq 0) {
        Write-Host "`n[OK] The scan found no driver updates for this machine." -ForegroundColor Green
        Write-Host "     Report: $reportXml" -ForegroundColor DarkGray
        return
    }

    Write-Host ("`n  {0} update(s) found:" -f $report.Updates.Count) -ForegroundColor Yellow
    foreach ($u in ($report.Updates | Sort-Object { "$($_.type)" }, { "$($_.name)" })) {
        $urg = if ("$($u.Urgency)") { " · $($u.Urgency)" } else { "" }
        Write-Host ("    {0} [{1}] {2}  {3}{4}" -f $Script:Glyph.Run, "$($u.type)", "$($u.name)", "$($u.version)", $urg) -ForegroundColor Gray
    }

    # --- 5. Apply, only once that has been read and agreed to ---
    Write-Host "`n  Install these now? [y/N] " -NoNewline -ForegroundColor Yellow
    if ("$([System.Console]::ReadKey($false).KeyChar)" -notmatch '^[yY]$') {
        Write-Host "`n[Cancelled] Nothing was installed." -ForegroundColor Yellow
        Write-Host "            Report: $reportXml" -ForegroundColor DarkGray
        return
    }
    Write-Host "`n"

    Write-Host "[5/5] Applying driver updates. This takes a while." -ForegroundColor Cyan
    # -reboot=disable is the documented way to keep it from restarting.
    # -forceUpdate is deliberately NOT passed: it reinstalls drivers that are
    # already current. -updateType=driver keeps the apply as narrow as the scan;
    # adding ",bios,firmware" to both strings widens it.
    & $dcu /applyUpdates -updateType=driver -silent -reboot=disable -outputLog="$applyLog"
    $applyCode = $LASTEXITCODE
    $apply = Get-DcuResultText -Code $applyCode

    Write-Host "`n[DCU Results]" -ForegroundColor Cyan
    if ($apply.Ok) { Write-Host ("   {0} {1}" -f $Script:Glyph.Ok,   $apply.Text) -ForegroundColor Green }
    else           { Write-Host ("   {0} {1}" -f $Script:Glyph.Fail, $apply.Text) -ForegroundColor Red }
    Write-Host   ("   Exit code    : {0}" -f $applyCode) -ForegroundColor DarkGray
    Write-Host   ("   Reboot needed: {0}" -f $(if ($applyCode -eq 1 -or $applyCode -eq 5) { "YES" } else { "no" })) -ForegroundColor DarkGray
    Write-Host   ("   Report       : {0}" -f $reportXml) -ForegroundColor DarkGray
    Write-Host   ("   Scan log     : {0}" -f $scanLog) -ForegroundColor DarkGray
    Write-Host   ("   Apply log    : {0}" -f $applyLog) -ForegroundColor DarkGray
    Write-Host "`n   Nothing was restarted. Reboot when you are ready." -ForegroundColor DarkGray
}

# =========================================================================
# LENOVO DRIVER UPDATE (Lenovo.Client.Update)
# =========================================================================
# Built to docs/Lenovo-Global-driver.md, with one rule deliberately overridden.
#
# The spec puts LCU in the hands of an administrator: provisioned ahead of time
# from an approved source, never fetched by the running tool. That rule is
# written for a governed enterprise rollout. This is a bench tool for setting up
# one machine at a time, where nobody has pre-staged anything and the stop it
# produced was simply a dead end - so the module is installed from PSGallery
# when it is absent. The same file already takes ps2exe from PSGallery, so this
# is the risk posture the project was already running at, not a new one.
#
# What is NOT relaxed, because none of it depends on where the module came from:
#
#   * No -SkipSignature / -SkipSignatureCheck anywhere, on any cmdlet. They are
#     simply never passed, so verification stays on by default.
#   * PSGallery is never marked Trusted. Install-Module -Force gets past the
#     prompt for this one call instead of changing a machine-wide setting that
#     would outlive the run.
#   * Drivers only, filtered before anything is downloaded, and never a forced
#     -Model. A China-SKU machine is reported as unverified rather than served a
#     Global package.
$Script:LcuModule = 'Lenovo.Client.Update'

# What this tool holds back. Everything else Get-LnvUpdate returns is installed.
#
# The first version asked for Category -eq 'Driver' and skipped all twelve
# packages on a real machine, because LCU's Category is the *device* category the
# package belongs to - "Audio", "Chipset", "Networking: LAN (Ethernet)" - not the
# kind of update it is. Lenovo's own docs only ever use it to group by device,
# which is the clue that was there to be read.
#
# Get-LnvUpdate already returns nothing but needed and applicable packages, and
# on a client machine that is overwhelmingly drivers. So the test is inverted:
# name what is not a driver, install the rest. Kept deliberately narrow - wrongly
# excluding a real driver is the failure this replaces, so a word like "utility"
# that also appears in genuine driver titles is not on the list.
$Script:LnvExcluded = @(
    @{ Label = "BIOS/UEFI";   Pattern = '(?i)\b(bios|uefi)\b' },
    @{ Label = "firmware";    Pattern = '(?i)\bfirmware\b' },
    @{ Label = "application"; Pattern = '(?i)\b(vantage|application)\b' }
)

function Get-LnvField {
    # The first of several candidate property names that actually carries a
    # value, or "".
    #
    # Every field printed about a package used one hard-coded name taken from
    # Lenovo's docs, and on a real machine FileSize, IsApplicable, IsInstalled
    # and Installer.Unattended all came back empty - the module spells them
    # differently. Names are tried in turn, and anything still unknown is left
    # out of the line entirely rather than printed as "applicable=" with nothing
    # after it, which tells the reader less than saying nothing.
    param([object]$Object, [string[]]$Names)

    if ($null -eq $Object) { return "" }
    foreach ($n in $Names) {
        # Two routes, because dotted access with a variable name comes back empty
        # on some object shapes while the PSObject property table still has the
        # value. Cheap to try both; a whole feature has already been blocked by
        # one of them returning nothing.
        $value = $null
        try { $value = $Object.$n } catch { }
        if ($null -eq $value -or "$value" -eq "") {
            try { $value = $Object.psobject.Properties[$n].Value } catch { }
        }
        if ($null -ne $value -and "$value" -ne "") { return "$value" }
    }
    return ""
}

function Test-LnvUnattended {
    # $false only when the module says so outright.
    #
    # This read "-not $pkg.Installer.Unattended", and on a real machine it held
    # back all twelve packages: an absent property is $null, $null is falsy, and
    # every driver looked interactive. Same shape as the Category bug before it -
    # demanding a positive answer from a field that could not be verified from
    # here, so silence became a "no".
    #
    # Lenovo's driver packages are unattended as a rule, and the point of the
    # tool is to install them. So an unknown answer lets the package through and
    # only an explicit negative stops it. Several spellings are tried because
    # which one this module version uses is exactly what could not be confirmed.
    param([object]$Package)

    foreach ($name in 'Unattended', 'IsUnattended', 'SupportsUnattended', 'Silent') {
        $value = $null
        try { $value = $Package.Installer.$name } catch { }
        if ($null -eq $value) { continue }
        # A string "False" is $true once cast, so text is compared as text.
        if ($value -is [string]) { return ($value -notmatch '(?i)^(false|no|0)$') }
        return [bool]$value
    }
    return $true
}

function Get-LnvExclusionReason {
    # Why this package is not a driver update, or "" when it is one.
    #
    # A kind field is used when the module actually provides one carrying a
    # recognisable update type - but only ever to exclude, never to include.
    # Requiring it to say "Driver" is exactly what broke.
    param([object]$Package)

    foreach ($field in 'Type', 'PackageType') {
        $value = $null
        try { $value = "$($Package.$field)" } catch { }
        if ($value -match '(?i)^(bios|uefi)$')      { return "BIOS/UEFI" }
        if ($value -match '(?i)^firmware$')         { return "firmware" }
        if ($value -match '(?i)^(application|app)$'){ return "application" }
    }

    # Category and Title are both searched: dock and Management Engine firmware
    # sit under device categories like "Motherboard Devices" and only say
    # "Firmware" in the title.
    $hay = "$($Package.Category) $($Package.Title)"
    foreach ($x in $Script:LnvExcluded) {
        if ($hay -match $x.Pattern) { return $x.Label }
    }
    return ""
}

function Install-LenovoDriverPackage {
    # The system-changing half, split out so SupportsShouldProcess actually
    # guards the LCU calls instead of decorating a function that has already made
    # them. -WhatIf and -Confirm come from PowerShell; the spec forbids declaring
    # them by hand and forbids a -Force that would let anything past them.
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][object[]]$Package,
        [Parameter(Mandatory)][string]$CachePath
    )

    $ids = ($Package | ForEach-Object { "$($_.PackageID)" }) -join ', '
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME,
            "Install $($Package.Count) Lenovo driver package(s): $ids")) {
        return $null
    }

    # Downloaded first, and the download result is checked: installing a package
    # whose transfer failed would turn a clear download error into a confusing
    # install error.
    # Same reasoning as the scan: one package raising a non-terminating error
    # must not discard the results for the others. Their own Status field is what
    # says whether each one worked.
    $saveErr = $null
    $saved = @(Save-LnvUpdate -Package $Package -Path $CachePath -ShowProgress `
                              -ErrorVariable saveErr -ErrorAction SilentlyContinue)
    foreach ($e in @($saveErr)) {
        Write-Host ("   {0} download: {1}" -f $Script:Glyph.Fail, $e.Exception.Message) -ForegroundColor Red
    }
    $badSave = @($saved | Where-Object { "$($_.Status)" -eq 'Failed' })
    foreach ($b in $badSave) {
        Write-Host ("   {0} download failed: {1} - {2}" -f $Script:Glyph.Fail, $b.PackageID, $b.Message) -ForegroundColor Red
    }
    # Installing a package whose transfer failed turns a clear download error
    # into a confusing install error, so nothing proceeds unless everything
    # asked for actually arrived.
    if ($badSave.Count -gt 0 -or $saved.Count -lt $Package.Count) {
        Write-Host ("   {0} {1} of {2} package(s) downloaded - not installing." -f
            $Script:Glyph.Fail, ($saved.Count - $badSave.Count), $Package.Count) -ForegroundColor Red
        return $null
    }

    $instErr = $null
    $results = @(Install-LnvUpdate -Package $Package -Path $CachePath -ExportToWMI `
                                   -ErrorVariable instErr -ErrorAction SilentlyContinue)
    foreach ($e in @($instErr)) {
        Write-Host ("   {0} install: {1}" -f $Script:Glyph.Fail, $e.Exception.Message) -ForegroundColor Red
    }
    return $results
}

function Invoke-LenovoDriverUpdate {
    # Scan first, always. Installing is a second, confirmed step over the list
    # produced in this same run - never a list carried over from an earlier scan.
    Write-Host "`n[Lenovo] Driver update via Lenovo.Client.Update" -ForegroundColor Magenta

    $work  = "$env:TEMP\MiniApp\Lenovo"
    $cache = Join-Path $work "cache"
    $log   = Join-Path $work "lcu-scan.log"
    foreach ($d in @($work, $cache)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

    # --- Preflight. Every failure names the one condition that stopped it, and
    #     nothing is downloaded or executed until all of them pass. ---
    Write-Host "`n[1/4] Preflight..." -ForegroundColor Cyan

    $cs   = try { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { $null }
    $prod = try { Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop } catch { $null }
    $vendor  = "$($cs.Manufacturer)".Trim()
    $family  = "$($prod.Version)".Trim()      # e.g. "ThinkPad X1 Carbon Gen 11"
    $mtm     = "$($cs.Model)".Trim()          # machine type, e.g. "21HM"
    $serial  = try { "$((Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber)".Trim() } catch { "" }

    if ($vendor -notmatch '(?i)lenovo') {
        Write-Host "      Manufacturer reads '$vendor' - not a Lenovo machine." -ForegroundColor Yellow
        return
    }
    # Commercial lines only. The spec puts consumer Lenovo out of scope, and LCU
    # is published for the commercial range.
    if ($family -notmatch '(?i)think(pad|centre|center|station)') {
        Write-Host "      Model reads '$family' - not a ThinkPad/ThinkCentre/ThinkStation." -ForegroundColor Yellow
        Write-Host "      Consumer Lenovo models are out of scope for this tool." -ForegroundColor DarkGray
        return
    }
    Write-Host "      Machine : $family  ($mtm)" -ForegroundColor DarkGray
    if ($serial) { Write-Host "      Serial  : $serial" -ForegroundColor DarkGray }

    if ([Environment]::OSVersion.Version.Major -lt 10) {
        Write-Host "      Windows 10 or 11 is required." -ForegroundColor Yellow
        return
    }
    if ($PSVersionTable.PSVersion -lt [version]"5.0") {
        Write-Host "      PowerShell 5.0 or newer is required (this is $($PSVersionTable.PSVersion))." -ForegroundColor Yellow
        return
    }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                   [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "      Not running as Administrator." -ForegroundColor Yellow
        return
    }
    Write-Host "      Platform: Windows $([Environment]::OSVersion.Version) · PowerShell $($PSVersionTable.PSVersion) · elevated" -ForegroundColor DarkGray

    if (Test-RebootPending) {
        Write-Host "`n[STOP] This machine has a restart pending - finish that first." -ForegroundColor Yellow
        return
    }

    $lcu = Get-Module -ListAvailable -Name $Script:LcuModule -ErrorAction SilentlyContinue |
           Sort-Object Version -Descending | Select-Object -First 1
    if (-not $lcu) {
        Write-Host "      $($Script:LcuModule) is not installed - fetching it from PSGallery..." -ForegroundColor Yellow
        try {
            if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
            }
            # -Force clears the untrusted-repository prompt for this call only.
            # Set-PSRepository -InstallationPolicy Trusted would do the same job
            # by changing a machine-wide setting that outlives the run, which is
            # the one part of the provisioning rule worth keeping.
            Install-Module -Name $Script:LcuModule -Scope CurrentUser -Force -ErrorAction Stop
        }
        catch {
            Write-Host "`n[STOP] Could not install $($Script:LcuModule)." -ForegroundColor Red
            Write-Host "       $($_.Exception.Message)" -ForegroundColor DarkGray
            Write-Host "       Install it by hand, then run this again:" -ForegroundColor DarkGray
            Write-Host "         Install-Module -Name $($Script:LcuModule) -Scope CurrentUser" -ForegroundColor DarkGray
            return
        }
        $lcu = Get-Module -ListAvailable -Name $Script:LcuModule -ErrorAction SilentlyContinue |
               Sort-Object Version -Descending | Select-Object -First 1
    }
    if (-not $lcu) {
        Write-Host "`n[STOP] $($Script:LcuModule) is still not available after the install." -ForegroundColor Red
        return
    }
    try { Import-Module $Script:LcuModule -ErrorAction Stop }
    catch {
        Write-Host "`n[STOP] $($Script:LcuModule) $($lcu.Version) could not be imported." -ForegroundColor Yellow
        Write-Host "       $($_.Exception.Message)" -ForegroundColor DarkGray
        return
    }
    Write-Host "      LCU     : $($Script:LcuModule) $($lcu.Version)" -ForegroundColor DarkGray

    $freeGb = try { [math]::Round((Get-Volume -DriveLetter ($cache.Substring(0,1)) -ErrorAction Stop).SizeRemaining / 1GB, 1) } catch { $null }
    if ($null -ne $freeGb -and $freeGb -lt 2) {
        Write-Host "      Only ${freeGb}GB free on the cache drive - need room for downloads." -ForegroundColor Yellow
        return
    }
    Write-Host "      Cache   : $cache$(if ($null -ne $freeGb) { "  (${freeGb}GB free)" })" -ForegroundColor DarkGray

    # --- Scan. No -All: the default already returns only what is needed and
    #     applicable, and -All would drag in installed and non-applicable
    #     packages that must never reach the install list. No -Model either -
    #     forcing one is how a China-SKU machine ends up with a Global package.
    Write-Host "`n[2/4] Scanning (this uses the network and can take a while)..." -ForegroundColor Cyan

    # -ErrorAction Stop was wrong here and is what made this step give up. LCU
    # evaluates every package in the catalogue against the machine, and one that
    # cannot be resolved or signature-checked raises a NON-terminating error -
    # which Stop promoted into an exception, throwing away every result already
    # gathered. Errors are collected instead and weighed against what came back.
    $all     = @()
    $scanErr = $null
    $fatal   = $null
    try {
        $all = @(Get-LnvUpdate -LogPath $log -ErrorVariable scanErr -ErrorAction SilentlyContinue)
    }
    catch {
        # The log is a nicety; the scan is the point. If writing it is what broke,
        # the scan is worth one more try without it.
        Write-Host "      Scan with logging failed - retrying without a log file..." -ForegroundColor Yellow
        Write-Host "      ($($_.Exception.Message))" -ForegroundColor DarkGray
        try { $all = @(Get-LnvUpdate -ErrorVariable scanErr -ErrorAction SilentlyContinue) }
        catch { $fatal = $_ }
    }

    # A run on a real machine came back with twelve System.String values instead
    # of package objects - the module had echoed its log to the output stream
    # because -LogPath was passed. Strings cannot be filtered on Category, and
    # Save-LnvUpdate -Package would reject them, so the whole run was quietly
    # working on text. Detected here and retried without the log, since the
    # packages matter and the log does not.
    if ($all.Count -gt 0 -and ($all | Where-Object { $_ -isnot [string] }).Count -eq 0) {
        Write-Host "      The scan returned text, not packages - retrying without -LogPath..." -ForegroundColor Yellow
        # Printed here, on the screen already being watched, rather than left in
        # a file to be fetched. Knowing that text came back says nothing; knowing
        # what it says is the whole diagnosis, and the last round cost a run
        # because the dump recorded a length and not a single character of it.
        Write-Host "      What came back:" -ForegroundColor DarkGray
        foreach ($t in @($all | Select-Object -First 3)) { Write-Host "        | $t" -ForegroundColor DarkGray }
        $withLog = $all

        try { $all = @(Get-LnvUpdate -ErrorVariable scanErr -ErrorAction SilentlyContinue) }
        catch { $fatal = $_ }

        # Say what the retry actually achieved. "Retrying" on its own leaves the
        # next question unanswered, which is how this took another round.
        $retryType = if ($all.Count -gt 0) { try { $all[0].GetType().Name } catch { "?" } } else { "nothing" }
        Write-Host ("      Retry returned {0} item(s), type {1}." -f $all.Count, $retryType) -ForegroundColor DarkGray

        # A retry that returns nothing is worse than the text: the run would go
        # on to announce a machine with no updates, when the logged attempt had
        # just found twelve. The text is kept so the stop below can show it.
        if ($all.Count -eq 0) {
            Write-Host "      Retry found nothing - keeping the first result so it can be shown." -ForegroundColor Yellow
            $all = $withLog
        }
    }

    if ($fatal) {
        Write-Host "`n[ERROR] The scan could not run at all." -ForegroundColor Red
        Write-Host "        $($fatal.Exception.Message)" -ForegroundColor DarkGray
        Write-Host "        Log: $log" -ForegroundColor DarkGray
        return
    }

    # Grumbles on the way do not undo a scan that returned packages, so they are
    # shown and stepped over. Printed in full because a one-line mystery is what
    # made the old failure impossible to act on.
    $errCount = @($scanErr).Count
    if ($errCount -gt 0) {
        Write-Host "      $errCount non-fatal issue(s) during the scan:" -ForegroundColor Yellow
        foreach ($e in @($scanErr | Select-Object -First 5)) {
            Write-Host "        $($e.Exception.Message)" -ForegroundColor DarkGray
        }
        if ($errCount -gt 5) { Write-Host "        ...and $($errCount - 5) more - see $log" -ForegroundColor DarkGray }
    }

    if ($all.Count -eq 0) {
        # Nothing back AND complaints is a failed scan, not a clean machine.
        # Calling it clean is the kind of quiet wrong answer that gets a laptop
        # handed over with stale drivers.
        if ($errCount -gt 0) {
            Write-Host "`n[ERROR] The scan returned nothing and reported errors - that is a failure," -ForegroundColor Red
            Write-Host "        not a machine with nothing to update." -ForegroundColor DarkGray
            Write-Host "        Log: $log" -ForegroundColor DarkGray
            return
        }
        Write-Host "`n[OK] The scan found no applicable updates for this machine." -ForegroundColor Green
        Write-Host "     Log: $log" -ForegroundColor DarkGray
        return
    }
    Write-Host "      $($all.Count) applicable package(s) returned." -ForegroundColor DarkGray

    # --- Filter, before anything is downloaded. BIOS, firmware and applications
    #     do not pass here even when they arrived in the same scan result. ---
    Write-Host "`n[3/4] Holding back BIOS, firmware and applications..." -ForegroundColor Cyan

    # Every wrong turn this tool has taken was a guess about this object made
    # from Lenovo's documentation - Category holding device names, Unattended not
    # being there, and then no readable property at all. So the first package is
    # written out in full, type and every value, to a file that can just be sent
    # on. Guessing from docs has been tried and does not work.
    $shapeFile = Join-Path $work "package-shape.txt"
    if ($all.Count -gt 0) {
        $typeName = try { $all[0].GetType().FullName } catch { "(type unreadable)" }
        $pkgProps = try {
            (($all[0] | Get-Member -MemberType Properties -ErrorAction Stop).Name) -join ', '
        } catch { "(none readable)" }
        Write-Host "      Object type : $typeName" -ForegroundColor DarkGray
        Write-Host "      Properties  : $pkgProps" -ForegroundColor DarkGray
        try {
            $dump = @()
            $dump += "Type: $typeName"
            $dump += "Count: $($all.Count)"
            $dump += "Properties: $pkgProps"
            $dump += ""
            # The raw values come first. Format-List on a String prints only its
            # Length, which is exactly what happened on the run that mattered -
            # the dump reported "System.String, Length 75" and never showed what
            # those 75 characters said.
            $dump += "--- first 5 items, as text ---"
            foreach ($item in @($all | Select-Object -First 5)) { $dump += "  $item" }
            $dump += ""
            $dump += "--- first item, every property ---"
            $dump += ($all[0] | Format-List * -Force | Out-String)
            $dump += "--- its Installer ---"
            $dump += ($all[0].Installer | Format-List * -Force | Out-String)
            $dump | Set-Content -LiteralPath $shapeFile -Encoding UTF8 -ErrorAction Stop
            Write-Host "      Full shape  : $shapeFile" -ForegroundColor Yellow
        }
        catch { }
    }

    # If they are still text after the retry, nothing below can mean anything:
    # a string has no Category to filter on and Save-LnvUpdate would reject it.
    # Stopping here is honest; carrying on would produce a confident list of
    # log lines and offer to install them.
    # The Count guard is not decoration: an empty array also has zero non-string
    # items, so without it a machine with nothing to update would be reported as
    # having returned text. An earlier return already covers the empty case, but
    # a check that only holds because of something forty lines above is one edit
    # away from being wrong.
    if ($all.Count -gt 0 -and ($all | Where-Object { $_ -isnot [string] }).Count -eq 0) {
        Write-Host "`n[ERROR] The scan returned text rather than update packages." -ForegroundColor Red
        Write-Host "        Nothing can be filtered or installed from that, so this stops here." -ForegroundColor DarkGray
        Write-Host "        First few lines:" -ForegroundColor DarkGray
        foreach ($t in @($all | Select-Object -First 3)) { Write-Host "          $t" -ForegroundColor DarkGray }
        Write-Host "        Full output: $shapeFile" -ForegroundColor Yellow
        return
    }

    $drivers = @()
    $skipped = @()
    foreach ($pkg in $all) {
        $reason = Get-LnvExclusionReason -Package $pkg
        if ($reason) {
            $skipped += @{ Pkg = $pkg; Why = $reason }
            continue
        }
        # An interactive installer waits for input nobody is there to give and
        # hangs the run - but only a package that actually says it is interactive
        # is held back. See Test-LnvUnattended for why silence is not a "no".
        if (-not (Test-LnvUnattended -Package $pkg)) {
            $skipped += @{ Pkg = $pkg; Why = "installer reports it is not unattended" }
            continue
        }
        $drivers += $pkg
    }

    if ($skipped.Count -gt 0) {
        Write-Host "`n  Held back ($($skipped.Count)):" -ForegroundColor DarkGray
        foreach ($sk in $skipped) {
            Write-Host ("    {0} {1}  [{2}]  - {3}" -f $Script:Glyph.Skip,
                "$($sk.Pkg.Title)", "$($sk.Pkg.Category)", $sk.Why) -ForegroundColor DarkGray
        }
    }

    if ($drivers.Count -eq 0) {
        # Everything filtered out when the scan did find packages is worth
        # spelling out. Reporting it as "nothing needed" is how twelve pending
        # driver updates went quietly uninstalled once already.
        Write-Host "`n[NOTHING TO DO] The scan returned $($all.Count) package(s) and all of them" -ForegroundColor Yellow
        Write-Host "                were held back. Categories seen:" -ForegroundColor Yellow
        foreach ($grp in ($all | Group-Object { "$($_.Category)" } | Sort-Object Name)) {
            Write-Host ("                  {0} x{1}" -f $grp.Name, $grp.Count) -ForegroundColor DarkGray
        }
        Write-Host "                Log: $log" -ForegroundColor DarkGray
        return
    }

    Write-Host "`n  Driver updates found ($($drivers.Count)):" -ForegroundColor Yellow
    foreach ($d in $drivers) {
        # A row must never come out blank. If none of the likely names carry a
        # title, whatever the object renders as is better than an empty line -
        # and a placeholder is better than nothing at all.
        $title = Get-LnvField $d @('Title', 'Name', 'PackageName', 'DisplayName', 'Description')
        if (-not $title) { $title = "$d" }
        if (-not $title -or $title -eq 'System.Object') { $title = "(package $($drivers.IndexOf($d) + 1) - name not readable)" }
        Write-Host ("    {0} {1}" -f $Script:Glyph.Run, $title) -ForegroundColor Gray

        # Built from what is there rather than a fixed format string, so a
        # property this module spells differently costs one field instead of
        # leaving a row of "name=" with nothing after each one.
        $bits = @()
        $id  = Get-LnvField $d @('PackageID', 'ID', 'PackageId')
        if ($id)  { $bits += $id }
        $ver = Get-LnvField $d @('Version', 'PackageVersion')
        if ($ver) { $bits += "v$ver" }
        $rel = Get-LnvField $d @('ReleaseDate', 'Date')
        if ($rel) { $bits += $rel }
        $sev = Get-LnvField $d @('Severity', 'Urgency')
        if ($sev) { $bits += $sev }

        $raw = Get-LnvField $d @('FileSize', 'Size', 'TotalSize')
        $bytes = 0
        if ($raw -and [double]::TryParse($raw, [ref]$bytes) -and $bytes -gt 0) {
            $bits += ("{0:N1} MB" -f ($bytes / 1MB))
        }

        # Shown when the module provides it because it is what settles whether
        # this tool updates outdated drivers or only installs missing ones: a
        # Lenovo package is a specific version, so an older driver on the machine
        # still counts as not installed.
        $inst = Get-LnvField $d @('IsInstalled', 'Installed')
        if ($inst) { $bits += "installed=$inst" }

        if ($bits.Count -gt 0) {
            Write-Host ("      " + ($bits -join " · ")) -ForegroundColor DarkGray
        }
    }

    # --- Install. ShouldProcess owns the confirmation; nothing reaches
    #     Save-LnvUpdate or Install-LnvUpdate without passing it. ---
    Write-Host "`n[4/4] Installing..." -ForegroundColor Cyan
    $results = $null
    try { $results = Install-LenovoDriverPackage -Package $drivers -CachePath $cache }
    catch {
        Write-Host "`n[FAILED] $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "         Log: $log" -ForegroundColor DarkGray
        return
    }

    if ($null -eq $results) {
        Write-Host "`n[NOT PERFORMED] Nothing was downloaded or installed." -ForegroundColor Yellow
        Write-Host "                Log: $log" -ForegroundColor DarkGray
        return
    }

    # --- Per-package results. Every exit code is kept rather than replaced by
    #     one summary line. ---
    Write-Host "`n[Lenovo Results]" -ForegroundColor Cyan
    $failed = 0
    $action = @()
    foreach ($r in $results) {
        $ok = ("$($r.Status)" -match '(?i)success')
        if (-not $ok) { $failed++ }
        $glyph = if ($ok) { $Script:Glyph.Ok } else { $Script:Glyph.Fail }
        $color = if ($ok) { "Green" } else { "Red" }
        Write-Host ("   {0} {1}" -f $glyph, "$($r.Title)") -ForegroundColor $color
        Write-Host ("      {0} · status={1} · exit={2} · {3}s" -f
            "$($r.PackageID)", "$($r.Status)", "$($r.ExitCode)", "$($r.Duration)") -ForegroundColor DarkGray
        if ("$($r.Message)") { Write-Host ("      {0}" -f "$($r.Message)") -ForegroundColor DarkGray }
        if ("$($r.ActionNeeded)" -and "$($r.ActionNeeded)" -notmatch '(?i)^(none|false|0)$') {
            $action += "$($r.Title): $($r.ActionNeeded)"
        }
    }

    # --- Outcome, in the four states the spec defines. ---
    Write-Host ""
    if ($failed -gt 0) {
        Write-Host "[FAILED] $failed of $($results.Count) package(s) did not install." -ForegroundColor Red
    }
    elseif ($action.Count -gt 0) {
        Write-Host "[SUCCESS - ACTION NEEDED] All packages installed." -ForegroundColor Yellow
        foreach ($a in $action) { Write-Host "   $a" -ForegroundColor Yellow }
    }
    else {
        Write-Host "[SUCCESS] All packages installed." -ForegroundColor Green
    }

    Write-Host "`n   Scan log : $log" -ForegroundColor DarkGray
    Write-Host   "   Cache    : $cache" -ForegroundColor DarkGray
    Write-Host   "   History  : root\Lenovo\Lenovo_Updates (exported to WMI)" -ForegroundColor DarkGray
    # Nothing here restarts anything. A driver can also make another driver newly
    # applicable, so a second scan is worth suggesting - and only suggesting.
    Write-Host "`n   Nothing was restarted. After any restart above, run this again -" -ForegroundColor DarkGray
    Write-Host   "   installing one driver can make another become applicable." -ForegroundColor DarkGray
}

# The OEM antivirus trials this tool knows to look for. Matched against the
# DisplayName shown in Programs and Features, so one pattern covers a vendor's
# several SKUs - LiveSafe, Total Protection, Security Scan, 360 - instead of
# needing a row each. Adding a vendor is one line.
$AntivirusTrials = @(
    @{ Vendor = "McAfee"; Match = 'McAfee' },
    @{ Vendor = "Norton"; Match = 'Norton' }
)

function Get-UninstallEntry {
    # Programs-and-Features entries whose DisplayName matches, across the same
    # three hives Test-IsInstalled already scans: 64-bit, 32-bit-on-64-bit, and
    # per-user. DisplayName is what the technician reads on screen, so it is
    # what gets matched and what gets reported back.
    param([string]$Pattern)

    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    return @(Get-ItemProperty -Path $roots -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -match $Pattern } |
             Sort-Object DisplayName -Unique)
}

function Remove-UninstallEntry {
    # Drives one Programs-and-Features entry. Three cases, in the order they can
    # be trusted:
    #
    #   QuietUninstallString  the vendor's own silent command. It exists because
    #                         the vendor published it, so it is used verbatim.
    #   MsiExec /I{GUID}      rewritten to /X{GUID} /qn /norestart - the same
    #                         operation, stated the silent way. Safe because MSI
    #                         switches are the installer platform's, not a
    #                         vendor's invention.
    #   anything else         a vendor EXE with no silent contract. Its switches
    #                         are NOT guessed: Norton's is "InstStub.exe /X /ARP"
    #                         and nothing silent is documented for it. It runs
    #                         with its window shown and the technician clicks
    #                         through - slower, but it cannot quietly do the
    #                         wrong thing to somebody's paid licence.
    #
    # Returns a result object rather than printing, so the caller owns the
    # report and the summary can count what actually happened.
    param([object]$Entry)

    $name = "$($Entry.DisplayName)"
    $quiet = "$($Entry.QuietUninstallString)".Trim()
    $plain = "$($Entry.UninstallString)".Trim()
    $cmd = if ($quiet) { $quiet } else { $plain }
    if (-not $cmd) {
        return @{ Name = $name; Ok = $false; Mode = "no uninstall command"; Code = $null }
    }

    $mode = "silent"
    $file = ""
    $argline = ""

    if (-not $quiet -and $cmd -match '(?i)msiexec') {
        # The GUID is the product; /I and /X differ only in direction.
        if ($cmd -match '(\{[0-9A-Fa-f-]{36}\})') {
            $file = "msiexec.exe"
            $argline = "/X$($Matches[1]) /qn /norestart"
        }
    }
    if (-not $file) {
        if     ($cmd -match '^\s*"([^"]+)"\s*(.*)$') { $file = $Matches[1]; $argline = $Matches[2].Trim() }
        elseif ($cmd -match '^\s*(.+?\.exe)\s*(.*)$') { $file = $Matches[1]; $argline = $Matches[2].Trim() }
        else   { $file = $cmd; $argline = "" }
        if (-not $quiet) { $mode = "interactive - click through its window" }
    }

    try {
        # -WindowStyle Hidden even for the silent path: -NoNewWindow hands back a
        # process whose ExitCode reads null after it has exited.
        $style = if ($mode -eq 'silent') { 'Hidden' } else { 'Normal' }
        $proc = if ($argline) {
            Start-Process -FilePath $file -ArgumentList $argline -Wait -PassThru -WindowStyle $style -ErrorAction Stop
        } else {
            Start-Process -FilePath $file -Wait -PassThru -WindowStyle $style -ErrorAction Stop
        }
        $code = try { $proc.ExitCode } catch { $null }
        # 3010 is "done, needs a reboot" - a success, not a fault.
        $ok = ($null -eq $code -or $code -eq 0 -or $code -eq 3010)
        return @{ Name = $name; Ok = $ok; Mode = $mode; Code = $code }
    }
    catch {
        return @{ Name = $name; Ok = $false; Mode = $_.Exception.Message; Code = $null }
    }
}

function Remove-AntivirusAppx {
    # The Store-app variant. "McAfee Personal Security" ships this way on most
    # new consumer machines and never shows up in Programs and Features at all,
    # so the registry sweep above would report a clean machine while the tile is
    # still on the Start menu.
    #
    # Removed for every account, then de-provisioned as well - without the
    # second step a newly created account gets it back at first sign-in.
    param([string]$Pattern)

    $results = @()
    foreach ($pkg in @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match $Pattern })) {
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            $results += @{ Name = "$($pkg.Name) (Store app)"; Ok = $true;  Mode = "removed for all users"; Code = 0 }
        }
        catch {
            $results += @{ Name = "$($pkg.Name) (Store app)"; Ok = $false; Mode = $_.Exception.Message; Code = $null }
        }
    }
    foreach ($prov in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                        Where-Object { $_.DisplayName -match $Pattern })) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            $results += @{ Name = "$($prov.DisplayName) (provisioned)"; Ok = $true;  Mode = "de-provisioned"; Code = 0 }
        }
        catch {
            $results += @{ Name = "$($prov.DisplayName) (provisioned)"; Ok = $false; Mode = $_.Exception.Message; Code = $null }
        }
    }
    return $results
}

function Invoke-RemoveAntivirusTrial {
    # Scans, shows exactly what it found, then asks. The listing is the safety
    # here rather than the y/N on its own: "Norton" and "McAfee" are broad
    # patterns, and a technician who can read the matched names before answering
    # cannot be surprised by what goes.
    Write-Host "`n[AV] Remove pre-installed antivirus trials" -ForegroundColor Magenta
    Write-Host "     Scanning Programs and Features and the Store apps..." -ForegroundColor DarkGray

    $found = @()
    foreach ($t in $AntivirusTrials) {
        foreach ($e in (Get-UninstallEntry -Pattern $t.Match)) {
            $found += @{ Vendor = $t.Vendor; Entry = $e; Kind = 'app' }
        }
        foreach ($pkg in @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                           Where-Object { $_.Name -match $t.Match })) {
            $found += @{ Vendor = $t.Vendor; Entry = $pkg; Kind = 'appx' }
        }
    }

    if ($found.Count -eq 0) {
        Write-Host "`n[OK] Nothing to remove - no McAfee or Norton products on this machine." -ForegroundColor Green
        return
    }

    Write-Host "`n  Found:" -ForegroundColor Yellow
    foreach ($f in $found) {
        $label = if ($f.Kind -eq 'appx') { "$($f.Entry.Name)  (Store app)" } else { "$($f.Entry.DisplayName)" }
        Write-Host ("    {0} {1}" -f $Script:Glyph.Run, $label) -ForegroundColor Gray
    }
    Write-Host "`n  Remove all of the above? [y/N] " -NoNewline -ForegroundColor Yellow
    if ("$([System.Console]::ReadKey($false).KeyChar)" -notmatch '^[yY]$') {
        Write-Host "`n[Cancelled] Nothing was removed." -ForegroundColor Yellow
        return
    }
    Write-Host ""

    $results = @()
    foreach ($t in $AntivirusTrials) {
        # Store apps first: they hold no services and go quickly, so the slow
        # part of the run is not sitting behind them.
        $results += Remove-AntivirusAppx -Pattern $t.Match
        foreach ($e in (Get-UninstallEntry -Pattern $t.Match)) {
            Write-Host "   [+] $($e.DisplayName)..." -ForegroundColor Gray
            $results += Remove-UninstallEntry -Entry $e
        }
    }

    Write-Host "`n[Antivirus Results]" -ForegroundColor Cyan
    foreach ($r in $results) {
        if ($r.Ok) {
            Write-Host ("   {0} {1}  [{2}]" -f $Script:Glyph.Ok, $r.Name, $r.Mode) -ForegroundColor Green
        }
        else {
            $code = if ($null -ne $r.Code) { " exit $($r.Code)" } else { "" }
            Write-Host ("   {0} {1}  [{2}]{3}" -f $Script:Glyph.Fail, $r.Name, $r.Mode, $code) -ForegroundColor Red
        }
    }

    if (@($results | Where-Object { -not $_.Ok }).Count -gt 0) {
        # Not a fallback that runs itself: these are large vendor tools that
        # reboot the machine, and that is the technician's call to make.
        Write-Host "`n   Anything left over needs the vendor's own remover:" -ForegroundColor Yellow
        Write-Host "     McAfee  MCPR   https://www.mcafee.com/support/?articleId=TS101331" -ForegroundColor DarkGray
        Write-Host "     Norton  NRnR   https://support.norton.com/sp/en/us/home/current/solutions/v60392881" -ForegroundColor DarkGray
    }
    Write-Host "`n[OK] Antivirus removal finished. A reboot is usually needed." -ForegroundColor Green
}

# Everything the CLI-TOOL window offers. Adding one is a line here plus a case
# in the switch inside Invoke-CliTools - the numbering, the Back slot and the
# arrow-key wrapping all size themselves off this table.
# Update Winget is deliberately not listed. The install engine now refreshes
# winget in the background on menu 1 and 2, so offering it here as well would
# have a technician doing by hand what the install run already did. The tool
# itself is kept below and is one line away from coming back:
#     @{ Label = "Update Winget"; Desc = "..."; Action = "Winget" },
$CliTools = @(
    @{ Label = "Environment for C++"; Desc = "VS Code + MinGW-w64 toolchain + C/C++ extension";     Action = "Cpp"          },
    @{ Label = "Remove Office";       Desc = "Force-remove Office 2016-2024 and Microsoft 365";     Action = "RemoveOffice" },
    @{ Label = "Remove Antivirus Trial"; Desc = "Uninstall pre-installed McAfee and Norton trials";  Action = "RemoveAv"     },
    @{ Label = "Dell Command Update"; Desc = "Install DCU, then update drivers without rebooting";    Action = "Dcu"          },
    @{ Label = "Lenovo - CLI - Driver Update"; Desc = "ThinkPad/Centre/Station drivers via Lenovo.Client.Update"; Action = "Lenovo" }
)

function Read-CliToolChoice {
    # An index into $CliTools, or -1 for Back. Same navigation as the main menu
    # so there is nothing to learn twice.
    $selected = 0
    $count = $CliTools.Count

    while ($true) {
        Clear-Host
        Write-BoxTop
        Write-BoxCenter "CLI TOOLS" "White"
        Write-BoxSep
        Write-BoxLine "  Standalone utilities. Each one runs here in this window." "DarkGray"
        Write-BoxBottom
        Write-Host ""

        for ($i = 0; $i -lt $count; $i++) {
            $num = $i + 1
            if ($i -eq $selected) {
                Write-Host ("  {0} {1}. {2}" -f $Script:Glyph.Run, $num, $CliTools[$i].Label.PadRight(34)) -ForegroundColor Black -BackgroundColor Cyan
                Write-Host ("       {0}" -f $CliTools[$i].Desc) -ForegroundColor DarkGray
            }
            else {
                Write-Host ("    {0}. {1}" -f $num, $CliTools[$i].Label) -ForegroundColor White
            }
        }
        Write-Host ""
        Write-Host ("    {0}. Back" -f ($count + 1)) -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Up/Down + Enter, a number key, or Esc to close this window." -ForegroundColor DarkGray

        $key = [System.Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { $selected = ($selected - 1 + $count) % $count }
            'DownArrow' { $selected = ($selected + 1) % $count }
            'Enter'     { return $selected }
            'Escape'    { return -1 }
            default {
                # Digits are read off the table rather than listed one per case,
                # so a new tool needs no key wiring - and Back keeps the slot
                # just past the end instead of colliding with the tool that
                # takes its old number.
                $d = -1
                if     ("$($key.Key)" -match '^D(\d)$')      { $d = [int]$Matches[1] }
                elseif ("$($key.Key)" -match '^NumPad(\d)$') { $d = [int]$Matches[1] }
                if ($d -ge 1 -and $d -le $count)  { return ($d - 1) }
                if ($d -eq ($count + 1))          { return -1 }
            }
        }
    }
}

function Invoke-CliTools {
    # The CLI-TOOL window. Its tools run inline rather than each opening a window
    # of their own: this window already is the one that was asked for, and
    # finishing a tool drops back to the list so the next can be picked without
    # a trip through the main menu.
    while ($true) {
        $choice = Read-CliToolChoice
        if ($choice -lt 0) { return }

        Clear-Host
        switch ($CliTools[$choice].Action) {
            # Winget has no entry in the table above any more; the case stays so
            # that putting the line back is all it takes.
            'Winget' { Update-Winget }
            'Cpp'    { Install-CppEnvironment }
            'RemoveOffice' { Invoke-RemoveOffice }
            'RemoveAv'     { Invoke-RemoveAntivirusTrial }
            'Dcu'          { Invoke-DellCommandUpdate }
            'Lenovo'       { Invoke-LenovoDriverUpdate }
            default  { Write-Host "[ERROR] Unknown tool '$($CliTools[$choice].Action)'." -ForegroundColor Red }
        }
        Write-Host "`nPress any key to return to the tool list..." -ForegroundColor Gray
        [System.Console]::ReadKey($true) | Out-Null
    }
}

function Invoke-Debloatware {
    Write-Host "`n[System] Launching Win11Debloat (silent default profile)..." -ForegroundColor Cyan
    try {
        & ([scriptblock]::Create((Invoke-RestMethod "https://debloat.raphi.re/"))) -RunDefaults -Silent
        Write-Host "`n[OK] Debloatware utility finished." -ForegroundColor Green
    }
    catch {
        Write-Host "`n[ERROR] Failed to run Debloatware utility: $_" -ForegroundColor Red
    }
}

function Invoke-RemoveOffice {
    # Runs the exact same logic as the background job that fires when WPS is
    # chosen (see $RemoveOfficeScript) - invoked directly here, in the
    # foreground, so its output can be watched line by line.
    #
    # The job path takes its consent from the licence question: answering "no
    # licence" is what schedules it. Reached from the tool list there is no such
    # answer behind it, and uninstalling a licensed Office is not something to
    # do on a mis-keyed menu item - so this path asks and the job path does not.
    # A "yes" on a clean machine still costs nothing: the scriptblock scans
    # first and returns when it finds no Office to remove.
    Write-Host "`n[Office] Force-remove Office 2016-2024 and Microsoft 365" -ForegroundColor Magenta
    Write-Host "         Every Office product found is uninstalled, licensed or not." -ForegroundColor DarkGray
    Write-Host "`n  Continue? [y/N] " -NoNewline -ForegroundColor Yellow
    if ("$([System.Console]::ReadKey($false).KeyChar)" -notmatch '^[yY]$') {
        Write-Host "`n[Cancelled] Office was left alone." -ForegroundColor Yellow
        return
    }
    Write-Host ""

    Write-Host "`n[System] Force-removing Office (2016-2024 + Microsoft 365)..." -ForegroundColor Magenta
    & $RemoveOfficeScript | ForEach-Object {
        $color = if ($_ -match 'FAILED') { 'Red' }
                 elseif ($_ -match '\[stderr\]') { 'Yellow' }
                 elseif ($_ -match ': OK\b') { 'Green' }
                 else { 'Gray' }
        Write-Host "   $_" -ForegroundColor $color
    }
    Write-Host "`n[OK] Office removal finished." -ForegroundColor Green

    # Open the raw, unmangled Office Tool Plus output in Notepad so it can be
    # copy-pasted exactly as-is (a terminal screenshot loses/garbles text).
    $rawLog = "$env:TEMP\OfficeToolPlus_stdout.log"
    if ((Test-Path $rawLog) -and (Get-Item $rawLog).Length -gt 0) {
        Write-Host "[Office] Raw Office Tool Plus output: $rawLog (opening in Notepad)" -ForegroundColor Cyan
        Start-Process -FilePath "notepad.exe" -ArgumentList "`"$rawLog`"" -WindowStyle Normal
    }
}

function Invoke-OptimizeInstall {
    # Menu 1 + 4 + 3 off a single keypress. The Office question is asked here
    # instead of inside the engine so everything starts only after it is
    # answered, and the answer is handed down rather than asked twice.
    $officeChoice = Read-OfficeChoice
    # Return before the debloat job starts, not just before the installs: menu 5
    # would otherwise still debloat and repartition a machine the user cancelled.
    if ($officeChoice -eq 'Cancel') {
        Write-Host "`n[Cancelled] Nothing was installed or changed." -ForegroundColor Yellow
        return
    }

    Write-Host "`n[System] Starting Debloat in the background..." -ForegroundColor Magenta
    $debloatJob = Start-Job -ScriptBlock $DebloatScript

    # info.exe is compiled alongside the installs. Fetching the ps2exe module
    # from PSGallery and running the compile is most of a minute on a machine
    # that has not done it before, and none of it waits on the apps - only the
    # desktop shortcuts do, and those stay at the end where they belong.
    #
    # A job starts in a fresh session holding none of this script's functions,
    # and Publish-InfoExe is far too long to duplicate just to reach it, so the
    # live definitions are handed over and re-declared on the far side.
    Write-Host "[System] Building info.exe in the background..." -ForegroundColor Magenta
    $infoFunctions = (Get-Command New-InfoIcon, Publish-InfoExe |
        ForEach-Object { "function $($_.Name) { $($_.ScriptBlock) }" }) -join "`n"
    # Both URLs travel with it. Publish-InfoExe reads them as script variables,
    # and a job sees none of this script's scope - an unset $InfoExeUrl would
    # send every machine down the slow compile path without ever saying why.
    $infoJob = Start-Job -ArgumentList $infoFunctions, $InfoExeUrl, $InfoSourceUrl -ScriptBlock {
        param([string]$FunctionDefs, [string]$ExeUrl, [string]$SourceUrl)
        . ([scriptblock]::Create($FunctionDefs))
        $InfoExeUrl    = $ExeUrl
        $InfoSourceUrl = $SourceUrl
        # Publish-InfoExe narrates its progress to a console this job does not
        # have. Only the path it returns is wanted here, so stream 6 is dropped
        # rather than left to mix into that return value.
        $path = ""
        try { $path = Publish-InfoExe 6>$null } catch { }
        # Opened here rather than back in the menu window once everything else
        # is done. The point of building it early is that it is ready early;
        # holding it until the installs finish would hand that back.
        if ($path -and (Test-Path -LiteralPath $path)) {
            try { Start-Process -FilePath $path -ErrorAction Stop } catch { }
        }
        Write-Output $path
    }

    Install-NecessaryApps -Method 'Installer' -OfficeChoice $officeChoice -WithOfficeShortcuts

    # Bounded like the Config/Disk jobs: a wedged debloat must not strand the run
    Write-Host "`n[System] Waiting for the Debloat job to finish..." -ForegroundColor Cyan
    Wait-Job $debloatJob -Timeout $Script:JobTimeoutSec | Out-Null
    if ($debloatJob.State -eq 'Running') {
        Write-Host ("   [!] Debloat still running after {0} min - stopping it." -f
            [int]($Script:JobTimeoutSec / 60)) -ForegroundColor Red
        Stop-Job -Job $debloatJob -ErrorAction SilentlyContinue
    }

    Write-Host "`n[Debloat Results]" -ForegroundColor Cyan
    foreach ($line in (Receive-Job -Job $debloatJob)) {
        $color = if ($line -match 'FAILED') { 'Red' } else { 'Gray' }
        Write-Host "   $line" -ForegroundColor $color
    }
    if ($debloatJob.State -eq 'Failed') {
        Write-Host "   [!] Debloat job crashed: $($debloatJob.ChildJobs[0].JobStateInfo.Reason.Message)" -ForegroundColor Red
    }
    Remove-Job $debloatJob -Force | Out-Null

    # Bounded the same way. A build that never finished just means Show-SystemInfo
    # falls back to compiling it itself, so there is nothing to rescue here.
    Write-Host "`n[System] Collecting the info.exe build..." -ForegroundColor Cyan
    Wait-Job $infoJob -Timeout $Script:JobTimeoutSec | Out-Null
    if ($infoJob.State -eq 'Running') {
        Write-Host ("   [!] info.exe build still running after {0} min - stopping it." -f
            [int]($Script:JobTimeoutSec / 60)) -ForegroundColor Red
        Stop-Job -Job $infoJob -ErrorAction SilentlyContinue
    }
    # Last non-empty line: the job writes one path, but a crashed run can leave
    # error records ahead of it.
    $infoPath = ""
    $infoResult = @(Receive-Job -Job $infoJob -ErrorAction SilentlyContinue) |
                  Where-Object { $_ -is [string] -and $_ } | Select-Object -Last 1
    if ($infoResult) { $infoPath = [string]$infoResult }
    Remove-Job $infoJob -Force | Out-Null

    # Both halves are already done by the time control reaches here: the job
    # opened info.exe as soon as it had built it, and the engine put the desktop
    # icons out as soon as the office suite landed. Nothing is left but to say so
    # - or, if the background build came back with nothing, to do it the slow way
    # after all.
    if ($infoPath) {
        Write-Host "   [OK] info.exe was built and opened while the apps installed." -ForegroundColor Green
    }
    else {
        Write-Host "   [!] Background build produced nothing - doing the info step now." -ForegroundColor Yellow
        Show-SystemInfo -OfficeChoice $officeChoice
    }
}

function New-InfoIcon {
    # Writes Windows' own "Information" stock icon to $Path as a multi-size
    # .ico for ps2exe -iconFile. No download at all, so nothing here can be
    # rate-limited or blocked.
    #
    # Two things matter for this not to look bad:
    #  1. The icon's location is asked of Windows (SHGetStockIconInfo with
    #     SHGSI_ICONLOCATION returns the DLL path plus the resource index)
    #     rather than hardcoding an imageres.dll index, which moves between
    #     Windows builds.
    #  2. Every size is extracted natively instead of shipping one bitmap.
    #     A single-frame .ico forces Windows to rescale on the fly - that is
    #     what made earlier attempts look blurry, worst of all when a 32px
    #     frame had to be blown up to the 48px the Desktop draws at.
    param([string]$Path)

    Add-Type -AssemblyName System.Drawing

    if (-not ("MiniAppStockIcon" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class MiniAppStockIcon {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHSTOCKICONINFO {
        public uint cbSize;
        public IntPtr hIcon;
        public int iSysImageIndex;
        public int iIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szPath;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHGetStockIconInfo(uint siid, uint uFlags, ref SHSTOCKICONINFO psii);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int PrivateExtractIcons(string szFileName, int nIconIndex,
        int cxIcon, int cyIcon, IntPtr[] phicon, int[] piconid, int nIcons, uint flags);
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@ -ErrorAction Stop
    }

    $SIID_INFO = 79            # SHSTOCKICONID: the "i" in a circle
    $SHGSI_ICONLOCATION = 0    # return szPath + iIcon, do not create a handle

    $sii = New-Object MiniAppStockIcon+SHSTOCKICONINFO
    $sii.cbSize = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type]'MiniAppStockIcon+SHSTOCKICONINFO')
    $hr = [MiniAppStockIcon]::SHGetStockIconInfo($SIID_INFO, $SHGSI_ICONLOCATION, [ref]$sii)
    if ($hr -ne 0 -or -not $sii.szPath) {
        throw "SHGetStockIconInfo failed (HRESULT $hr)"
    }

    # Largest first, the order Windows itself writes .ico files in.
    $frames = New-Object System.Collections.Generic.List[object]
    foreach ($size in @(256, 128, 64, 48, 32, 16)) {
        $hIcons = New-Object IntPtr[] 1
        $iconIds = New-Object int[] 1
        $extracted = [MiniAppStockIcon]::PrivateExtractIcons($sii.szPath, $sii.iIcon, $size, $size, $hIcons, $iconIds, 1, 0)
        if ($extracted -le 0 -or $hIcons[0] -eq [IntPtr]::Zero) { continue }

        try {
            $icon = [System.Drawing.Icon]::FromHandle($hIcons[0])
            $bmp = $icon.ToBitmap()
            $ms = New-Object System.IO.MemoryStream
            try {
                # PNG-compressed frames, supported by .ico since Vista and the
                # only sane way to carry a 256px frame.
                $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                [void]$frames.Add([pscustomobject]@{ Size = $size; Data = $ms.ToArray() })
            }
            finally { $ms.Dispose() }
            $bmp.Dispose()
            $icon.Dispose()
        }
        finally { [void][MiniAppStockIcon]::DestroyIcon($hIcons[0]) }
    }

    if ($frames.Count -eq 0) { throw "Could not extract the Windows Information icon from $($sii.szPath)" }

    # ICONDIR header, then one 16-byte ICONDIRENTRY per frame, then the frames.
    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    try {
        $bw.Write([uint16]0)                # reserved
        $bw.Write([uint16]1)                # 1 = icon (2 would be cursor)
        $bw.Write([uint16]$frames.Count)

        $offset = 6 + (16 * $frames.Count)
        foreach ($f in $frames) {
            # 256 is stored as 0: the field is one byte, so 256 does not fit.
            $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }
            $bw.Write([byte]$dim)           # width
            $bw.Write([byte]$dim)           # height
            $bw.Write([byte]0)              # palette entries (0 = truecolour)
            $bw.Write([byte]0)              # reserved
            $bw.Write([uint16]1)            # colour planes
            $bw.Write([uint16]32)           # bits per pixel
            $bw.Write([uint32]$f.Data.Length)
            $bw.Write([uint32]$offset)
            $offset += $f.Data.Length
        }
        foreach ($f in $frames) { $bw.Write($f.Data) }
        $bw.Flush()
    }
    finally {
        $bw.Dispose()
        $fs.Dispose()
    }
}

function Publish-InfoExe {
    # Puts info.exe on the Desktop so the customer can reopen the hardware
    # report later without going through Setup.ps1 again. Two ways to get one,
    # tried in order:
    #
    #  1. Download the prebuilt copy from R2. Seconds, and every machine ends
    #     up with the identical binary.
    #  2. Compile it here with ps2exe. Minutes, pulls a module off PSGallery,
    #     and wants an execution policy the machine may not have - but it works
    #     when R2 cannot be reached.
    #
    # Either way it is fetched afresh every run rather than skipped when the
    # file is already there: the old "return early if it exists" check meant the
    # very first copy stayed on that machine forever, and later fixes to
    # Info.ps1 could never reach a box that had run this once.
    #
    # Returns the path, or $null when neither route worked and no earlier copy
    # is on the Desktop.
    $desktop = [Environment]::GetFolderPath('Desktop')
    $dest = Join-Path $desktop "info.exe"

    # A copy left open from a previous run holds a write lock on the file, which
    # would fail either route. Hoisted above both for that reason. Own errors
    # swallowed so a process that cannot be inspected does not abort the run.
    try {
        Get-Process -Name 'info' -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $dest } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    catch { }

    $workDir = "$env:TEMP\MiniApp"
    if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }

    # --- 1. The prebuilt binary from R2 ---
    try {
        Write-Host "[System] Downloading info.exe..." -ForegroundColor Cyan
        # Staged in TEMP instead of written straight to the Desktop: a transfer
        # that dies halfway would otherwise replace a working info.exe with a
        # truncated one.
        $staged = "$workDir\info.exe"
        Invoke-WebRequest -Uri $InfoExeUrl -OutFile $staged -UseBasicParsing -ErrorAction Stop

        # A captive portal or a proxy error page answers 200 with HTML, and that
        # would land on the Desktop named info.exe and fail at the double-click
        # instead of here. Every Windows binary opens with "MZ".
        $bytes = [System.IO.File]::ReadAllBytes($staged)
        if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
            throw "what came back is not a Windows executable"
        }

        Copy-Item -LiteralPath $staged -Destination $dest -Force -ErrorAction Stop
        Write-Host "[OK] info.exe downloaded to Desktop." -ForegroundColor Green
        return $dest
    }
    catch {
        Write-Host "[WARN] Could not download info.exe: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "[System] Building it on this machine instead..." -ForegroundColor Cyan
    }

    # --- 2. Compile it here ---
    try {
        # The elevation relaunch (top of this script) sets -ExecutionPolicy
        # Bypass for the process, but only when Setup.ps1 actually had to
        # relaunch itself; a console already running as Administrator skips
        # that and keeps whatever policy the user/machine had (often
        # Restricted). Import-Module loads ps2exe's .psm1 from disk, which
        # is subject to that policy even though the outer script (run via
        # iex) is not - so it must be set explicitly, process-scoped only.
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

        if (-not (Get-Module -ListAvailable -Name ps2exe)) {
            if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
            }
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Install-Module -Name ps2exe -Scope CurrentUser -Force -ErrorAction Stop
        }
        Import-Module ps2exe -ErrorAction Stop

        $sourcePs1 = "$workDir\Info.ps1"
        $iconPath  = "$workDir\info.ico"

        Invoke-WebRequest -Uri (Get-NoCacheUrl $InfoSourceUrl) -OutFile $sourcePs1 -UseBasicParsing -ErrorAction Stop
        # A missing icon is not worth failing the build over - ps2exe just
        # falls back to its own default and info.exe still works.
        $useIcon = $true
        try { New-InfoIcon -Path $iconPath }
        catch {
            $useIcon = $false
            Write-Host "[WARN] Could not build the icon, using the default: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # Piped to Out-Null: Invoke-ps2exe writes its own compile-log lines to
        # the success stream, which would otherwise land in this function's
        # return value alongside $dest below, turning a clean path string
        # into a mixed array (and breaking Test-Path/Start-Process downstream).
        $ps2exeArgs = @{
            inputFile   = $sourcePs1
            outputFile  = $dest
            noConsole   = $true
            title       = "System Information"
            ErrorAction = 'Stop'
        }
        if ($useIcon) { $ps2exeArgs['iconFile'] = $iconPath }

        try {
            Invoke-ps2exe @ps2exeArgs | Out-Null
        }
        catch {
            # The icon is the only unusual input here, and the compiler
            # ps2exe drives is picky about .ico layouts. Rather than leave
            # the machine with no exe at all, build again without one.
            if (-not $ps2exeArgs.ContainsKey('iconFile')) { throw }
            Write-Host "[WARN] Build rejected the icon, retrying without it: $($_.Exception.Message)" -ForegroundColor Yellow
            $ps2exeArgs.Remove('iconFile')
            Invoke-ps2exe @ps2exeArgs | Out-Null
        }

        # ps2exe can report success without producing anything usable, and
        # everything downstream assumes a real file, so confirm it landed.
        if (-not (Test-Path -LiteralPath $dest) -or (Get-Item -LiteralPath $dest).Length -eq 0) {
            throw "ps2exe finished but no usable info.exe was produced at $dest"
        }

        Write-Host "[OK] info.exe built and placed on Desktop." -ForegroundColor Green
        return $dest
    }
    catch {
        Write-Host "[WARN] Could not build info.exe either: $($_.Exception.Message)" -ForegroundColor Yellow
        # A build from an earlier run may still be sitting on the Desktop.
        # Opening that is better than opening nothing, even if it is stale.
        if (Test-Path $dest) {
            Write-Host "[System] Using the info.exe already on the Desktop." -ForegroundColor DarkGray
            return $dest
        }
    }
}

# =========================================================================
# INTERACTIVE MENU UI
# =========================================================================
# Action names the feature window Start-FeatureWindow opens, and is what the
# dispatch at the bottom of this file matches on. Exit has none - it is the only
# item still handled inside the menu process itself.
$MenuOptions = @(
    @{ Label = "Optimize Install";         Desc = "Install + Debloat together, then hardware report"; Action = "Optimize" },
    @{ Label = "Install Apps (Installer)"; Desc = "Download from direct links, install in parallel";  Action = "Install"  },
    @{ Label = "System Information";       Desc = "Hardware info in a GUI window + build info.exe";   Action = "Info"     },
    @{ Label = "Debloat Windows";          Desc = "Remove bloatware (Win11Debloat defaults)";         Action = "Debloat"  },
    @{ Label = "CLI-TOOL";                 Desc = "Standalone utilities, listed in their own window";     Action = "CliTool"  },
    @{ Label = "Exit";                     Desc = "Close the tool";                                   Action = ""         }
)

function Get-NominalDiskSize {
    # Rounds a raw byte count to the size printed on the box: a "512GB" SSD
    # reports 476GB in binary GiB, and a technician reading 476 off the header
    # would write down the wrong drive. Same table and rounding as Info.ps1 -
    # the two are kept in step by hand.
    param([double]$Bytes)
    $decimalGB = $Bytes / 1000000000
    $standardSizesGB = @(32, 60, 64, 90, 120, 125, 128, 160, 180, 200, 240, 250, 256, 320, 400, 480, 500, 512, 640, 750, 960, 1000, 1024, 1500, 2000, 3000, 4000, 5000, 6000, 8000, 10000, 12000, 16000, 20000)
    $closest = $standardSizesGB | Sort-Object { [Math]::Abs($_ - $decimalGB) } | Select-Object -First 1
    if ($closest -ge 1000) { return "$([math]::Round($closest / 1000, 1))TB" }
    return "${closest}GB"
}

function Get-ShortCpuName {
    # "13th Gen Intel(R) Core(TM) i5-1335U" -> "i5 1335U". The vendor and brand
    # words are the same on every machine that comes through, so they buy
    # nothing at this width; the model number is the whole of what is worth
    # showing. Also handles "Core Ultra 7 155H", "Ryzen 7 5800H with Radeon
    # Graphics" and "Celeron N4020 CPU @ 1.10GHz".
    param([string]$Name)

    $n = $Name -replace '\((R|TM|tm)\)', ''
    $n = $n -replace '\d+th Gen ', ''
    $n = $n -replace '\s+(CPU|Processor)\b.*$', ''
    # Some names carry the clock with no "CPU" in front of it to anchor the
    # rule above - "Pentium(R) Silver N6000 @ 1.10GHz" - so the frequency is
    # cut on its own too.
    $n = $n -replace '\s*@\s*[\d.]+\s*[GM]Hz.*$', ''
    $n = $n -replace '\s+with\s+.*$', ''
    $n = $n -replace '\b(Intel|AMD|Core)\b', ''
    return (($n -replace '-', ' ') -replace '\s+', ' ').Trim()
}

function Get-MenuContext {
    # Machine identity shown in the header - the fields a technician writes down
    # off the screen. Every lookup is best-effort and falls back to "-": a header
    # field that cannot be read is not worth failing the menu over.
    $model  = try { (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Model.Trim() } catch { "-" }
    $serial = try { (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber.Trim() } catch { "-" }

    # Caption is "Microsoft Windows 10 Pro" - the feature-update label (25H2) is
    # not in it and has to come out of the registry. DisplayVersion is what 20H2
    # and later write; ReleaseId is the older name for the same value, so it is
    # a fallback rather than a second field. Neither present just means the
    # caption is shown on its own.
    $winVer = try { ((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption -replace '^Microsoft\s+', '').Trim() } catch { "-" }
    $release = try {
        $cv = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
        if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId }
    } catch { $null }
    if ($winVer -ne "-" -and $release) { $winVer = "$winVer $release" }

    # The headline spec, on one line. Each part is read on its own so that one
    # unreadable piece leaves the other two standing rather than blanking the
    # whole field.
    $cpuText = try { Get-ShortCpuName (Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).Name } catch { "" }

    $ramText = try {
        # Summed from the modules rather than TotalPhysicalMemory, which is
        # short by whatever the firmware reserved and rounds down to 15GB on a
        # 16GB machine.
        $bytes = (Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | Measure-Object -Property Capacity -Sum).Sum
        "$([math]::Round($bytes / 1GB))GB"
    } catch { "" }

    $diskText = try {
        # The disk holding C:, not disk 0 - they are usually the same, but on a
        # machine with a second drive fitted they need not be.
        $sysDisk = Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk -ErrorAction Stop
        # MediaType is the only place SSD/HDD is stated; when it is Unspecified
        # or the cmdlet is missing, the neutral "Disk" is better than guessing.
        $kind = "Disk"
        $pd = Get-PhysicalDisk -ErrorAction SilentlyContinue |
              Where-Object { $_.DeviceId -eq [string]$sysDisk.Number } | Select-Object -First 1
        if ($pd -and "$($pd.MediaType)" -in @("SSD", "HDD")) { $kind = "$($pd.MediaType)" }
        "$kind $(Get-NominalDiskSize -Bytes $sysDisk.Size)"
    } catch { "" }

    $info = (@($cpuText, $ramText, $diskText) | Where-Object { $_ }) -join " / "

    # When the repo was last pushed, so a technician can see at a glance whether
    # this machine pulled a current Setup.ps1. Best-effort and time-boxed: a slow
    # or rate-limited GitHub must never hold the menu hostage.
    $updated = try {
        $head = Invoke-RestMethod -Uri $CommitApiUrl -TimeoutSec 5 -UseBasicParsing `
                                  -Headers @{ 'User-Agent' = 'MiniApp' } -ErrorAction Stop
        $stamp = $head.commit.committer.date
        # PowerShell 5.1 already turns the ISO-8601 field into [datetime] while
        # newer hosts hand back the raw string. Normalise, or the stamp is off by
        # a whole timezone. ToLocalTime is a no-op on an already-local value.
        if ($stamp -isnot [datetime]) {
            $stamp = [datetime]::Parse($stamp, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
        $stamp.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
    } catch { "unknown" }

    return @{ Host = $env:COMPUTERNAME; Model = $model; Serial = $serial; Windows = $winVer
              Info = $info; Updated = $updated }
}

function Show-Menu {
    param([int]$SelectedIndex, [hashtable]$Ctx)

    Clear-Host
    Write-BoxTop
    Write-BoxCenter "MINIAPP  -  Windows Setup Tool" "White"
    Write-BoxSep
    # Two spaces between fields, not three: kept tight from when the box was
    # narrower (58-column interior) - a 15-char hostname plus "Offline" would
    # have overrun it at three spaces and lost its last letter.
    # Two columns over three lines. Label widths are the widest label in each
    # column plus a space - "Update:" on the left, "Serial:" on the right - and
    # what is left over splits evenly, so all four value cells start on one of
    # two columns whatever the machine is called.
    #
    # The right-hand label is "OS", not "Windows": the value already begins with
    # the word, and "Windows: Windows 10 Pro 22H2" would spend five characters
    # of a tight line saying it twice.
    $lw = 8
    $rw = 8
    # The split is not even. What goes on the left runs long - a model name and
    # a full spec line - while the right holds an OS caption, a serial and a
    # fixed-width timestamp, so the left column is given the extra columns.
    # 2 + 8 + 32 + 8 + 24 fills the 74-column interior exactly.
    $lc = 32
    $rc = 24
    Write-BoxLine ("  " + (Format-HeaderCell "Host"  $Ctx.Host  $lw $lc) +
                          (Format-HeaderCell "OS"     $Ctx.Windows $rw $rc)) "DarkGray"
    Write-BoxLine ("  " + (Format-HeaderCell "Model" $Ctx.Model $lw $lc) +
                          (Format-HeaderCell "Serial" $Ctx.Serial  $rw $rc)) "DarkGray"
    Write-BoxLine ("  " + (Format-HeaderCell "Info"  $Ctx.Info  $lw $lc) +
                          (Format-HeaderCell "Update" $Ctx.Updated $rw $rc)) "DarkGray"
    Write-BoxBottom
    Write-Host ""

    for ($i = 0; $i -lt $MenuOptions.Count; $i++) {
        $num = $i + 1
        # Asked on every redraw rather than cached: an item frees up the moment
        # its window closes, and the next keypress repaints and shows that.
        # Padding fits the longest label plus a suffix (both are 10 wide), so
        # the highlight bar keeps one width in every state.
        $blocker = Get-BlockingWindow $MenuOptions[$i].Action
        $busy = ""
        if ($blocker) {
            $busy = if ($blocker -eq $MenuOptions[$i].Action) { " [running]" } else { " [blocked]" }
        }
        if ($i -eq $SelectedIndex) {
            Write-Host ("  {0} {1}. {2}" -f $Script:Glyph.Run, $num, ($MenuOptions[$i].Label + $busy).PadRight(34)) -ForegroundColor Black -BackgroundColor Cyan
            Write-Host ("       {0}" -f $MenuOptions[$i].Desc) -ForegroundColor DarkGray
        }
        else {
            $color = if ($busy) { "DarkGray" } else { "White" }
            Write-Host ("    {0}. {1}{2}" -f $num, $MenuOptions[$i].Label, $busy) -ForegroundColor $color
        }
    }
    Write-Host ""
    Write-Host "  Up/Down + Enter, a number key, or A/S/I/D/C/Q to run directly." -ForegroundColor DarkGray
    Write-Host "  Each item opens its own window - this menu stays usable." -ForegroundColor DarkGray
}

function Read-MenuChoice {
    $selectedIndex = 0
    $count = $MenuOptions.Count
    # Cached for the session. Launching a feature now returns here instantly, so
    # re-running Get-MenuContext - a network call with a 5s timeout - on every
    # pass would put a visible stall between one launch and the next.
    if (-not $Script:MenuCtx) { $Script:MenuCtx = Get-MenuContext }
    $ctx = $Script:MenuCtx

    while ($true) {
        Show-Menu -SelectedIndex $selectedIndex -Ctx $ctx
        $key = [System.Console]::ReadKey($true).Key

        switch ($key) {
            'UpArrow'   { $selectedIndex = ($selectedIndex - 1 + $count) % $count }
            'DownArrow' { $selectedIndex = ($selectedIndex + 1) % $count }
            'Enter'     { return $selectedIndex }
            'Escape'    { return $count - 1 }
            'D1'        { return 0 }
            'NumPad1'   { return 0 }
            'D2'        { return 1 }
            'NumPad2'   { return 1 }
            'D3'        { return 2 }
            'NumPad3'   { return 2 }
            'D4'        { return 3 }
            'NumPad4'   { return 3 }
            'D5'        { return 4 }
            'NumPad5'   { return 4 }
            'D6'        { return 5 }
            'NumPad6'   { return 5 }
            # Direct-run letter shortcuts, one per menu item - fire immediately,
            # no Enter needed (unlike the number keys they're identical to).
            'A'         { return 0 }
            'S'         { return 1 }
            'I'         { return 2 }
            'D'         { return 3 }
            'C'         { return 4 }
            'Q'         { return 5 }
        }
    }
}

# =========================================================================
# FEATURE WINDOWS
# =========================================================================
# A menu item no longer takes over this console. It opens its own PowerShell
# window and returns immediately, so the menu stays on screen and usable while
# the feature runs - and several features can be watched side by side.
$Script:FeatureWindows = @{}

function Get-FeatureWindow {
    # The still-open window for an action, or $null. Closed windows are dropped
    # here rather than swept separately, so an item becomes selectable again on
    # the first redraw after its window goes away.
    param([string]$Action)

    if ([string]::IsNullOrEmpty($Action)) { return $null }
    $proc = $Script:FeatureWindows[$Action]
    if (-not $proc) { return $null }

    # A Process object outlives the process it describes, and HasExited can
    # throw once the handle is gone. A window that cannot be read is treated as
    # closed: worst case the item is offered again, which beats a menu item
    # locked out for the rest of the session.
    $exited = $true
    try { $exited = $proc.HasExited } catch { }
    if ($exited) {
        $Script:FeatureWindows.Remove($Action)
        return $null
    }
    return $proc
}

# Actions that must never be open at the same time, keyed action -> group name.
# Same shape as $SerialGroups up in the install engine, and the same reasoning:
# Optimize Install drives that very engine, so running it beside Install Apps
# means two engines downloading into one %TEMP% folder and two passes
# repartitioning C:. Another pair just needs two more lines here.
$ExclusiveGroups = @{
    "Optimize" = "install"
    "Install"  = "install"
    # Still the whole CLI-TOOL window: the C++ tool installs through winget,
    # which the install run is refreshing in its own background job, and it
    # pulls ~2GB while the engine is already saturating the connection. The
    # window is also the only thing the menu process can see - which tool a
    # separate process settles on is not visible from here, so there is nothing
    # finer to block on.
    "CliTool"  = "install"
}

function Get-BlockingWindow {
    # The name of the open action standing in the way of $Action - itself when
    # it is already running, otherwise whichever member of its exclusive group
    # is. $null when the item is free to start.
    param([string]$Action)

    if ([string]::IsNullOrEmpty($Action)) { return $null }
    if (Get-FeatureWindow $Action) { return $Action }

    $group = $ExclusiveGroups[$Action]
    if (-not $group) { return $null }
    foreach ($other in $ExclusiveGroups.Keys) {
        if ($other -eq $Action) { continue }
        if ($ExclusiveGroups[$other] -ne $group) { continue }
        if (Get-FeatureWindow $other) { return $other }
    }
    return $null
}

function Start-FeatureWindow {
    param([Parameter(Mandatory)][string]$Action)

    # The child cannot simply be handed this script: run through `irm | iex`
    # there is no file behind it and $PSCommandPath is empty - the same reason
    # the elevation block up top re-fetches instead of relaunching itself. So a
    # two-line bootstrap is written out that sets $MiniAppAction and re-fetches;
    # iex runs in that scope, so the dispatch below sees the variable and runs
    # that one feature instead of drawing a menu.
    #
    # Started from this process, which is already elevated, so the child
    # inherits Administrator - no second UAC prompt per window.
    $workDir = "$env:TEMP\MiniApp"
    if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }
    $boot = "$workDir\run-$Action.ps1"

    try {
        # The bootstrap is rewritten on every launch, so the cache-buster in it
        # is fresh each time a window opens.
        Set-Content -LiteralPath $boot -Encoding UTF8 -Force -ErrorAction Stop -Value @(
            "`$MiniAppAction = '$Action'"
            "iex (irm '$(Get-NoCacheUrl $SelfUrl)')"
        )
        # -File with the path quoted: %TEMP% lives under the user profile, and a
        # username with a space in it would otherwise split into two arguments.
        #
        # No -NoExit, and nothing is transcribed: the window closes on its own
        # and leaves the customer's Desktop clean. To watch a run that is
        # misbehaving, add -NoExit here and the window stays open on whatever it
        # last printed.
        $proc = Start-Process powershell -PassThru -ErrorAction Stop `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$boot`""
        $Script:FeatureWindows[$Action] = $proc
        return $true
    }
    catch {
        Write-Host "`n  [ERROR] Could not open a window for $Action - $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# =========================================================================
# MAIN LOOP
# =========================================================================
# Set by the bootstrap Start-FeatureWindow writes. When it is present this
# process is a feature window, not the menu: run the one feature and close.
if ($MiniAppAction) {
    # Nothing is written to disk here: the Desktop these windows run against is
    # the one handed to the customer, and a machine that leaves the shop should
    # carry the tool's output no more than it carries its installers. The window
    # closing takes what it printed with it - see the note in Start-FeatureWindow
    # for how to watch a run that needs watching.
    switch ($MiniAppAction) {
        'Optimize' { Invoke-OptimizeInstall }
        'Install'  { Install-NecessaryApps -Method 'Installer' }
        'Info'     { Show-SystemInfo }
        'Debloat'  { Invoke-Debloatware }
        'CliTool'  { Invoke-CliTools }
        default    { Write-Host "[ERROR] Unknown action '$MiniAppAction'." -ForegroundColor Red }
    }
    exit
}

# Below this line is the menu session. The gate sits here rather than at the top
# of the file so the feature windows above return before reaching it.
Assert-AccessPassword

while ($true) {
    $choice = Read-MenuChoice
    $option = $MenuOptions[$choice]

    # Exit is the one item with no Action - nothing to open, just stop here.
    if (-not $option.Action) {
        Clear-Host
        Write-Host "Exiting program. Have a great day!" -ForegroundColor Green
        exit
    }

    # Refused rather than queued: the window holding the item is still open and
    # can be watched, so there is something to wait on rather than a silent one.
    $blocker = Get-BlockingWindow $option.Action
    if ($blocker) {
        if ($blocker -eq $option.Action) {
            Write-Host ("`n  [!] {0} is already running in its own window." -f $option.Label) -ForegroundColor Yellow
            Write-Host "      Finish that one first, or pick another item." -ForegroundColor DarkGray
        }
        else {
            $blockerLabel = ($MenuOptions | Where-Object { $_.Action -eq $blocker } | Select-Object -First 1).Label
            Write-Host ("`n  [!] {0} cannot start while {1} is running." -f $option.Label, $blockerLabel) -ForegroundColor Yellow
            Write-Host "      Both drive the same installer engine - only one of them at a time." -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 2
        continue
    }

    if (Start-FeatureWindow -Action $option.Action) {
        Write-Host ("`n  {0} {1} opened in a new window." -f $Script:Glyph.Ok, $option.Label) -ForegroundColor Green
    }
    # Long enough to read either message, and it keeps a held-down key from
    # firing off several windows before the first shows up as [running].
    Start-Sleep -Seconds 2
}

