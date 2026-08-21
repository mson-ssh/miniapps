# info.exe

`Info.ps1` là bản gốc (canonical) của cửa sổ "System Information" — `Setup.ps1` có 2 bản dùng nó:

- `Invoke-InfoTesting` (menu 6): bản sao chép tay vào `Setup.ps1` để test trực tiếp trong menu, không phải build gì.
- `Publish-InfoExe`: tải đúng file `Info.ps1` này từ GitHub (raw), rồi **tự build ra `info.exe` ngay trên máy khách** bằng module `ps2exe`, đặt lên Desktop — không còn phụ thuộc R2 nữa. Chỉ build 1 lần/máy (nếu `Desktop\info.exe` đã có thì bỏ qua).

Vì vậy **sửa `Info.ps1` ở đây là sửa đúng nội dung sẽ hiện trên máy khách** — nhưng nhớ đồng bộ tay
sang `Invoke-InfoTesting` trong `Setup.ps1` nữa (2 bản không tự động khớp nhau).

## Test nhanh giao diện (không cần build .exe)

Trên Windows, mở PowerShell trong thư mục này rồi chạy:

```powershell
.\Info.ps1
```

Cửa sổ hiện ra ngay, sửa `Info.ps1` xong chạy lại là thấy thay đổi — vòng lặp chỉnh sửa nhanh
nhất, không cần build `.exe`.

## Build tay 1 bản info.exe để xem thử (không bắt buộc)

```powershell
.\Build-InfoExe.ps1
```

Lần đầu sẽ tự cài module `ps2exe` (từ PowerShell Gallery, cần mạng). Xong sẽ ra file `info.exe`
ngay trong thư mục này, kèm icon "i" — chạy thử bằng cách double-click hoặc `.\info.exe`.

Icon lấy thẳng từ Windows (icon **Information** có sẵn của hệ điều hành). Vị trí của nó được hỏi
qua `SHGetStockIconInfo` chứ không hardcode chỉ số trong `imageres.dll` — chỉ số đó đổi giữa các
bản Windows. Icon được rút ra ở **nhiều kích thước** (256/128/64/48/32/16) rồi ghép thành một
file `.ico` đa lớp, nên sắc nét ở mọi nơi; file `.ico` chỉ có một kích thước sẽ bị Windows co
giãn lúc hiển thị và trông nhoè.

Script này **không cần chạy để tính năng hoạt động thật** — `Setup.ps1` tự build trên máy khách
rồi, đây chỉ để anh xem trước file `.exe` trông ra sao trên máy dev của mình.

## Ghi chú

- Dữ liệu hiển thị: Hostname, Model, Serial, CPU, RAM (chi tiết từng khe/onboard qua parse SMBIOS
  thô), Graphics Card (tách iGPU/GPU), độ phân giải, tần số quét, thời gian — CPU/RAM/Graphics Card
  được tô nổi bật.
- `Info.ps1` không đọc/gọi gì từ `Setup.ps1` — độc lập hoàn toàn.
- Em chưa test được trên Windows thật (máy hiện tại là macOS) — mọi thứ mới viết theo lý thuyết,
  cần anh chạy thử trên máy thật để xác nhận.
