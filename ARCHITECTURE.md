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
| `$DebloatScript` | Scriptblock Win11Debloat, chạy nền cho Optimize Install |
| `Get-HardwareInfo` | Trích xuất thông số phần cứng ra `Desktop\info.txt` |
| `$AppCatalog` | Bảng khai báo 11 phần mềm (`$WpsOffice` là bản thay cho ô Office) |
| `Install-NecessaryApps` | Engine tải/cài chính |
| `Invoke-OptimizeInstall` | Gộp menu 1 + 4 + 3 vào một lượt |
| Menu UI | Điều hướng bằng phím mũi tên, phím số, hoặc `A` |

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

### Giai đoạn 1b: Chọn bộ Office (chỉ chế độ Installer)

`Read-OfficeChoice` hỏi máy/khách có bản quyền Office không. Có → giữ nguyên `Office 2024`.
Không → `$WpsOffice` thay vào **đúng ô đó** của catalog, mọi thứ còn lại không đổi:

```powershell
$catalog = @($AppCatalog | ForEach-Object { if ($_.Name -eq "Office 2024") { $WpsOffice } else { $_ } })
```

Engine từ đây chỉ đọc `$catalog`, không đọc `$AppCatalog` nữa — bảng tiến trình, `$orderIndex`,
rescue winget và thẻ tổng kết đều tự khớp theo lựa chọn.

Hỏi trước khi `Start-Job` và trước khi tải, nên không có gì phải hủy giữa chừng. Phiên
non-interactive (output bị pipe/redirect) không bao giờ hỏi và giữ mặc định Office 2024 như cũ.

WPS Office là bộ cài NSIS 3.05 nên tham số silent là `/S`; nó cài theo từng user vào
`%LOCALAPPDATA%\Kingsoft\WPS Office` và ghi khóa gỡ cài đặt ở HKCU — nhánh registry mà
`Test-IsInstalled` vốn đã quét, nên Smart Skip chạy được không cần xử lý riêng.

### Giai đoạn 2: Chạy ngầm Config + Disk

`Start-Job` với `$ConfigScript` và `$DiskScript`. Hai job này emit các dòng
`[Config] <mục>: OK|FAILED` / `[Disk] ...`, được `Receive-Job` thu lại và in ra cuối quá trình.
Job crash cũng được bắt và in lý do. Không có lỗi nào bị ẩn.

### Giai đoạn 3: Khởi tạo Winget (chỉ khi chọn menu Winget)

`Initialize-Winget` cài Winget nếu thiếu (VCLibs + UI.Xaml + DesktopAppInstaller), bật
`BypassCertificatePinningForMicrosoftStore`. **Chỉ được gọi khi `$Method = 'Winget'`.** Chế độ
Installer tuyệt đối không đụng tới Winget — dựng Winget sẽ tải ~200MB appx và thay đổi máy khách
mà không được hỏi. Nếu chọn Winget mà máy không dựng được, menu báo lỗi và thoát.

### Giai đoạn 4: Engine tải & cài

Đây là phần cốt lõi. Kiến trúc: **tải song song, cài song song, trừ các nhóm serial.**

```
Download (song song, N tasks)              Install (song song)
  WebClient.DownloadFileTaskAsync  ──►  $pending  ──►  $running (nhiều process cùng lúc)
                                                  └──► nhóm serial: chờ anh em cùng nhóm xong
```

`WebClient` stream trực tiếp ra đĩa nên không phình RAM như `Invoke-WebRequest`. App nào tải
xong là cài ngay, không chờ app khác.

Vòng lặp `while` mỗi 200ms xử lý 4 việc:

0. **Canh đình trệ** → `WebClient` không có thuộc tính `Timeout`, và download qua kết nối
   half-open sẽ không bao giờ hoàn tất cũng không fault. Nên byte nhận được được theo dõi: nếu
   đứng yên quá `$DlStallSec` (90s) thì `CancelAsync` → task chuyển sang faulted → vào đường retry.
1. **Thu hoạch download xong** → vào `$pending`; nếu `IsFaulted`/`IsCanceled` → thử lại **chính
   link đó** (`$MaxDlTries` = 3 lần, backoff 0s→2s→4s), hết lượt thì `Failed (Download)`. Không
   tự chuyển sang winget — mọi máy nhận cùng một artifact.
2. **Theo dõi mọi tiến trình trong `$running`** → kiểm tra `HasExited` + exit code, hoặc kill
   nếu quá timeout riêng của app đó. Exit code lỗi báo nguyên trạng, không fallback.
3. **Khởi chạy tất cả app trong `$pending`**, trừ app đang bị nhóm serial chặn.

Sau vòng lặp, chế độ Installer đề nghị **rescue pass tùy chọn**: các app failed *và* có `WingetId`
được liệt kê, hỏi `y/N` trước khi thử winget. Mặc định No; phiên non-interactive không bao giờ
hỏi cũng không tự đồng ý. Đây là chỗ duy nhất Installer mode có thể động tới winget, và chỉ khi
người dùng chủ động đồng ý.

### Nhóm serial

`$SerialGroups` map tên app → tên nhóm. Hai app cùng nhóm không bao giờ chạy đồng thời với
nhau, nhưng vẫn song song với mọi app ngoài nhóm. Hiện chỉ có một nhóm `vcredist` gồm
`VCRedist x64` và `VCRedist x86`: cả hai là Burn bundle bọc MSI, tranh chấp mutex
`_MSIExecute` nên chạy cùng lúc sẽ lỗi 1618.

Thứ tự trong nhóm theo thứ tự khai báo trong `$AppCatalog` (`$orderIndex`), nên x64 luôn trước
x86. App bị chặn hiển thị `Waiting (<nhóm> busy)` và được thử lại mỗi nhịp.

Khóa nhóm được nhả khi thành viên đang chạy kết thúc **hoặc bị kill vì timeout** — đã kiểm thử
để một app treo không chặn vĩnh viễn app còn lại.

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

### Giai đoạn 5: Optimize Install (menu 5 / phím `A`)

`Invoke-OptimizeInstall` chạy menu 1 + 4 + 3 trong một lượt. Thứ tự có chủ đích:

1. `Read-OfficeChoice` hỏi trước, ngay đầu — không có gì khởi động trước khi câu hỏi được trả lời.
2. `$DebloatScript` vào `Start-Job` → chạy **song song** với toàn bộ engine cài đặt.
3. `Install-NecessaryApps -OfficeLicensed $licensed` chạy foreground, giữ độc quyền console.
4. Thu `$debloatJob` với cùng mốc `$JobTimeoutSec` như Config/Disk, in kết quả.
5. `Show-SystemInfo` **cuối cùng**.

Câu trả lời Office được truyền xuống qua tham số `-OfficeLicensed` thay vì hỏi lại. Tham số khai
báo `[object]` chứ không phải `[bool]`: `$null` mang nghĩa "chưa ai hỏi, hỏi ngay bây giờ", còn
`[bool]` sẽ âm thầm biến `$null` thành `$false` và bỏ Office mà không hỏi ai. Menu 1 gọi không kèm
tham số nên vẫn tự hỏi như cũ.

Hai điểm cố ý **không** chạy song song:

- **Báo cáo phần cứng chạy cuối.** `Show-SystemInfo` tạo shortcut Word/Excel/PowerPoint bằng cách
  dò `Program Files\Microsoft Office`; chạy song song thì Office còn đang cài, không dò thấy gì và
  shortcut lặng lẽ không được tạo. Nó còn bật Notepad — đè lên bảng tiến trình đang neo vị trí
  bằng `SetCursorPosition`.
- **Output của Win11Debloat bị nuốt** (`*>&1 | Out-Null`) vì job chạy cùng lúc với bảng tiến trình
  live; chỉ còn đúng một dòng `[Debloat] ...: OK|FAILED`. Exception vẫn được `catch` và báo nguyên
  văn, nên lỗi không bị giấu.

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

**Retry cùng nguồn** — download fault/cancel thì thử lại chính link đó tối đa `$MaxDlTries` (3)
lần, backoff 0s→2s→4s (`$retryAt`). Không bao giờ đổi sang nguồn khác giữa chừng, nên mọi máy
nhận đúng một artifact và lỗi hạ tầng (link R2 chết) hiện ra thay vì bị winget che.

**Canh đình trệ download** — `$DlStallSec` (90s). Vì `WebClient` không có timeout và kết nối
half-open treo vô hạn, byte nhận được được theo dõi mỗi nhịp; đứng yên quá ngưỡng thì `CancelAsync`
→ vào retry. Đo đình trệ chứ không đo tổng thời gian, nên Office 4GB trên mạng yếu vẫn an toàn.

**Timeout riêng từng app** — khai báo qua `TimeoutSec` trong `$AppCatalog`, mỗi process trong
`$running` có deadline riêng. Silent installer 300s, Office 2024 1800s vì là bộ cài tương tác và
tải nội dung từ CDN. Quá hạn thì `Stop-Process -Force`. Vì Office giờ cài song song, nó không còn
chặn các app khác trong lúc anh bấm tay.

**Job có giới hạn** — `Wait-Job -Timeout $JobTimeoutSec` (3600s); job còn chạy thì `Stop-Job`.
Vòng chờ giải mã BitLocker trong `$DiskScript` cũng có mốc 60 phút, quá hạn thì bỏ qua phân vùng.
Cả hai chặn kịch bản một job kẹt làm treo toàn bộ phiên cài.

**Exit code** — `$SuccessExitCodes = @(0, 3010, -1978335201)`: OK, cần reboot, đã cài sẵn.
Riêng winget dùng `$WingetSuccessExitCodes` bổ sung các mã "đã cài sẵn / không có bản áp dụng"
(`-1978335189`, `-1978335212`, `-1978335216`) để app đã có sẵn không bị báo nhầm là lỗi.

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
   WingetId   = "Winget.Package.Id" # để trống -> không thể rescue qua winget khi link lỗi
   Args       = "/S"                # để trống -> chạy chế độ tương tác, tự đưa cửa sổ lên trước
   MatchName  = "Regex Registry"    # để trống -> luôn cài, không Smart Skip
   TimeoutSec = 300                 # giới hạn thời gian cài
}
```

Lưu ý: `Name = "EVKey"` có xử lý đặc biệt (SFX WinRAR, chạy hidden rồi kết thúc ngay, không chờ
process).

---
*Cập nhật 30/07/2026 (v2) — toàn bộ nhánh của engine đã được kiểm thử bằng catalog giả:
thành công, download fault → retry cùng link → Failed, download treo → canh đình trệ → cancel →
retry, exit code lỗi báo nguyên trạng (không fallback), rescue winget tùy chọn có xác nhận, mã
"đã cài sẵn" của winget tính là thành công, job kẹt bị Stop-Job đúng hạn, timeout → kill, smart
skip, bộ cài tương tác, và nhánh fire-and-forget của EVKey.*
