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

Đây là phần cốt lõi. Kiến trúc: **tải song song, cài song song, trừ các nhóm serial.**

```
Download (song song, N tasks)              Install (song song)
  WebClient.DownloadFileTaskAsync  ──►  $pending  ──►  $running (nhiều process cùng lúc)
                                                  └──► nhóm serial: chờ anh em cùng nhóm xong
```

`WebClient` stream trực tiếp ra đĩa nên không phình RAM như `Invoke-WebRequest`. App nào tải
xong là cài ngay, không chờ app khác.

Vòng lặp `while` mỗi 200ms xử lý 3 việc:

1. **Thu hoạch download xong** → vào `$pending`; nếu `IsFaulted` → thử Winget Fallback.
2. **Theo dõi mọi tiến trình trong `$running`** → kiểm tra `HasExited` + exit code, hoặc kill
   nếu quá timeout riêng của app đó.
3. **Khởi chạy tất cả app trong `$pending`**, trừ app đang bị nhóm serial chặn.

### Nhóm serial

`$SerialGroups` map tên app → tên nhóm. Hai app cùng nhóm không bao giờ chạy đồng thời với
nhau, nhưng vẫn song song với mọi app ngoài nhóm. Hiện chỉ có một nhóm `vcredist` gồm
`VCRedist x64` và `VCRedist x86`: cả hai là Burn bundle bọc MSI, tranh chấp mutex
`_MSIExecute` nên chạy cùng lúc sẽ lỗi 1618.

Thứ tự trong nhóm theo thứ tự khai báo trong `$AppCatalog` (`$orderIndex`), nên x64 luôn trước
x86. App bị chặn hiển thị `Waiting (<nhóm> busy)` và được thử lại mỗi nhịp.

Khóa nhóm được nhả khi thành viên đang chạy kết thúc **hoặc bị kill vì timeout** — đã kiểm thử
để một app treo không chặn vĩnh viễn app còn lại. Nếu một thành viên rơi vào Winget Fallback,
nó chiếm lại khóa trong lúc chạy winget.

Thêm nhóm mới chỉ cần một dòng, ví dụ hai app xung đột khác:

```powershell
$SerialGroups = @{
    "VCRedist x64" = "vcredist"
    "VCRedist x86" = "vcredist"
    "App Foo"      = "foogroup"
    "App Bar"      = "foogroup"
}
```

UI chỉ vẽ lại khi có thay đổi trạng thái (`$dirty`), dùng `[Console]::SetCursorPosition` để
cập nhật tại chỗ.

---

## 2b. Tầng giao diện

Đặt ở đầu script (trước cả khối UAC) để mọi thông báo, kể cả lỗi elevate, đều render đúng.

**Tự phát hiện khả năng terminal** — `$Script:CanReposition = -not [Console]::IsOutputRedirected`.
Khi output bị pipe hoặc redirect thì không có console buffer, `SetCursorPosition` sẽ ném "handle is
invalid". Mọi lần đặt lại con trỏ đi qua `Set-CursorTop` có guard, nên chạy được cả khi
`Setup.ps1 > log.txt`.

**Bộ ký tự hai tầng** — `$Script:Glyph`. Terminal thật dùng Unicode (`✔ ✗ ⊘ ● █ ╭─╮`), console cũ
hoặc redirect tự hạ cấp sang ASCII (`[OK] [X] [-] * # +-+`). Trạng thái luôn có **cả** ký hiệu và
màu, không bao giờ chỉ dựa vào màu — để người mù màu vẫn đọc được.

**Tiến trình tải** — `Register-ObjectEvent` trên `DownloadProgressChanged` của mỗi WebClient, ghi
vào hashtable `[hashtable]::Synchronized(@{})` vì handler chạy trên thread khác. Vòng render đọc ra
hiện `Downloading 45% 12MB/27MB`. Subscription được `Unregister-Event` sau khi engine xong.

**Transcript** — `Desktop\MiniApp-log.txt`, nằm ngoài `%TEMP%\MiniApp` nên không bị bước dọn xóa
mất. `$Script:LogPath` chỉ được set khi `Start-Transcript` thành công thật, nên giao diện không bao
giờ trỏ tới file không tồn tại (trường hợp policy chặn transcription hoặc Desktop bị OneDrive
chuyển hướng không ghi được).

## 3. Các cơ chế an toàn

**Smart Skip** — quét 3 nhánh registry Uninstall, cộng thêm kiểm tra trực tiếp thư mục cho Zalo
và Telegram (hai app này cài vào user profile, không ghi registry chuẩn), và `C:\EVKey` cho EVKey.

**Winget Fallback** — kích hoạt khi download fault hoặc installer trả exit code lỗi. Hashtable
`$fallbackUsed` đảm bảo mỗi app chỉ fallback đúng một lần, tránh vòng lặp vô hạn.

**Timeout riêng từng app** — khai báo qua `TimeoutSec` trong `$AppCatalog`, mỗi process trong
`$running` có deadline riêng. Silent installer 300s, Office 2024 1800s vì là bộ cài tương tác và
tải nội dung từ CDN. Quá hạn thì `Stop-Process -Force`. Vì Office giờ cài song song, nó không còn
chặn các app khác trong lúc anh bấm tay.

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
