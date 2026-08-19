# =========================================================================
# MINIAZ SETUP SCRIPT - All-in-One Windows Deployment Tool
# =========================================================================
# Self-contained: Config, Disk partitioning and Hardware Info are embedded.
# Usage: irm https://raw.githubusercontent.com/mson-ssh/miniapps/main/Setup.ps1 | iex
# =========================================================================

# Configure TLS 1.2 to prevent GitHub downloads from being blocked
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# Single source of truth for self-relaunch during UAC elevation
$SelfUrl = "https://raw.githubusercontent.com/mson-ssh/miniapps/main/Setup.ps1"

# Derived from $SelfUrl rather than written out again, so repo and branch still
# live on exactly one line. Feeds the "Update" stamp in the menu header.
$CommitApiUrl = $SelfUrl -replace '^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/.*$', 'https://api.github.com/repos/$1/$2/commits/$3'

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
            Invoke-WebRequest -Uri $SelfUrl -OutFile $tempScript -UseBasicParsing -ErrorAction Stop
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
# EMBEDDED: HARDWARE INFORMATION (was config/Get-info.ps1)
# =========================================================================
function Get-HardwareInfo {
    $DesktopPath = [Environment]::GetFolderPath("Desktop")
    $LogFile = "$DesktopPath\info.txt"

    $computer = Get-CimInstance Win32_ComputerSystem
    $bios     = Get-CimInstance Win32_BIOS
    $cpu      = Get-CimInstance Win32_Processor | Select-Object -First 1
    $ram      = Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum
    $disks    = Get-CimInstance Win32_DiskDrive | Where-Object { $_.MediaType -eq 'Fixed hard disk media' }
    $gpus     = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notlike '*Basic*' -and $_.Name -notlike '*Standard*' }

    $ramGB = [math]::Round($ram.Sum / 1GB, 2)
    $currentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    try {
        $videoController = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution -and $_.CurrentVerticalResolution } | Select-Object -First 1
        if ($videoController) {
            $screenRes = "$($videoController.CurrentHorizontalResolution)x$($videoController.CurrentVerticalResolution)"
            $refreshRate = if ($videoController.CurrentRefreshRate) { "$($videoController.CurrentRefreshRate) Hz" } else { "N/A" }
        }
        else { $screenRes = "N/A"; $refreshRate = "N/A" }
    }
    catch { $screenRes = "N/A"; $refreshRate = "N/A" }

    $report = @(
        "================================================================"
        "                   MINIAZ SYSTEM INFORMATION"
        "================================================================"
        "HOSTNAME       : $($computer.Name)"
        "Model          : $($computer.Model)"
        "Serial         : $($bios.SerialNumber)"
        "CPU            : $($cpu.Name)"
        "RAM            : $ramGB GB"
    )

    foreach ($disk in $disks) {
        if ($disk.Size) {
            $diskGB = [math]::Round($disk.Size / 1GB, 2)
            $report += "Storage        : $($disk.Model) - $diskGB GB"
        }
    }
    foreach ($gpu in $gpus) {
        $report += "Graphics Card  : $($gpu.Name)"
    }

    $report += @(
        "Resolution     : $screenRes"
        "Refresh Rate   : $refreshRate"
        "DATE AND TIME  : $currentTime"
        "================================================================"
        "[PROCESS] COMPLETED SUCCESSFULLY"
    )

    $report | Out-File -FilePath $LogFile -Encoding UTF8 -Force

    # Launch decoupled from this process tree so the caller can finish immediately
    Start-Process -FilePath "notepad.exe" -ArgumentList "`"$LogFile`"" -WindowStyle Normal
    return $LogFile
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

function Install-AppInstaller {
    # Fetches App Installer (~200MB) plus its two framework packages from GitHub
    # and registers them. Serves both a missing winget and one too old to trust.
    $tempDir = "$env:TEMP\MiniApp"
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

    try {
        Invoke-WebRequest -Uri "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx" -OutFile "$tempDir\VCLibs.appx" -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest -Uri "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx" -OutFile "$tempDir\UiXaml.appx" -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest -Uri "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -OutFile "$tempDir\Winget.msixbundle" -UseBasicParsing -ErrorAction Stop

        Add-AppxPackage -Path "$tempDir\VCLibs.appx" -ErrorAction SilentlyContinue
        Add-AppxPackage -Path "$tempDir\UiXaml.appx" -ErrorAction SilentlyContinue
        # -ForceApplicationShutdown is what makes this an upgrade path and not just
        # a first install: replacing an already registered App Installer fails
        # while anything still holds it open.
        Add-AppxPackage -Path "$tempDir\Winget.msixbundle" -ForceApplicationShutdown -ErrorAction SilentlyContinue
    }
    catch {
        Write-Host "-> Winget download failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    finally {
        Remove-Item "$tempDir\VCLibs.appx", "$tempDir\UiXaml.appx", "$tempDir\Winget.msixbundle" -Force -ErrorAction SilentlyContinue
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

function Set-CursorTop {
    # Reposition only when a real console buffer exists
    param([int]$Top)
    if ($Script:CanReposition) { try { [Console]::SetCursorPosition(0, $Top) } catch { } }
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
        [ValidateSet('', 'Office', 'Wps', 'Cancel')][string]$OfficeChoice = ''
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

    # Installer mode must not touch Winget: bootstrapping it would download
    # ~200MB of appx and change the client machine without being asked. Winget
    # is only initialized here for the explicit Winget option; Installer mode
    # asks for consent later, and only if something actually failed.
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
            Write-Host $line.PadRight(58) -ForegroundColor $color
        }
        # Overall progress line
        $total = $catalog.Count
        $pct = if ($total) { [int](($done + $fail) * 100 / $total) } else { 0 }
        $elapsed = (Get-Date) - $overallStart
        $bar = Get-ProgressBar -Percent $pct -Width 22
        $failTxt = if ($fail -gt 0) { "$fail failed" } else { "0 failed" }
        $summary = "  {0} {1}/{2}  {3}  {4:mm\:ss}" -f $bar, ($done + $fail), $total, $failTxt, $elapsed
        Write-Host $summary.PadRight(58) -ForegroundColor White
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
                $dirty = $true
            }
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
function Show-SystemInfo {
    param(
        # '' = no known context (standalone menu access): detect whichever
        # suite is actually on disk, so a box carrying both gets both sets.
        # 'Office' / 'Wps' = only create shortcuts for that suite, matching
        # the licence answer from Read-OfficeChoice.
        [ValidateSet('', 'Office', 'Wps')][string]$OfficeChoice = ''
    )
    Write-Host "`n[System] Collecting hardware information..." -ForegroundColor Cyan
    try {
        $logFile = Get-HardwareInfo
        Write-Host "[OK] Report saved to $logFile" -ForegroundColor Green
    }
    catch {
        Write-Host "[ERROR] Failed to collect system information: $_" -ForegroundColor Red
        return
    }

    # Neither suite puts icons on the desktop, so do it here. With a known
    # licence answer, only that suite's shortcuts go out - a WPS box must not
    # also get Word/Excel/PowerPoint icons, and vice versa. With no context
    # (standalone menu access) fall back to detecting what is actually on the
    # machine, so a box carrying both suites gets both sets.
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
    # foreground, so it can be tested/run on its own with live output.
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

    Install-NecessaryApps -Method 'Installer' -OfficeChoice $officeChoice

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

    # Runs last on purpose: the Office shortcuts need the suite that was just
    # installed to be on disk, and Notepad must not pop over the live table.
    Show-SystemInfo -OfficeChoice $officeChoice
}

# =========================================================================
# INTERACTIVE MENU UI
# =========================================================================
$MenuOptions = @(
    @{ Label = "Install Apps (Installer)"; Desc = "Download from direct links, install in parallel" },
    @{ Label = "Install Apps (Winget)";    Desc = "Install via Windows Package Manager" },
    @{ Label = "System Information";        Desc = "Export hardware report to Desktop" },
    @{ Label = "Debloat Windows";           Desc = "Remove bloatware (Win11Debloat defaults)" },
    @{ Label = "Optimize Install";          Desc = "Install + Debloat together, then hardware report" },
    @{ Label = "Exit";                      Desc = "Close the tool" }
)

function Get-MenuContext {
    # One-line machine context shown in the header
    $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption -replace 'Microsoft ', ''
    $cFree = try { [math]::Round((Get-Volume -DriveLetter C -ErrorAction Stop).SizeRemaining / 1GB) } catch { "?" }
    $net = try { if (Test-Connection 1.1.1.1 -Count 1 -Quiet -ErrorAction SilentlyContinue) { "Online" } else { "Offline" } } catch { "?" }

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

    return @{ Host = $env:COMPUTERNAME; OS = $os; CFree = $cFree; Net = $net; Updated = $updated }
}

function Show-Menu {
    param([int]$SelectedIndex, [hashtable]$Ctx)

    Clear-Host
    Write-BoxTop
    Write-BoxCenter "MINIAPP  -  Windows Setup Tool" "White"
    Write-BoxSep
    # Two spaces between fields, not three: a 15-char hostname plus "Offline"
    # overruns the 58-column interior at three and loses its last letter.
    Write-BoxLine ("  Host: {0}  Disk C: {1}GB free  Net: {2}" -f $Ctx.Host, $Ctx.CFree, $Ctx.Net) "DarkGray"
    # Update sits hard right and the OS caption is what gives way, not the other
    # way round: "Windows 10 Enterprise LTSC 2021" is long enough to shove the
    # timestamp off the edge, and the timestamp is the half worth keeping.
    $stamp  = "  Update: {0} " -f $Ctx.Updated
    $osCell = $Script:UiWidth - 2 - $stamp.Length
    $osText = "  {0}" -f $Ctx.OS
    if ($osText.Length -gt $osCell) { $osText = $osText.Substring(0, $osCell) }
    Write-BoxLine ($osText.PadRight($osCell) + $stamp) "DarkGray"
    Write-BoxBottom
    Write-Host ""

    for ($i = 0; $i -lt $MenuOptions.Count; $i++) {
        $num = $i + 1
        if ($i -eq $SelectedIndex) {
            Write-Host ("  {0} {1}. {2}" -f $Script:Glyph.Run, $num, $MenuOptions[$i].Label.PadRight(28)) -ForegroundColor Black -BackgroundColor Cyan
            Write-Host ("       {0}" -f $MenuOptions[$i].Desc) -ForegroundColor DarkGray
        }
        else {
            Write-Host ("    {0}. {1}" -f $num, $MenuOptions[$i].Label) -ForegroundColor White
        }
    }
    Write-Host ""
    Write-Host "  Up/Down + Enter, press a number key, or A for Optimize Install." -ForegroundColor DarkGray
}

function Read-MenuChoice {
    $selectedIndex = 0
    $count = $MenuOptions.Count
    $ctx = Get-MenuContext

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
            # A highlights Optimize Install; Enter then runs it
            'A'         { $selectedIndex = 4 }
        }
    }
}

# =========================================================================
# MAIN LOOP
while ($true) {
    $choice = Read-MenuChoice
    Clear-Host

    switch ($choice) {
        0 { Install-NecessaryApps -Method 'Installer' }
        1 { Install-NecessaryApps -Method 'Winget' }
        2 { Show-SystemInfo }
        3 { Invoke-Debloatware }
        4 { Invoke-OptimizeInstall }
        5 {
            Write-Host "Exiting program. Have a great day!" -ForegroundColor Green
            exit
        }
    }

    Write-Host "`nPress any key to return to the Menu..." -ForegroundColor Gray
    [System.Console]::ReadKey($true) | Out-Null
}

