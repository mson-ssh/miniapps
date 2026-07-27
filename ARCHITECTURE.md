# Kiến trúc Hoạt động của MiniApps Windows Setup

Tài liệu này giải thích luồng hoạt động và các cơ chế an toàn bên trong `Setup.ps1`.

---

## 1. Thành phần

`Setup.ps1` là file triển khai duy nhất, tự chứa (self-contained). Bên trong gồm:

| Khối | Vai trò |
|---|---|
| Auto-Elevate | Kiểm tra quyền Admin, tự leo quyền qua UAC |
| `$ConfigScript` | Scriptblock cấu hình Windows, chạy trong background job |
| `$DiskScript` | Scriptblock chia phân vùng ổ đĩa, chạy trong background job |
| `Get-HardwareInfo` | Trích xuất thông số phần cứng ra `Desktop\info.txt` |
| `$AppCatalog` | Bảng khai báo 11 phần mềm |
| `Install-NecessaryApps` | Engine tải/cài chính |
| Menu UI | Điều hướng bằng phím mũi tên hoặc phím số |

Thư mục `config/` vẫn giữ bản độc lập của 3 script trên để dùng cho WinRAR SFX. `Setup.ps1`
không phụ thuộc vào chúng — sửa một bên **không** tự động cập nhật bên kia.

---

## 2. Luồng hoạt động

### Giai đoạn 1: Auto-Elevate

Script kiểm tra `WindowsBuiltInRole::Administrator`. Nếu chưa có quyền:

- Chạy từ file thật (`$PSCommandPath` có giá trị) → relaunch chính file đó.
- Chạy từ RAM qua `irm | iex` → PowerShell **không cho script đọc source của chính nó**
  (`$MyInvocation.MyCommand.ScriptBlock` chỉ trả về lệnh gọi ngoài, `ScriptContents` rỗng), nên
  buộc phải tải lại từ `$SelfUrl`. Đây là lý do `$SelfUrl` được khai báo một chỗ duy nhất ở đầu
  file — đổi repo/branch thì chỉ sửa dòng đó.

### Giai đoạn 2: Chạy ngầm Config + Disk

`Start-Job` với `$ConfigScript` và `$DiskScript`. Hai job này emit các dòng
`[Config] <mục>: OK|FAILED` / `[Disk] ...`, được `Receive-Job` thu lại và in ra cuối quá trình.
Job crash cũng được bắt và in lý do. Không có lỗi nào bị ẩn.

### Giai đoạn 3: Khởi tạo Winget

`Initialize-Winget` cài Winget nếu thiếu (VCLibs + UI.Xaml + DesktopAppInstaller), bật
`BypassCertificatePinningForMicrosoftStore`. Trả về `$true/$false` — giá trị này quyết định
Winget Fallback có khả dụng hay không.

### Giai đoạn 4: Engine tải & cài

Đây là phần cốt lõi. Kiến trúc: **tải song song hoàn toàn, cài tuần tự qua hàng đợi.**

```
Download (song song, N tasks)          Install (tuần tự, 1 tại một thời điểm)
  WebClient.DownloadFileTaskAsync  ──►  $installQueue  ──►  Start-Process
```

Lý do tách: nhiều bộ cài chạy đồng thời sẽ tranh chấp Windows Installer service và registry.
Tải thì ngược lại, càng song song càng nhanh. `WebClient` stream trực tiếp ra đĩa nên không
phình RAM như `Invoke-WebRequest`.

Vòng lặp `while` mỗi 200ms xử lý 3 việc:

1. **Thu hoạch download xong** → vào `$installQueue`; nếu `IsFaulted` → thử Winget Fallback.
2. **Theo dõi tiến trình đang cài** → kiểm tra `HasExited` + exit code, hoặc kill nếu quá timeout.
3. **Lấy app tiếp theo từ hàng đợi** và khởi chạy.

UI chỉ vẽ lại khi có thay đổi trạng thái (`$dirty`), dùng `[Console]::SetCursorPosition` để
cập nhật tại chỗ.

---

## 3. Các cơ chế an toàn

**Smart Skip** — quét 3 nhánh registry Uninstall, cộng thêm kiểm tra trực tiếp thư mục cho Zalo
và Telegram (hai app này cài vào user profile, không ghi registry chuẩn), và `C:\EVKey` cho EVKey.

**Winget Fallback** — kích hoạt khi download fault hoặc installer trả exit code lỗi. Hashtable
`$fallbackUsed` đảm bảo mỗi app chỉ fallback đúng một lần, tránh vòng lặp vô hạn.

**Timeout riêng từng app** — khai báo qua `TimeoutSec` trong `$AppCatalog`. Silent installer 300s,
Office 2024 1800s vì là bộ cài tương tác và tải nội dung từ CDN. Quá hạn thì `Stop-Process -Force`.

**Exit code** — `$SuccessExitCodes = @(0, 3010, -1978335201)`: OK, cần reboot, đã cài sẵn.

Một điểm cần biết: `Start-Process -PassThru -NoNewWindow` trả về process object có `ExitCode`
là **null** ngay cả khi `HasExited` là true. Vì vậy nhánh winget dùng `-WindowStyle Hidden`
(vừa ẩn cửa sổ vừa đọc được exit code). Ngoài ra `$null -eq $code` vẫn được coi là thành công
để không báo lỗi sai.

**Chốt an toàn của Disk** — bỏ qua nếu ổ > 1100GB, bỏ qua nếu D:/E: đã tồn tại, bỏ qua nếu dung
lượng không thuộc class nào (256GB / 500GB / 1TB), hủy nếu C: sẽ tụt dưới 30GB. Chỉ *relabel* C:
chứ không format. Giải mã BitLocker và tắt hibernate trước khi shrink vì cả hai đều ghim file
ở cuối volume.

**Garbage Collection** — xóa `%TEMP%\MiniAZ_Apps` sau khi cài xong, thu hồi khoảng 400MB.

---

## 4. Mở rộng

Thêm/sửa/xóa phần mềm chỉ cần một dòng trong `$AppCatalog`:

```powershell
@{
   Name       = "Tên hiển thị"      # dùng làm key trạng thái, giữ ngắn (<= 13 ký tự cho vừa bảng)
   Url        = "Direct link"       # tên file lấy từ segment cuối của URL
   WingetId   = "Winget.Package.Id" # để trống nếu không có -> mất khả năng fallback
   Args       = "/S"                # để trống -> chạy chế độ tương tác, tự đưa cửa sổ lên trước
   MatchName  = "Regex Registry"    # để trống -> luôn cài, không Smart Skip
   TimeoutSec = 300                 # giới hạn thời gian cài
}
```

Lưu ý: `Name = "EVKey"` có xử lý đặc biệt (SFX WinRAR, chạy hidden rồi kết thúc ngay, không chờ
process).

---
*Cập nhật 27/07/2026 — toàn bộ nhánh của engine đã được kiểm thử bằng catalog giả:
thành công, download fault → fallback, exit code lỗi → fallback, timeout → kill, smart skip,
bộ cài tương tác, và nhánh fire-and-forget của EVKey.*
