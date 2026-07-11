# MiniApps Windows Setup

Dự án này là bộ công cụ PowerShell All-in-One giúp kỹ thuật viên và người dùng tự động hóa quá trình thiết lập Windows, cài đặt phần mềm và tối ưu hóa hệ thống chỉ với một dòng lệnh duy nhất.

## 🚀 Hướng dẫn sử dụng nhanh

Bạn không cần phải tải bất kỳ file nào về máy. Chỉ cần mở **Windows PowerShell** (chạy bằng tài khoản thường cũng được, script sẽ tự động yêu cầu quyền Admin) và gõ câu lệnh dưới đây:

```powershell
irm https://raw.githubusercontent.com/mson-ssh/miniapps/main/Setup.ps1 | iex
```

---

## 📋 Các tính năng chính (Interactive Menu)

Khi chạy lệnh trên, một Menu tương tác trực quan sẽ hiện ra cho phép bạn lựa chọn các tác vụ:

### 1. Install Necessary App (Cài đặt Phần mềm & Cấu hình)
Đây là tính năng cốt lõi của dự án, thực hiện một loạt các thao tác tự động:
- **Tự động cấu hình Windows (`Config.ps1` & `disk.ps1`)**: Chạy ngầm các tinh chỉnh hệ thống và cấu hình ổ đĩa song song với quá trình cài đặt phần mềm.
- **Smart Skip (Bỏ qua thông minh)**: Tự động quét Registry hệ thống. Nếu phần mềm đã có sẵn trên máy, script sẽ tự động đánh dấu "Already Installed" và bỏ qua để tiết kiệm băng thông.
- **Tải & Cài đặt Song Song (Parallel Installation)**: 
  - Tải xuống và cài đặt âm thầm (Silent) cùng lúc 8 phần mềm thiết yếu: *Google Chrome, EVKey, K-Lite Codec Pack, Telegram, UltraViewer, WinRAR, Zalo, Zoom*.
  - Nguồn tải siêu tốc từ Direct Link (Cloudflare R2).
- **Winget Fallback**: Nếu cài từ Direct Link thất bại, hệ thống tự động thiết lập và chuyển sang tải từ kho ứng dụng Winget của Microsoft.
- **Giao diện CLI Động (Dynamic Table)**: Bảng trạng thái hiển thị trực quan tiến trình tải và cài đặt của từng phần mềm theo thời gian thực.
- **Thư viện Nền tảng**: Tự động cài đặt nối tiếp (Sequential) các gói Microsoft Visual C++ Redistributable (x64 & x86).

### 2. Information (Trích xuất thông tin hệ thống)
- Khởi chạy kịch bản `Get-info.ps1`.
- Trích xuất toàn bộ thông tin phần cứng (CPU, RAM, Disk, BaseBoard...) và thông tin hệ điều hành.
- Tự động xuất thông tin ra file `info.txt` trên Desktop và mở file lên cho người dùng xem.

### 3. Debloatware (Tối ưu hóa Windows)
- Tích hợp công cụ [Win11Debloat](https://github.com/raphire/win11debloat) cực kỳ nổi tiếng.
- Khởi chạy ở chế độ **Silent Default Profile** (`-RunDefaults`): Tự động gỡ bỏ các ứng dụng rác (Bloatware) mặc định của Windows, tắt Telemetry và tối ưu hóa hệ thống mà không hiện bất kỳ cửa sổ phức tạp nào.

---

## 📂 Cấu trúc dự án

- `Setup.ps1`: Kịch bản điều phối trung tâm chứa Menu UI, hệ thống quản lý tiến trình ngầm (Background Jobs) và Auto-Elevate UAC.
- `config/Config.ps1`: Kịch bản tinh chỉnh, thiết lập cài đặt lõi của hệ điều hành.
- `config/disk.ps1`: Kịch bản cấu hình và chia phân vùng ổ đĩa tự động.
- `config/Get-info.ps1`: Kịch bản phân tích phần cứng và ghi xuất Log.

---
*Lưu ý: Quá trình thiết lập diễn ra nhanh hay chậm phụ thuộc vào tốc độ ổ cứng và mạng Internet của bạn.*
