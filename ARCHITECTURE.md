# Cấu trúc & Kiến trúc Hoạt động của Dự án MiniApps Windows Setup

Tài liệu này giải thích chi tiết luồng hoạt động (Workflow), cách tổ chức mã nguồn và các cơ chế an toàn được tích hợp bên trong dự án MiniApps, giúp nhà phát triển dễ dàng bảo trì và mở rộng sau này.

---

## 1. Thành phần Dự án (Project Structure)

Dự án bao gồm 1 file điều phối chính và 1 thư mục chứa các kịch bản (scripts) cấu hình chuyên sâu:

- **`Setup.ps1`**: Kịch bản "đầu não" (Brain/Wrapper). Có nhiệm vụ hiển thị giao diện UI, điều hướng (Menu), phân luồng các luồng cài đặt song song và xử lý các kịch bản con ngầm.
- **`config/Config.ps1`**: Kịch bản thực thi các cấu hình lõi của hệ thống Windows (Tắt Fast Startup, Cấu hình DNS, Tắt giới hạn mật khẩu...).
- **`config/disk.ps1`**: Kịch bản siêu an toàn chuyên lo việc chia phân vùng ổ cứng (C, D, E) tự động dựa vào việc nhận diện dung lượng SSD vật lý.
- **`config/Get-info.ps1`**: Kịch bản chuyên trích xuất thông tin phần cứng hệ thống (CPU, RAM, Mainboard...) và bung ra trình xem văn bản cho người dùng.

---

## 2. Luồng hoạt động chính (Core Workflow) của `Setup.ps1`

Khi chạy lệnh `irm ... | iex`, kịch bản sẽ đi qua các giai đoạn sau:

### Giai đoạn 1: Auto-Elevate (Tự động leo quyền Admin)
- Script sẽ tự kiểm tra quyền quản trị viên (`WindowsBuiltInRole::Administrator`).
- Do đặc thù lệnh `iex` chạy từ RAM sẽ gây lỗi khi cần bàn phím (Menu), hệ thống sẽ tự động tải file `Setup.ps1` lưu thành một tệp tạm ở máy (`$env:TEMP\winget2_elevated.ps1`), sau đó dùng lệnh `Start-Process` khởi chạy Cửa sổ PowerShell mới với tư cách Quản trị viên trỏ vào tệp đó. Hệ thống lúc này là 100% Admin và tương tác ổn định.

### Giai đoạn 2: Tải và thiết lập môi trường (Bypass Security & Winget)
- Kích hoạt giao thức bảo mật `TLS 1.2` để tải file không bị lỗi HTTP.
- Kích hoạt cơ chế chống lỗi chứng chỉ Winget (Certificate Pinning) qua lệnh: `winget settings --enable BypassCertificatePinningForMicrosoftStore`. Điều này đảm bảo tính năng Fallback của Winget hoạt động thông suốt.

### Giai đoạn 3: Menu Tương tác (Interactive Menu)
Hệ thống sử dụng phím Lên/Xuống hoặc phím số (1, 2, 3) để điều hướng:

#### Menu 1 - Tải và Cài đặt Thông minh (Install Necessary App)
1. **Khởi chạy tiến trình ngầm (Background Jobs)**: Hệ thống tách nhánh, cho `Config.ps1` và `disk.ps1` chạy độc lập dưới dạng Job (`Start-Job`) để tối ưu hóa thời gian.
2. **Quét Smart Skip (Bỏ qua thông minh)**: Đọc Registry để tìm tên phần mềm (MatchName). Nếu đã có, gán trạng thái `"Already Installed"`.
3. **Cài đặt Song song (Parallel Installation)**:
   - Các ứng dụng chính được khai báo URL (Cloudflare R2) và tải về cùng lúc dưới dạng nhiều Job độc lập.
   - **Auto-Retry**: Mỗi luồng tải file (`Invoke-WebRequest`) được bọc bởi vòng lặp thử lại tối đa 3 lần và Timeout 5 phút (300 giây) để chống đứt cáp quang.
   - **Force Kill Timeout**: Các lệnh `Start-Process` cài đặt sẽ bị ép Timeout 3 phút (ngoại trừ Office 2024 là 30 phút). Nếu qua thời gian này, tiến trình kẹt sẽ bị giết (Killed) để vòng lặp đi tiếp.
   - **Giao diện Dynamic Table**: Vòng lặp `while ($jobs.State -contains 'Running')` chịu trách nhiệm thu thập kết quả và cập nhật liên tục ra màn hình console ở vị trí cố định.
   - **Winget Fallback**: Nếu Direct Link thất bại, tiến trình sẽ tự động cài qua lệnh `winget install`.
4. **Cài đặt Tuần tự (Sequential Installation)**:
   - Sau khi phần mềm chính xong, hệ thống tiến hành tải và cài VC Redist. Cũng áp dụng luật Auto-Retry, Timeout (3 phút) và Winget Fallback tương tự như nhánh song song.

#### Menu 2 - Trích xuất phần cứng (Information)
- Trích xuất System Info qua WMI/CIM, xuất ra `$env:USERPROFILE\Desktop\info.txt` và gọi `Notepad` để mở tệp.

#### Menu 3 - Tối ưu hóa (Debloatware)
- Kéo và biên dịch thẳng công cụ [Win11Debloat](https://github.com/raphire/win11debloat) bằng `[scriptblock]::Create`.
- Áp dụng tham số ẩn `-RunDefaults` để dọn rác Windows tự động theo thông số tiêu chuẩn của công cụ.

---

## 3. Khả năng mở rộng (Scalability)

Dự án được viết theo cấu trúc `Array of Hashtables` cực kỳ linh hoạt.
Nếu muốn thêm, sửa hoặc xóa bất kỳ phần mềm nào, chỉ cần truy cập vào mảng `$parallelApps` hoặc `$sequentialApps` trong `Setup.ps1` và thay đổi thông số 1 dòng duy nhất.

Cấu trúc định dạng phần mềm:
```powershell
@{ 
   Name="Tên_Hiển_Thị"; 
   Url="Link_Tải_R2_Cloudflare"; 
   WingetId="Mã_Phần_Mềm_Winget_Để_Fallback"; 
   Args="Tham_Số_Cài_Đặt_Im_Lặng_Ví_Dụ_/S"; 
   MatchName="Tên_Trên_Registry_Để_Smart_Skip" 
}
```

---
*Tài liệu này được tạo vào ngày 11/07/2026. Tất cả các tính năng đã được kiểm thử và đang hoạt động ở trạng thái ổn định (Stable).*
