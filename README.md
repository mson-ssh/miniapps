# MiniApps Windows Setup

Dự án này chứa các script PowerShell giúp tự động hóa quá trình cài đặt phần mềm trên Windows bằng công cụ Winget.

## Tính năng chính
- Tự động kiểm tra và cài đặt Winget nếu hệ thống chưa có.
- Cài đặt âm thầm (Silent mode) danh sách các phần mềm thông dụng: Google Chrome, WinRAR, Zalo, Telegram, K-Lite Codec Pack, UltraViewer, Zoom và các gói Visual C++ Redistributable (2012-2022).
- Chạy ngầm hoàn toàn, không yêu cầu người dùng tương tác trong quá trình cài đặt.

## Hướng dẫn sử dụng nhanh (Run via PowerShell)

Bạn không cần phải tải file về máy. Chỉ cần mở **Windows PowerShell** với quyền Quản trị viên (Run as Administrator) và chạy câu lệnh dưới đây:

```powershell
irm https://raw.githubusercontent.com/mson-ssh/miniapps/main/Setup.ps1 | iex
```

### Các Script hiện có:
- `Setup.ps1`: Kịch bản hoàn chỉnh, tích hợp thêm phần cài đặt tự động danh sách các phần mềm thiết yếu và thư viện cho máy tính.

---
*Lưu ý: Quá trình cài đặt có thể mất một vài phút tùy thuộc vào tốc độ mạng của bạn.*
