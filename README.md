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
- **Cấu hình Windows & chia ổ đĩa chạy ngầm**: song song với quá trình cài phần mềm. Kết quả
  từng mục được in ra cuối cùng (kể cả khi thất bại), không im lặng bỏ qua.
- **Smart Skip**: quét Registry (và cả thư mục AppData cho Zalo/Telegram). Phần mềm đã có sẵn
  sẽ được đánh dấu `Already Installed` và bỏ qua.
- **Tải song song, cài tuần tự**: 11 gói được tải cùng lúc qua Direct Link (Cloudflare R2),
  nhưng chỉ cài từng cái một để các bộ cài không tranh chấp Windows Installer.
- **Winget Fallback**: nếu Direct Link chết hoặc bộ cài trả về exit code lỗi, app đó tự động
  được cài lại qua `winget` (mỗi app chỉ fallback một lần).
- **Timeout riêng từng app**: 5 phút cho bộ cài silent, 30 phút cho Office 2024. Tiến trình kẹt
  bị kill để hàng đợi đi tiếp.
- **Dọn dẹp**: xóa toàn bộ file cài (~400MB) trong `%TEMP%\MiniAZ_Apps` sau khi xong.

Danh sách app: *Chrome, EVKey, K-Lite Codec Pack, Telegram, UltraViewer, WinRAR, Zalo, Zoom,
Office 2024, VC++ Redistributable x64 & x86*.

### 2. Install App with Winget
Cài toàn bộ qua Winget thay vì Direct Link. App nào không có Winget ID vẫn dùng Direct Link.
Nếu Winget không cài được trên máy, menu này báo lỗi và thoát thay vì chạy vô ích.

### 3. Information
Trích xuất thông tin phần cứng (Model, Serial, CPU, RAM, Disk, GPU, độ phân giải), xuất ra
`Desktop\info.txt` rồi mở Notepad. Tự tạo shortcut Word/Excel/PowerPoint nếu tìm thấy Office.

### 4. Debloatware Windows
Chạy [Win11Debloat](https://github.com/raphire/win11debloat) ở chế độ `-RunDefaults -Silent`.

---

## Lưu ý quan trọng

Menu 1 và 2 sẽ **tự động thực hiện các thay đổi khó hoàn tác** ngay khi chọn, không hỏi lại:

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
