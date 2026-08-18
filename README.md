# MiniApps Windows Setup

Bộ công cụ PowerShell All-in-One giúp kỹ thuật viên tự động hóa quá trình thiết lập Windows, cài đặt phần mềm và tối ưu hóa hệ thống chỉ với một dòng lệnh.

## Hướng dẫn sử dụng nhanh

Mở **Windows PowerShell** (chạy bằng tài khoản thường cũng được, script tự yêu cầu quyền Admin) và gõ:

```powershell
irm https://raw.githubusercontent.com/mson-ssh/miniapps/main/Setup.ps1 | iex
```

`Setup.ps1` là file duy nhất cần thiết — toàn bộ phần cấu hình Windows, chia ổ đĩa và trích xuất
thông tin phần cứng đã được nhúng sẵn bên trong.

---

## Các tính năng chính (Interactive Menu)

### 1. Install App with Installer
- **Hỏi bản quyền Office trước khi chạy**: máy/khách có bản quyền thì cài Office 2024, không có
  thì WPS Office thế vào đúng vị trí đó trong danh sách. Hỏi một lần, trước khi tải bất cứ thứ gì.
- **Cấu hình Windows & chia ổ đĩa chạy ngầm**: song song với quá trình cài phần mềm. Kết quả
  từng mục được in ra cuối cùng (kể cả khi thất bại), không im lặng bỏ qua.
- **Smart Skip**: quét Registry (và cả thư mục AppData cho Zalo/Telegram). Phần mềm đã có sẵn
  sẽ được đánh dấu `Already Installed` và bỏ qua.
- **Tải và cài song song**: 11 gói tải cùng lúc qua Direct Link (Cloudflare R2), và cài ngay
  khi tải xong — nhiều app cài đồng thời.
- **Ngoại lệ tuần tự**: hai gói VC++ Redistributable x64/x86 không bao giờ cài cùng lúc với
  nhau (cả hai bọc MSI, tranh chấp mutex `_MSIExecute` của Windows Installer nên báo lỗi 1618).
  x64 chạy trước, x86 chờ. Chúng vẫn cài song song với mọi app khác.
- **Thử lại cùng nguồn**: link tải chết hoặc treo (canh đình trệ 90s) thì thử lại chính link đó
  tối đa 3 lần trước khi báo lỗi. Không tự đổi sang winget — mọi máy nhận cùng một bản cài.
- **Rescue winget tùy chọn**: cuối lượt, nếu còn app lỗi mà có Winget ID, script *hỏi* có muốn
  thử lại qua winget không. Mặc định Không. Máy chưa có winget sẽ được báo trước cái giá ~200MB.
- **Giao diện tự thích ứng**: bảng tiến trình có ký hiệu và màu theo trạng thái, % tải trực tiếp,
  thanh tiến trình tổng và thẻ tổng kết cuối. Terminal hiện đại dùng ký tự Unicode, console cũ tự
  hạ cấp sang ASCII. Ghi log phiên ra `Desktop\MiniApp-log.txt`.
- **Timeout riêng từng app**: 5 phút cho bộ cài silent, 30 phút cho Office 2024. Tiến trình kẹt
  bị kill để hàng đợi đi tiếp.
- **Dọn dẹp**: xóa toàn bộ file cài (~400MB) trong `%TEMP%\MiniAZ_Apps` sau khi xong.

Danh sách app: *Chrome, EVKey, K-Lite Codec Pack, Telegram, UltraViewer, WinRAR, Zalo, Zoom,
Office 2024 (hoặc WPS Office), VC++ Redistributable x64 & x86*.

### 2. Install App with Winget
Cài toàn bộ qua Winget thay vì Direct Link. App nào không có Winget ID vẫn dùng Direct Link.
Nếu Winget không cài được trên máy, menu này báo lỗi và thoát thay vì chạy vô ích.

### 3. Information
Trích xuất thông tin phần cứng (Model, Serial, CPU, RAM, Disk, GPU, độ phân giải), xuất ra
`Desktop\info.txt` rồi mở Notepad. Đưa luôn icon bộ office ra desktop, dò theo cái đang thực sự
có trên máy chứ không theo câu trả lời bản quyền lúc đầu:

- **Office**: tự tạo shortcut Word/Excel/PowerPoint từ đường dẫn exe trong `Program Files`.
- **WPS**: chép sẵn shortcut từ `Start Menu\Programs` ra desktop (WPS đã tự tạo sẵn ở đó).

### 4. Debloatware Windows
Chạy [Win11Debloat](https://github.com/raphire/win11debloat) ở chế độ `-RunDefaults -Silent`.

### 5. Optimize Install
Gộp mục 1 + 4 + 3 vào một phím. Chọn bằng số `5`, bằng mũi tên, hoặc gõ `A` rồi Enter.

Hỏi bản quyền Office trước, xong mới khởi động mọi thứ. **Debloat chạy song song** với quá trình
cài phần mềm (dạng background job như Config/Disk), kết quả in ra sau. Báo cáo phần cứng chạy
**cuối cùng** — cố ý, vì shortcut Word/Excel/PowerPoint cần bộ Office vừa cài đã nằm trên đĩa,
và Notepad không được bật đè lên bảng tiến trình đang vẽ.

---

## Lưu ý quan trọng

Menu 1, 2 và 5 sẽ **tự động thực hiện các thay đổi khó hoàn tác** ngay khi chọn, không hỏi lại:

- Chia lại phân vùng ổ C: (shrink C:, tạo D:/E:) — có các chốt an toàn: bỏ qua nếu ổ > 1100GB,
  bỏ qua nếu D:/E: đã tồn tại, hủy nếu C: còn dưới 30GB, và **giải mã BitLocker** trên C:
  để shrink được.
- Tắt UAC prompt, tắt System Restore và xóa toàn bộ shadow copy.
- Tắt Fast Startup, tắt hibernate, đặt DNS 1.1.1.1, timezone SE Asia.

Thiết kế cho máy mới cài Windows. **Không nên chạy trên máy đang có dữ liệu quan trọng.**

---

## Cấu trúc dự án

- `Setup.ps1` — file triển khai duy nhất, tự chứa toàn bộ logic.
- `config/` — bản độc lập của Config / disk / Get-info, dùng cho WinRAR SFX hoặc chạy riêng lẻ.
  `Setup.ps1` **không** gọi tới các file này nữa.
- `url.md` — danh sách Direct Link nguồn.
- `ARCHITECTURE.md` — chi tiết luồng hoạt động.
