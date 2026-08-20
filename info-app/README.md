# info.exe (prototype)

Đứng riêng, không đụng gì tới `Setup.ps1` hay `config/`. Đây là bước 1: dựng và test giao diện
`info.exe` trước khi tích hợp vào luồng chính (sẽ làm khi được yêu cầu).

## Test nhanh giao diện (không cần build .exe)

Trên Windows, mở PowerShell trong thư mục này rồi chạy:

```powershell
.\Info.ps1
```

Cửa sổ hiện ra ngay, sửa `Info.ps1` xong chạy lại là thấy thay đổi — vòng lặp chỉnh sửa nhanh
nhất, không cần build lại `.exe` mỗi lần.

## Build thành info.exe

```powershell
.\Build-InfoExe.ps1
```

Lần đầu sẽ tự cài module `ps2exe` (từ PowerShell Gallery, cần mạng). Xong sẽ ra file `info.exe`
ngay trong thư mục này — chạy thử bằng cách double-click hoặc `.\info.exe`.

## Ghi chú

- Dữ liệu hiển thị lấy y hệt `Get-HardwareInfo` trong `Setup.ps1` (Hostname, Model, Serial, CPU,
  RAM, ổ cứng, card đồ họa, độ phân giải, tần số quét, thời gian) — chỉ khác cách trình bày: cửa
  sổ GUI thay vì file `.txt` mở bằng Notepad.
- `Info.ps1` không đọc/gọi gì từ `Setup.ps1` — nếu sau này sửa `Get-HardwareInfo` thì cần cập
  nhật tay ở đây nữa nếu muốn giữ đồng bộ.
- Em chưa test được trên Windows thật (máy hiện tại là macOS) — anh chạy `.\Info.ps1` trước để
  xem giao diện, phản hồi lại rồi mình chỉnh tiếp trước khi build `.exe`.
