# MiniApps Windows Setup

Dự án này chứa các script PowerShell giúp tự động hóa quá trình cài đặt phần mềm trên Windows bằng công cụ Winget.

## Tính năng chính
- Tự động kiểm tra và cài đặt Winget nếu hệ thống chưa có.
- Cài đặt âm thầm (Silent mode) danh sách các phần mềm thông dụng: Google Chrome, WinRAR, Zalo, Telegram, UniKey, K-Lite Codec Pack, UltraViewer, Zoom...
- Chạy ngầm hoàn toàn, không yêu cầu người dùng tương tác trong quá trình cài đặt.

## Hướng dẫn sử dụng nhanh (Run via PowerShell)

Bạn không cần phải tải file về máy. Chỉ cần mở **Windows PowerShell** với quyền Quản trị viên (Run as Administrator) và chạy câu lệnh dưới đây:

```powershell
irm https://raw.githubusercontent.com/mson-ssh/miniapps/main/winget2.ps1 | iex
```

### Các Script hiện có:
- `winget.ps1`: Kịch bản nền tảng cơ bản, dùng để setup Winget.
- `winget2.ps1`: Kịch bản hoàn chỉnh, tích hợp thêm phần cài đặt tự động 8 phần mềm thiết yếu cho máy tính.

---
*Lưu ý: Quá trình cài đặt có thể mất một vài phút tùy thuộc vào tốc độ mạng của bạn.*
