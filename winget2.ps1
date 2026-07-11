# Thiet lap giao thuc bao mat TLS 1.2 de tai file tu GitHub kho khong bi chan
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -------------------------------------------------------------------------
# BUOC 1: KIEM TRA VA CAI DAT/CAP NHAT WINGET IM LANG
# -------------------------------------------------------------------------
$wingetCheck = Get-Command winget -ErrorAction SilentlyContinue

if (-not $wingetCheck) {
    Write-Host "[He thong] Chua co Winget hoac phien ban qua cu. Bat dau tu dong thiet lap ngam..." -ForegroundColor Yellow
    
    $tempDir = "$env:TEMP\winget-init"
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }
    
    $desktopAppInstallerUrl = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
    $uiXamlUrl = "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx"
    $vclibsUrl = "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx"
    
    try {
        # Tai cac goi phu thuoc ngam
        Invoke-WebRequest -Uri $vclibsUrl -OutFile "$tempDir\VCLibs.appx" -UseBasicParsing
        Invoke-WebRequest -Uri $uiXamlUrl -OutFile "$tempDir\UiXaml.appx" -UseBasicParsing
        Invoke-WebRequest -Uri $desktopAppInstallerUrl -OutFile "$tempDir\Winget.msixbundle" -UseBasicParsing
        
        # Dang ky goi vao thiet lap Windows (hoan toan im lang)
        Add-AppxPackage -Path "$tempDir\VCLibs.appx" -ErrorAction SilentlyContinue
        Add-AppxPackage -Path "$tempDir\UiXaml.appx" -ErrorAction SilentlyContinue
        Add-AppxPackage -Path "$tempDir\Winget.msixbundle" -ErrorAction SilentlyContinue
        
        # Don dep file rac
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        
        # Cap nhat kho du lieu am tham
        & winget source update --quiet | Out-Null
        Write-Host "[OK] Khoi tao Winget moi nhat thanh cong." -ForegroundColor Green
    }
    catch {
        Write-Host "[LOI] Khong the tu dong cai Winget: $_" -ForegroundColor Red
        Exit
    }
}
else {
    Write-Host "[He thong] Winget da san sang. Dang lam moi du lieu kho phan mem..." -ForegroundColor Green
    & winget source update --quiet | Out-Null
}

# -------------------------------------------------------------------------
# BUOC 2: CAI DAT DANH SACH PHAN MEM SILENT HOAN TOAN
# -------------------------------------------------------------------------
$apps = @(
    "Google.Chrome",
    "CodecGuide.K-LiteCodecPack.Mega",
    "Telegram.TelegramDesktop",
    "DucFabulous.UltraViewer",
    "RARLab.WinRAR",
    "VNGCorp.Zalo",
    "Zoom.Zoom",
    "Microsoft.VCRedist.2012.x86",
    "Microsoft.VCRedist.2012.x64",
    "Microsoft.VCRedist.2013.x86",
    "Microsoft.VCRedist.2013.x64",
    "Microsoft.VCRedist.2015+.x86",
    "Microsoft.VCRedist.2015+.x64"
)

Write-Host "`n[Bat dau] Tien hanh cai dat $($apps.Count) phan mem che do Silent..." -ForegroundColor Cyan

foreach ($app in $apps) {
    Write-Host "-> Dang cai dat: $app" -ForegroundColor Yellow
    
    # Bo sung tham so --disable-interactivity de chan hoan toan cac cua so cua bo cai dat nhay len
    $process = Start-Process winget -ArgumentList "install --id $app --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements" -NoNewWindow -PassThru -Wait
    
    if ($process.ExitCode -eq 0) {
        Write-Host "   [OK] Cài dat thanh cong: $app" -ForegroundColor Green
    }
    else {
        # Ma loi 0x8A15001F thuong la do phan mem da co san phien ban moi nhat tren may
        if ($process.ExitCode -eq -1978335201) {
            Write-Host "   [Ghi chu] $app da co san phien ban moi nhat tren he thong." -ForegroundColor Blue
        }
        else {
            Write-Host "   [LOI] Gap loi khi cai $app. Ma loi (Exit Code): $($process.ExitCode)" -ForegroundColor Red
        }
    }
}

Write-Host "`n[Hoan tat] Toan bo qua trinh cai dat ket thuc!" -ForegroundColor Cyan