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
        $tempScript = "$env:TEMP\MiniAZ_Setup_elevated.ps1"
        try {
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
                    while ($true) {
                        $bdeStatus = (Get-BitLockerVolume -MountPoint C: -ErrorAction SilentlyContinue).VolumeStatus
                        if (-not $bdeStatus -or $bdeStatus -eq 'FullyDecrypted') { break }
                        Start-Sleep -Seconds 5
                    }
                    Write-Output "[Disk] BitLocker decryption: OK"
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

# Installer exit codes treated as success: 0 = ok, 3010 = reboot required,
# -1978335201 = already installed (winget/VC Redist)
$SuccessExitCodes = @(0, 3010, -1978335201)

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

function Initialize-Winget {
    # Winget is needed both for the Winget menu option and as the fallback path
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        & winget settings --enable BypassCertificatePinningForMicrosoftStore --accept-source-agreements 2>&1 | Out-Null
        & winget source update --quiet 2>&1 | Out-Null
        return $true
    }

    Write-Host "-> Winget not found. Starting silent Winget initialization..." -ForegroundColor Yellow
    $tempDir = "$env:TEMP\winget-init"
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

    try {
        Invoke-WebRequest -Uri "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx" -OutFile "$tempDir\VCLibs.appx" -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest -Uri "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx" -OutFile "$tempDir\UiXaml.appx" -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest -Uri "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -OutFile "$tempDir\Winget.msixbundle" -UseBasicParsing -ErrorAction Stop

        Add-AppxPackage -Path "$tempDir\VCLibs.appx" -ErrorAction SilentlyContinue
        Add-AppxPackage -Path "$tempDir\UiXaml.appx" -ErrorAction SilentlyContinue
        Add-AppxPackage -Path "$tempDir\Winget.msixbundle" -ErrorAction SilentlyContinue
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

        if (Get-Command winget -ErrorAction SilentlyContinue) {
            & winget settings --enable BypassCertificatePinningForMicrosoftStore --accept-source-agreements 2>&1 | Out-Null
            & winget source update --quiet 2>&1 | Out-Null
            Write-Host "-> Winget initialized successfully." -ForegroundColor Gray
            return $true
        }
        Write-Host "-> Winget initialization did not complete. Fallback will be unavailable." -ForegroundColor Yellow
        return $false
    }
    catch {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "-> Winget initialization failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

# =========================================================================
# MAIN INSTALL ENGINE
# Downloads run fully in parallel; installs run one at a time from a queue
# so concurrent installers never fight over the Windows Installer service.
# =========================================================================
function Install-NecessaryApps {
    param([ValidateSet('Installer', 'Winget')][string]$Method = 'Installer')

    Write-Host "`n[System] Starting Config and Disk setup in the background..." -ForegroundColor Magenta
    $configJob = Start-Job -ScriptBlock $ConfigScript
    $diskJob = Start-Job -ScriptBlock $DiskScript
    Write-Host "-> Background jobs activated (Config, Disk)." -ForegroundColor Gray

    $wingetReady = Initialize-Winget
    if ($Method -eq 'Winget' -and -not $wingetReady) {
        Write-Host "`n[ERROR] Winget is unavailable, so the Winget method cannot run." -ForegroundColor Red
        Write-Host "        Use option 1 (Installer) instead." -ForegroundColor Yellow
        Wait-Job $configJob, $diskJob | Out-Null
        Receive-Job $configJob, $diskJob | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray }
        Remove-Job $configJob, $diskJob -Force | Out-Null
        return
    }

    $tempDir = "$env:TEMP\MiniAZ_Apps"
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
    $fallbackUsed  = @{}   # Name -> $true once fallback was spent
    $installQueue  = @()

    Write-Host "`n[Progress] Downloading in parallel, installing sequentially..." -ForegroundColor Cyan
    $startTop = [Console]::CursorTop

    $renderTable = {
        try { [Console]::SetCursorPosition(0, $startTop) } catch { }
        foreach ($a in $AppCatalog) {
            $line = "   [+] {0} - {1}" -f $a.Name.PadRight(13), $appStates[$a.Name]
            Write-Host $line.PadRight(78) -ForegroundColor Yellow
        }
    }

    foreach ($app in $AppCatalog) {
        if ($app.MatchName -and (Test-IsInstalled $app.MatchName)) {
            $appStates[$app.Name] = "Already Installed"
        }
        elseif ($app.Name -eq "EVKey" -and (Test-Path "C:\EVKey")) {
            $appStates[$app.Name] = "Already Installed"
        }
        elseif ($Method -eq 'Winget' -and $app.WingetId) {
            $appStates[$app.Name] = "Waiting to Install"
            $installMode[$app.Name] = 'Winget'
            $installQueue += $app.Name
        }
        else {
            # Direct download. WebClient streams to disk instead of buffering in RAM.
            $appStates[$app.Name] = "Downloading"
            $installMode[$app.Name] = 'Installer'
            $tempExe = Join-Path $tempDir ($app.Url.Split('/')[-1])
            $wc = New-Object System.Net.WebClient
            $webClients[$app.Name] = $wc
            $downloadTasks[$app.Name] = $wc.DownloadFileTaskAsync($app.Url, $tempExe)
        }
        Write-Host ("   [+] {0} - {1}" -f $app.Name.PadRight(13), $appStates[$app.Name]) -ForegroundColor Yellow
    }

    $currentApp = $null
    $currentProc = $null
    $installDeadline = $null

    while ($downloadTasks.Count -gt 0 -or $installQueue.Count -gt 0 -or $currentApp) {
        $dirty = $false

        # --- 1. Harvest finished downloads ---
        $finished = @()
        foreach ($key in @($downloadTasks.Keys)) {
            if ($downloadTasks[$key].IsCompleted) {
                $finished += $key
                if ($downloadTasks[$key].IsFaulted -or $downloadTasks[$key].IsCanceled) {
                    $app = $AppCatalog | Where-Object { $_.Name -eq $key }
                    if ($wingetReady -and $app.WingetId -and -not $fallbackUsed[$key]) {
                        # Direct link died: hand this app to Winget instead
                        $fallbackUsed[$key] = $true
                        $installMode[$key] = 'Winget'
                        $appStates[$key] = "Winget Fallback"
                        $installQueue += $key
                    }
                    else {
                        $appStates[$key] = "Failed (Download)"
                    }
                }
                else {
                    $appStates[$key] = "Waiting to Install"
                    $installQueue += $key
                }
                $dirty = $true
            }
        }
        foreach ($key in $finished) {
            $downloadTasks.Remove($key)
            $webClients[$key].Dispose()
            $webClients.Remove($key)
        }

        # --- 2. Watch the running install ---
        if ($currentApp) {
            if (-not $currentProc) {
                # Fire-and-forget launch (EVKey SFX) - nothing to wait on
                $appStates[$currentApp] = "Done"
                $currentApp = $null
                $dirty = $true
            }
            elseif ($currentProc.HasExited) {
                # A null ExitCode means Windows would not hand it back; the process
                # did exit, so trust it rather than reporting a false failure.
                $code = try { $currentProc.ExitCode } catch { $null }
                if ($null -eq $code -or $SuccessExitCodes -contains $code) {
                    $appStates[$currentApp] = "Done"
                }
                else {
                    $app = $AppCatalog | Where-Object { $_.Name -eq $currentApp }
                    if ($wingetReady -and $app.WingetId -and -not $fallbackUsed[$currentApp]) {
                        $fallbackUsed[$currentApp] = $true
                        $installMode[$currentApp] = 'Winget'
                        $appStates[$currentApp] = "Winget Fallback"
                        $installQueue += $currentApp
                    }
                    else {
                        $appStates[$currentApp] = "Failed (ExitCode: $code)"
                    }
                }
                $currentApp = $null
                $currentProc = $null
                $dirty = $true
            }
            elseif ($installDeadline -and (Get-Date) -gt $installDeadline) {
                # Hung installer: kill it so the queue keeps moving
                $currentProc | Stop-Process -Force -ErrorAction SilentlyContinue
                $appStates[$currentApp] = "Failed (Timeout)"
                $currentApp = $null
                $currentProc = $null
                $dirty = $true
            }
        }

        # --- 3. Start the next install from the queue ---
        if (-not $currentApp -and $installQueue.Count -gt 0) {
            $currentApp = $installQueue[0]
            $installQueue = @($installQueue | Select-Object -Skip 1)

            $app = $AppCatalog | Where-Object { $_.Name -eq $currentApp }
            $appStates[$currentApp] = "Installing"
            $installDeadline = (Get-Date).AddSeconds($app.TimeoutSec)
            $currentProc = $null
            $dirty = $true

            try {
                if ($installMode[$currentApp] -eq 'Winget') {
                    $wingetArgs = "install --id $($app.WingetId) --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements"
                    # -WindowStyle Hidden, not -NoNewWindow: with -NoNewWindow the
                    # returned process object reports a null ExitCode even after exit.
                    $currentProc = Start-Process winget -ArgumentList $wingetArgs -PassThru -WindowStyle Hidden
                }
                elseif ($currentApp -eq "EVKey") {
                    # WinRAR SFX: extracts to C:\EVKey and returns immediately
                    Start-Process -FilePath (Join-Path $tempDir ($app.Url.Split('/')[-1])) -ArgumentList $app.Args -WindowStyle Hidden
                    Start-Sleep -Seconds 3
                }
                elseif ([string]::IsNullOrWhiteSpace($app.Args)) {
                    # Interactive installer (Office) - surface its window to the user
                    $currentProc = Start-Process -FilePath (Join-Path $tempDir ($app.Url.Split('/')[-1])) -PassThru
                    Start-Sleep -Seconds 3
                    $hwnd = [Win32UI]::FindWindow($null, "Microsoft Office")
                    if ($hwnd -ne [IntPtr]::Zero) { [Win32UI]::SetForegroundWindow($hwnd) | Out-Null }
                }
                else {
                    $currentProc = Start-Process -FilePath (Join-Path $tempDir ($app.Url.Split('/')[-1])) -ArgumentList $app.Args -PassThru
                }
            }
            catch {
                $appStates[$currentApp] = "Failed (Launch)"
                $currentApp = $null
                $currentProc = $null
            }
        }

        if ($dirty) { & $renderTable }
        Start-Sleep -Milliseconds 200
    }
    & $renderTable

    # --- Wait for background jobs and report what they actually did ---
    Write-Host "`n[System] Waiting for Config and Disk jobs to finish..." -ForegroundColor Cyan
    Wait-Job $configJob, $diskJob | Out-Null

    Write-Host "`n[Background Results]" -ForegroundColor Cyan
    foreach ($job in @($configJob, $diskJob)) {
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
    Remove-Job $configJob, $diskJob -Force | Out-Null

    # --- Reclaim the ~400MB of installers ---
    Write-Host "`n[System] Cleaning up temporary installation files..." -ForegroundColor Cyan
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

    $failed = @($AppCatalog | Where-Object { $appStates[$_.Name] -like "Failed*" })
    if ($failed.Count -gt 0) {
        Write-Host "`n[Completed with warnings] $($failed.Count) app(s) failed: $($failed.Name -join ', ')" -ForegroundColor Yellow
    }
    else {
        Write-Host "`n[Completed] The entire installation and setup process has finished!" -ForegroundColor Green
    }
}

# =========================================================================
# MENU ACTIONS
# =========================================================================
function Show-SystemInfo {
    Write-Host "`n[System] Collecting hardware information..." -ForegroundColor Cyan
    try {
        $logFile = Get-HardwareInfo
        Write-Host "[OK] Report saved to $logFile" -ForegroundColor Green
    }
    catch {
        Write-Host "[ERROR] Failed to collect system information: $_" -ForegroundColor Red
        return
    }

    # Office installs without desktop shortcuts, so create them if Office is present
    try {
        $officeApps = @{ "WINWORD.EXE" = "Word"; "EXCEL.EXE" = "Excel"; "POWERPNT.EXE" = "PowerPoint" }
        $officeRoots = @(
            "C:\Program Files\Microsoft Office\root\Office16",
            "C:\Program Files (x86)\Microsoft Office\root\Office16"
        )
        $desktop = [Environment]::GetFolderPath('Desktop')
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
    catch {
        Write-Host "[WARN] Could not create Office shortcuts: $($_.Exception.Message)" -ForegroundColor Yellow
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

# =========================================================================
# INTERACTIVE MENU UI
# =========================================================================
$MenuOptions = @(
    "1. Install App with Installer",
    "2. Install App with Winget",
    "3. Information",
    "4. Debloatware Windows",
    "5. Exit"
)

function Show-Menu {
    param([int]$SelectedIndex)

    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "                        MINI-APPS                         " -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""

    for ($i = 0; $i -lt $MenuOptions.Count; $i++) {
        if ($i -eq $SelectedIndex) {
            Write-Host "  > $($MenuOptions[$i]) " -ForegroundColor Black -BackgroundColor Cyan
        }
        else {
            Write-Host "    $($MenuOptions[$i]) " -ForegroundColor White
        }
    }
    Write-Host ""
    Write-Host "  Use Up/Down + Enter, or press a number key." -ForegroundColor DarkGray
}

function Read-MenuChoice {
    $selectedIndex = 0
    $count = $MenuOptions.Count

    while ($true) {
        Show-Menu -SelectedIndex $selectedIndex
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
        }
    }
}

# =========================================================================
# MAIN LOOP
# =========================================================================
while ($true) {
    $choice = Read-MenuChoice
    Clear-Host

    switch ($choice) {
        0 { Install-NecessaryApps -Method 'Installer' }
        1 { Install-NecessaryApps -Method 'Winget' }
        2 { Show-SystemInfo }
        3 { Invoke-Debloatware }
        4 {
            Write-Host "Exiting program. Have a great day!" -ForegroundColor Green
            exit
        }
    }

    Write-Host "`nPress any key to return to the Menu..." -ForegroundColor Gray
    [System.Console]::ReadKey($true) | Out-Null
}

