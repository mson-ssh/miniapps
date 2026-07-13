# Configure TLS 1.2 to prevent GitHub downloads from being blocked
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# =========================================================================
# MINIAZ SETUP SCRIPT
# =========================================================================
$ProgressPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
# GLOBAL FUNCTIONS
# =========================================================================

# =========================================================================
# AUTO-ELEVATE TO ADMINISTRATOR (UAC PROMPT)
# =========================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($PSCommandPath) {
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    }
    else {
        $tempScript = "$env:TEMP\Setup_elevated.ps1"
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/mson-ssh/miniapps/main/Setup.ps1" -OutFile $tempScript -UseBasicParsing
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
    }
    exit
}

function Install-NecessaryApps {
    param([string]$Method = 'Installer')
    Write-Host "`n[System] Initializing parallel processes (App Installation, Config, Disk)..." -ForegroundColor Cyan
    
    function Test-IsInstalled {
        param([string]$pattern)
        if (-not $pattern) { return $false }
        $paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        $installed = Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $pattern }
        if ($installed) { return $true }
        
        # Explicit checks for local AppData installations like Zalo and Telegram
        if ($pattern -match "Zalo" -and (Test-Path "$env:LOCALAPPDATA\Programs\Zalo\Zalo.exe")) { return $true }
        if ($pattern -match "Telegram" -and (Test-Path "$env:APPDATA\Telegram Desktop\Telegram.exe")) { return $true }
        
        return $false
    }
    
    # 1. Run Config.ps1 and disk.ps1 from GitHub silently in parallel
    Write-Host "`n[System] Initiating Config and Disk Setup in background..." -ForegroundColor Magenta
    $configJob = Start-Job -ScriptBlock { & ([scriptblock]::Create((irm "https://raw.githubusercontent.com/mson-ssh/miniapps/main/config/Config.ps1"))) -Silent }
    $diskJob = Start-Job -ScriptBlock { & ([scriptblock]::Create((irm "https://raw.githubusercontent.com/mson-ssh/miniapps/main/config/disk.ps1"))) -Silent }
    Write-Host "-> Background processes Config.ps1 and disk.ps1 activated!" -ForegroundColor Gray

    # 2. Check and install Winget silently (Used for Fallback)
    $wingetCheck = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCheck) {
        Write-Host "-> Winget not found. Starting silent Winget initialization..." -ForegroundColor Yellow
        $tempDir = "$env:TEMP\winget-init"
        if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }
        
        $desktopAppInstallerUrl = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
        $uiXamlUrl = "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx"
        $vclibsUrl = "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx"
        
        try {
            Invoke-WebRequest -Uri $vclibsUrl -OutFile "$tempDir\VCLibs.appx" -UseBasicParsing
            Invoke-WebRequest -Uri $uiXamlUrl -OutFile "$tempDir\UiXaml.appx" -UseBasicParsing
            Invoke-WebRequest -Uri $desktopAppInstallerUrl -OutFile "$tempDir\Winget.msixbundle" -UseBasicParsing
            
            Add-AppxPackage -Path "$tempDir\VCLibs.appx" -ErrorAction SilentlyContinue
            Add-AppxPackage -Path "$tempDir\UiXaml.appx" -ErrorAction SilentlyContinue
            Add-AppxPackage -Path "$tempDir\Winget.msixbundle" -ErrorAction SilentlyContinue
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            & winget settings --enable BypassCertificatePinningForMicrosoftStore --accept-source-agreements | Out-Null
            & winget source update --quiet | Out-Null
        }
        catch { }
    }
    else {
        & winget settings --enable BypassCertificatePinningForMicrosoftStore --accept-source-agreements | Out-Null
        & winget source update --quiet | Out-Null
    }

    # 3. Install applications utilizing Direct Links from R2 Cloudflare
    $parallelApps = @(
        @{ Name = "EVKey"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/EVKey.exe"; WingetId = ""; Args = "-s"; MatchName = "" },
        @{ Name = "Chrome"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/chrome.exe"; WingetId = "Google.Chrome"; Args = "/silent /install"; MatchName = "Google Chrome" },
        @{ Name = "Klite"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/klite.exe"; WingetId = "CodecGuide.K-LiteCodecPack.Mega"; Args = "/verysilent /norestart /suppressmsgboxes"; MatchName = "K-Lite Codec Pack" },
        @{ Name = "Telegram"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/tele.exe"; WingetId = "Telegram.TelegramDesktop"; Args = "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES"; MatchName = "Telegram Desktop" },
        @{ Name = "Ultraview"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/ultrav.exe"; WingetId = "DucFabulous.UltraViewer"; Args = "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES"; MatchName = "UltraViewer" },
        @{ Name = "WinRAR"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/winrar.exe"; WingetId = "RARLab.WinRAR"; Args = "/S"; MatchName = "WinRAR" },
        @{ Name = "Zalo"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/zalo.exe"; WingetId = "VNGCorp.Zalo"; Args = "/S"; MatchName = "Zalo" },
        @{ Name = "Zoom"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/zoom.exe"; WingetId = "Zoom.Zoom"; Args = "/silent"; MatchName = "Zoom" },
        @{ Name = "Office 2024"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/OfficeSetup.exe"; WingetId = ""; Args = ""; MatchName = "Microsoft Office|Microsoft 365" }
    )

    $sequentialApps = @(
        @{ Name = "VCRedist x64"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/VC_redist.x64.exe"; WingetId = "Microsoft.VCRedist.2015+.x64"; Args = "/install /quiet /norestart"; MatchName = "Microsoft Visual C\+\+.*x64" },
        @{ Name = "VCRedist x86"; Url = "https://pub-50d6cf4af6964541b0621bbc9bc26690.r2.dev/VC_redist.x86.exe"; WingetId = "Microsoft.VCRedist.2015+.x86"; Args = "/install /quiet /norestart"; MatchName = "Microsoft Visual C\+\+.*x86" }
    )

    $allApps = $parallelApps + $sequentialApps
    $appStates = @{}
    $downloadTasks = @{}
    $webClients = @{}
    $installQueue = @()
    
    $tempDir = "$env:TEMP\MiniAZ_Apps"
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
    
    # C# UI helper to bring window to front
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

    Write-Host "`n[Progress] Parallel Downloading & Sequential Installing..." -ForegroundColor Cyan
    $startTop = [Console]::CursorTop
    foreach ($app in $allApps) {
        if ($app.MatchName -and (Test-IsInstalled $app.MatchName)) {
            $appStates[$app.Name] = "Already Installed"
        } elseif ($app.Name -eq "EVKey" -and (Test-Path "C:\EVKey")) {
            $appStates[$app.Name] = "Already Installed"
        } else {
            if ($Method -eq 'Winget' -and $app.WingetId) {
                $appStates[$app.Name] = "Waiting to Install"
                $installQueue += $app.Name
            } else {
                $appStates[$app.Name] = "Downloading"
                $fileName = $app.Url.Split('/')[-1]
                $tempExe = "$tempDir\$fileName"
                
                # Start parallel download task via C# WebClient to bypass RAM buffering
                $wc = New-Object System.Net.WebClient
                $webClients[$app.Name] = $wc
                $downloadTasks[$app.Name] = $wc.DownloadFileTaskAsync($app.Url, $tempExe)
            }
        }
        Write-Host ("   [+] {0} - {1}" -f $app.Name.PadRight(12), $appStates[$app.Name]) -ForegroundColor Yellow
    }

    $currentInstallApp = $null
    $currentInstallProc = $null
    $installTimeoutTime = $null

    while ($downloadTasks.Count -gt 0 -or $installQueue.Count -gt 0 -or $currentInstallApp) {
        $uiUpdated = $false
        
        # 1. Check Download Tasks
        $completedDownloads = @()
        foreach ($key in $downloadTasks.Keys) {
            $task = $downloadTasks[$key]
            if ($task.IsCompleted) {
                if ($task.IsFaulted) {
                    $appStates[$key] = "Failed (Download)"
                } else {
                    $appStates[$key] = "Waiting to Install"
                    $installQueue += $key
                }
                $completedDownloads += $key
                $uiUpdated = $true
            }
        }
        foreach ($key in $completedDownloads) {
            $downloadTasks.Remove($key)
            $webClients[$key].Dispose()
        }
        
        # 2. Check current install process
        if ($currentInstallApp) {
            if ($currentInstallProc) {
                if ($currentInstallProc.HasExited) {
                    if ($currentInstallProc.ExitCode -eq 0 -or $currentInstallProc.ExitCode -eq 3010 -or $currentInstallProc.ExitCode -eq -1978335201) {
                        $appStates[$currentInstallApp] = "Done"
                    } else {
                        $appStates[$currentInstallApp] = "Failed (ExitCode: $($currentInstallProc.ExitCode))"
                    }
                    $currentInstallApp = $null
                    $currentInstallProc = $null
                    $uiUpdated = $true
                } elseif ($installTimeoutTime -and (Get-Date) -gt $installTimeoutTime) {
                    $currentInstallProc | Stop-Process -Force -ErrorAction SilentlyContinue
                    $appStates[$currentInstallApp] = "Failed (Timeout)"
                    $currentInstallApp = $null
                    $currentInstallProc = $null
                    $uiUpdated = $true
                }
            } else {
                # Process was launched without process object (e.g., EVKey hidden)
                $appStates[$currentInstallApp] = "Done"
                $currentInstallApp = $null
                $uiUpdated = $true
            }
        }
        
        # 3. Pick next install from queue
        if (-not $currentInstallApp -and $installQueue.Count -gt 0) {
            $currentInstallApp = $installQueue[0]
            # Remove from queue
            if ($installQueue.Count -eq 1) { $installQueue = @() } else { $installQueue = $installQueue[1..($installQueue.Count - 1)] }
            
            $appStates[$currentInstallApp] = "Installing"
            $uiUpdated = $true
            $installTimeoutTime = (Get-Date).AddSeconds(300) # 5 minutes timeout per app
            
            $appObj = $allApps | Where-Object { $_.Name -eq $currentInstallApp }
            $fileName = $appObj.Url.Split('/')[-1]
            $tempExe = "$tempDir\$fileName"
            
            if ($Method -eq 'Winget' -and $appObj.WingetId) {
                $currentInstallProc = Start-Process winget -ArgumentList "install --id $($appObj.WingetId) --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements" -PassThru -NoNewWindow
            } else {
                if ($appObj.Name -eq "EVKey") {
                    Start-Process -FilePath $tempExe -ArgumentList $appObj.Args -WindowStyle Hidden
                    Start-Sleep -Seconds 3
                    $currentInstallProc = $null
                } else {
                    if ([string]::IsNullOrWhiteSpace($appObj.Args)) {
                        $currentInstallProc = Start-Process -FilePath $tempExe -PassThru
                        # Bring interactive installers to foreground
                        Start-Sleep -Seconds 3
                        $hwnd = [Win32UI]::FindWindow($null, "Microsoft Office")
                        if ($hwnd -ne [IntPtr]::Zero) { [Win32UI]::SetForegroundWindow($hwnd) | Out-Null }
                    } else {
                        $currentInstallProc = Start-Process -FilePath $tempExe -ArgumentList $appObj.Args -PassThru
                    }
                }
            }
        }
        
        # Update UI if anything changed
        if ($uiUpdated) {
            [Console]::SetCursorPosition(0, $startTop)
            foreach ($app in $allApps) {
                $line = "   [+] {0} - {1}" -f $app.Name.PadRight(12), $appStates[$app.Name]
                Write-Host $line.PadRight(80) -ForegroundColor Yellow
            }
        }
        
        Start-Sleep -Milliseconds 200
    }
    Wait-Job $configJob, $diskJob | Out-Null
    Remove-Job $configJob, $diskJob | Out-Null
    Write-Host "`n[Completed] The entire installation and setup process has finished!" -ForegroundColor Green
}

function Show-SystemInfo {
    Write-Host "`n[System] Downloading and running system information script..." -ForegroundColor Cyan
    try {
        irm https://raw.githubusercontent.com/mson-ssh/miniapps/main/config/Get-info.ps1 | iex
        
        # Create Office shortcuts if they exist
        $officePaths = @(
            "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE",
            "C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE",
            "C:\Program Files\Microsoft Office\root\Office16\POWERPNT.EXE",
            "C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE",
            "C:\Program Files (x86)\Microsoft Office\root\Office16\EXCEL.EXE",
            "C:\Program Files (x86)\Microsoft Office\root\Office16\POWERPNT.EXE"
        )
        $wshShell = New-Object -ComObject WScript.Shell
        $desktop = [Environment]::GetFolderPath('Desktop')
        foreach ($path in $officePaths) {
            if (Test-Path $path) {
                $name = (Get-Item $path).BaseName
                if ($name -eq "WINWORD") { $name = "Word" }
                elseif ($name -eq "EXCEL") { $name = "Excel" }
                elseif ($name -eq "POWERPNT") { $name = "PowerPoint" }
                
                $shortcutPath = Join-Path $desktop "$name.lnk"
                if (-not (Test-Path $shortcutPath)) {
                    $shortcut = $wshShell.CreateShortcut($shortcutPath)
                    $shortcut.TargetPath = $path
                    $shortcut.Save()
                }
            }
        }

        Write-Host "[OK] Executed successfully, exported file to Desktop, and created Office shortcuts (if found)!" -ForegroundColor Green
    }
    catch {
        Write-Host "[ERROR] Failed to run System Information tasks: $_" -ForegroundColor Red
    }
}

function Run-Debloatware {
    Write-Host "`n[System] Launching Windows Debloatware utility (Silent Default Profile)..." -ForegroundColor Cyan
    try {
        & ([scriptblock]::Create((irm "https://debloat.raphi.re/"))) -RunDefaults -Silent
        Write-Host "`n[OK] Debloatware utility exited successfully!" -ForegroundColor Green
    }
    catch {
        Write-Host "`n[ERROR] Failed to run Debloatware utility: $_" -ForegroundColor Red
    }
}

# =========================================================================
# INTERACTIVE MENU UI
# =========================================================================

function Draw-Menu {
    param ($selectedIndex)
    
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "                        MINI-APPS                         " -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""

    $options = @(
        "1. Install App with Installer",
        "2. Install App with Winget",
        "3. Information",
        "4. Debloatware Windows",
        "5. Exit"
    )

    for ($i = 0; $i -lt $options.Count; $i++) {
        if ($i -eq $selectedIndex) {
            Write-Host "  > $($options[$i]) " -ForegroundColor Black -BackgroundColor Cyan
        }
        else {
            Write-Host "    $($options[$i]) " -ForegroundColor White
        }
    }
    Write-Host ""
}

function Run-Menu {
    $selectedIndex = 0
    $optionsCount = 5

    while ($true) {
        Draw-Menu -selectedIndex $selectedIndex

        $keyInfo = [System.Console]::ReadKey($true)
        $key = $keyInfo.Key

        if ($key -eq 'UpArrow') {
            $selectedIndex--
            if ($selectedIndex -lt 0) { $selectedIndex = $optionsCount - 1 }
        }
        elseif ($key -eq 'DownArrow') {
            $selectedIndex++
            if ($selectedIndex -ge $optionsCount) { $selectedIndex = 0 }
        }
        elseif ($key -eq 'D1' -or $key -eq 'NumPad1') { $selectedIndex = 0; break }
        elseif ($key -eq 'D2' -or $key -eq 'NumPad2') { $selectedIndex = 1; break }
        elseif ($key -eq 'D3' -or $key -eq 'NumPad3') { $selectedIndex = 2; break }
        elseif ($key -eq 'D4' -or $key -eq 'NumPad4') { $selectedIndex = 3; break }
        elseif ($key -eq 'D5' -or $key -eq 'NumPad5') { $selectedIndex = 4; break }
        elseif ($key -eq 'Enter') {
            break
        }
        elseif ($key -eq 'Escape') {
            $selectedIndex = 4; break
        }
    }
    return $selectedIndex
}

# =========================================================================
# MAIN LOOP
# =========================================================================

while ($true) {
    $choice = Run-Menu
    
    Clear-Host
    if ($choice -eq 0) {
        Install-NecessaryApps -Method 'Installer'
    }
    elseif ($choice -eq 1) {
        Install-NecessaryApps -Method 'Winget'
    }
    elseif ($choice -eq 2) {
        Show-SystemInfo
    }
    elseif ($choice -eq 3) {
        Run-Debloatware
    }
    elseif ($choice -eq 4) {
        Write-Host "Exiting program. Have a great day!" -ForegroundColor Green
        exit
    }

    Write-Host "`nPress any key to return to Menu..." -ForegroundColor Gray
    [System.Console]::ReadKey($true) | Out-Null
}
