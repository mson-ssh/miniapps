# Lenovo Driver Update CLI

## Mục đích

Tài liệu này là đặc tả để tạo một CLI PowerShell cập nhật **driver** cho máy Lenovo thương mại bằng `Lenovo.Client.Update` (LCU). Đây chưa phải mã nguồn hay lệnh triển khai.

Giả định đã chốt:

- Thiết bị mục tiêu là Lenovo thương mại: ThinkPad, ThinkCentre hoặc ThinkStation.
- Hệ điều hành là Windows 10 hoặc Windows 11; PowerShell 5.0 trở lên; chạy bằng quyền Administrator.
- Phiên bản đầu chỉ xử lý package có loại `Driver`; không cài BIOS/UEFI, firmware, application hoặc package khác.
- Mặc định là quét và báo cáo. Cài đặt phải có xác nhận rõ ràng của người dùng; không tự khởi động lại.
- Không dùng driver, BIOS hay firmware ép theo model/SKU/thị trường khác. Đặc biệt không dùng package Global cho máy China SKU nếu LCU không tự xác nhận phù hợp.

LCU là module PowerShell do Lenovo CDRT công bố cho quản trị PC Lenovo thương mại. Nó phát hiện, tải và cài update dựa trên machine type, phần cứng, BIOS và cấu hình thực tế của máy, thay vì chỉ dựa trên tên dòng máy.

## Ngoài phạm vi phiên bản đầu

- Hỗ trợ máy Lenovo consumer hoặc model chỉ bán tại Trung Quốc đại lục.
- Cập nhật BIOS/UEFI, firmware, dock firmware hoặc ứng dụng Lenovo.
- Chế độ unattended hoàn toàn, lịch tự chạy, Intune/SCCM hoặc repository offline.
- Tự cài LCU từ Internet, tự thay đổi execution policy, hoặc tự đánh dấu repository là trusted.
- Tự xóa thư mục cache sau khi cài.

Các phần này cần được thiết kế và phê duyệt riêng, không thêm ngầm vào CLI driver-only.

## Công cụ và nguồn được chấp nhận

Backend là `Lenovo.Client.Update`, được cấp phát trước bởi quản trị viên từ nguồn Lenovo đã phê duyệt. CLI không được tự tải hay cập nhật module khi đang chạy.

Trước khi import/chạy LCU, quá trình triển khai phải lưu lại phiên bản đã duyệt và kiểm tra tính toàn vẹn/chữ ký của gói theo quy trình nội bộ. Không coi việc PowerShell Gallery hoặc repository được đánh dấu `Trusted` là bằng chứng về nhà phát hành. Microsoft coi PSGallery là nguồn cộng đồng và không phù hợp làm dependency production trực tiếp; nếu dùng, gói phải được thẩm định rồi đưa vào repository nội bộ đã phê duyệt.

Không được dùng các lựa chọn bỏ qua xác minh:

- `Get-LnvUpdate -SkipSignature`
- `Save-LnvUpdate -SkipSignatureCheck`
- `Install-LnvUpdate -SkipSignatureCheck`

Tài liệu LCU hiện có khác biệt giữa một số trang về tham số xác minh chữ ký. Khi triển khai, phải kiểm tra cú pháp của **đúng phiên bản LCU đã duyệt** trước khi dùng tham số bảo mật; không đoán hoặc sao chép tham số từ tài liệu của phiên bản khác.

## Thiết kế CLI tối thiểu

Tên script đề xuất: `Lenovo-Driver.ps1`.

Giao diện phiên bản đầu chỉ cần `-Action Scan|Install`, với `Scan` là mặc định. Ngoài common parameters của PowerShell, không thêm cờ chức năng nào khác trong phiên bản đầu.

Hai thao tác là:

| Thao tác | Hành vi | Có thay đổi máy? |
| --- | --- | --- |
| `Scan` (mặc định) | Kiểm tra update cần thiết, lọc driver, hiện báo cáo và ghi log quét | Không, trừ file log/scratch do LCU dùng để đánh giá package |
| `Install` | Quét mới, lọc driver, hiện lại danh sách, chờ xác nhận, tải vào cache rồi cài | Có |

`Install` là thao tác thay đổi hệ thống và phải dùng `[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]`. Nó phải có `-WhatIf` và `-Confirm` do PowerShell tự cung cấp; không tự khai báo hai tham số này. Lệnh gọi `Save-LnvUpdate` và `Install-LnvUpdate` chỉ được chạy sau khi `ShouldProcess` chấp thuận. Chỉ thêm attribute là chưa đủ để bảo vệ lời gọi module bên ngoài.

Không thêm `-Force` để bỏ qua xác nhận trong phiên bản đầu. Nếu về sau cần automation không tương tác, đó là một feature riêng có policy, allow-list và thử nghiệm riêng.

## Preflight bắt buộc

Trước `Scan` và `Install`, CLI phải kiểm tra các điều kiện dưới đây. Nếu bất kỳ điều kiện nào không đạt, dừng trước khi tải hoặc chạy installer và trả về lý do rõ ràng.

| Kiểm tra | Điều kiện đạt | Hành động khi không đạt |
| --- | --- | --- |
| Nhà sản xuất và dòng máy | Lenovo commercial được nhận diện | Dừng: không hỗ trợ tự động |
| Nền tảng | Windows 10/11, PowerShell 5.0+ | Dừng: nền tảng không được hỗ trợ |
| Quyền hạn | Phiên PowerShell elevated | Dừng: yêu cầu chạy Administrator |
| Trạng thái restart | Không có restart đang chờ | Dừng: yêu cầu hoàn tất restart trước |
| LCU | Đã có đúng phiên bản được duyệt, import được | Dừng: LCU chưa được provision/không hợp lệ |
| Nguồn package | Có mạng tới catalog Lenovo và đủ dung lượng scratch/cache | Dừng: không có nguồn update khả dụng |
| Máy China SKU | LCU tự quét và trả package phù hợp, có chữ ký | Chỉ báo không được xác minh; không fallback sang package Global |

CLI phải lấy machine type/model/serial thực tế từ firmware hoặc Windows, nhưng chỉ dùng thông tin này cho kiểm tra và log. Không được ép `-Model` sang model Global hoặc tự ghép package thủ công.

## Luồng xử lý driver-only

```text
Preflight
  -> Get-LnvUpdate (chỉ update cần thiết/applicable)
  -> lọc Driver + unattended-installable
  -> hiển thị báo cáo
  -> [Scan: kết thúc]
  -> [Install: xác nhận/ShouldProcess]
  -> Save-LnvUpdate vào thư mục cache kiểm soát được
  -> Install-LnvUpdate
  -> đánh giá kết quả từng package
  -> ghi audit/WMI, báo ActionNeeded
```

Quy tắc bắt buộc trong luồng này:

1. Dùng `Get-LnvUpdate` không kèm `-All` cho luồng cài đặt. Mặc định cmdlet chỉ trả package cần thiết và phù hợp; `-All` gồm cả package đã cài hoặc không phù hợp.
2. Lọc `Driver` **trước cả** `Save-LnvUpdate` và `Install-LnvUpdate`. Không để BIOS, firmware hay application đi qua chỉ vì chúng là dependency hay cùng kết quả quét.
3. Chỉ cho package có installer unattended vào phiên bản đầu. Package không đáp ứng phải hiện ở mục “Skipped”, không cố chạy installer tương tác vì có thể treo CLI/deployment.
4. Tài liệu Lenovo hiện dùng cả `Category` và một ví dụ dùng `Type` để mô tả loại package. Trước khi cố định bộ lọc, kiểm tra object thực tế của đúng phiên bản LCU và viết test xác nhận trường/giá trị `Driver`. Không hard-code mù quáng theo một ví dụ tài liệu.
5. `Get-LnvUpdate` có thể dùng mạng và thư mục scratch để đánh giá tính phù hợp và chữ ký; quét không phải thao tác tức thời. CLI cần báo tiến trình và lỗi mạng rõ ràng.
6. `Install` phải quét lại ngay trong cùng lượt chạy trước khi cài. Không cài danh sách cũ từ một lượt quét trước đó.

## Báo cáo và kết quả

Ở cuối `Scan`, CLI hiển thị tối thiểu các trường sau cho mỗi driver phù hợp:

- `PackageID`, `Title`, `Version`, `ReleaseDate`
- `Category`, `Severity`, `FileSize`
- Trạng thái applicable và khả năng unattended

Ở cuối `Install`, CLI không chỉ báo “đã chạy xong”. Nó phải thu thập từng `PackageInstallResult` từ LCU và hiển thị/lưu:

- `PackageID`, `Title`, `Status`, `ExitCode`
- `ActionNeeded`, `Message`, `Duration`

Quy ước kết quả cấp CLI:

| Kết quả | Ý nghĩa |
| --- | --- |
| Thành công | Mọi package đã chọn có `Status` thành công hoặc không có driver cần cập nhật |
| Thành công nhưng cần hành động | Không có lỗi cài đặt, nhưng một hay nhiều package có `ActionNeeded` |
| Không thực hiện | `-WhatIf`, người dùng từ chối xác nhận, hoặc không có driver phù hợp |
| Thất bại | Preflight, scan, tải hoặc ít nhất một package cài thất bại |

Lưu toàn bộ exit code từng package trong report thay vì thay thế chúng bằng một thông báo chung. Process exit code của CLI sẽ được định nghĩa cùng test automation sau; không tự coi một exit code installer cụ thể là thành công nếu LCU trả `Status` thất bại.

## Reboot và dependency

CLI tuyệt đối không gọi `Restart-Computer` trong phiên bản đầu. Sau cài đặt, đọc `ActionNeeded` và báo rõ nếu người dùng phải restart hoặc shutdown. Không cam kết “driver-only thì chắc chắn không reboot”: một số package vẫn có thể yêu cầu hành động sau cài.

Lenovo lưu ý một driver có thể làm driver khác mới trở nên applicable. Sau khi người dùng hoàn tất restart hoặc hệ thống ổn định, CLI chỉ **đề xuất** chạy lại `Scan`; không tự động chạy pass cài đặt thứ hai.

## Log và audit

- Ghi log quét bằng cơ chế `-LogPath` của LCU hoặc đường dẫn log do CLI quản lý.
- Sau `Install` đã được xác nhận, dùng `-ExportToWMI` để ghi lịch sử vào `root\Lenovo\Lenovo_Updates`.
- Report của CLI phải phân biệt: package tìm thấy, package bị bỏ qua, package được chọn, package cài thành công/thất bại và restart cần thiết.
- Không ghi secret, credential proxy hoặc thông tin nhạy cảm không cần thiết vào console/log.

## Tiêu chí nghiệm thu trước khi phát hành CLI

1. Máy không phải Lenovo thương mại bị từ chối và không có installer nào chạy.
2. `Scan` chỉ trả driver cần thiết; không tải/cài package vào cache cuối cùng.
3. `Install -WhatIf` không gọi `Save-LnvUpdate` hay `Install-LnvUpdate`.
4. `Install` hiển thị danh sách driver và chỉ gọi LCU sau xác nhận PowerShell.
5. Test fixture có BIOS, firmware và application chứng minh chúng không đi qua bước tải/cài.
6. Không có đường mã nào dùng tham số bỏ qua chữ ký, thay đổi execution policy hay tự tin cậy repository.
7. Một package cài lỗi tạo kết quả thất bại có `PackageID`, `ExitCode` và `Message`.
8. Một package trả `ActionNeeded` chỉ tạo thông báo restart/shutdown; CLI không tự reboot.
9. Lịch sử WMI/log sau lượt cài được đọc lại để đối chiếu report.
10. Thử nghiệm đầu tiên thực hiện trên một máy Lenovo thương mại không phải production và có backup/khả năng khôi phục phù hợp.

## Tài liệu chính thức đã dùng

Lenovo:

- [Lenovo.Client.Update: yêu cầu và phạm vi](https://docs.lenovocdrt.com/guides/lcu/)
- [Get-LnvUpdate](https://docs.lenovocdrt.com/guides/lcu/functions/get-lnvupdate/)
- [Save-LnvUpdate](https://docs.lenovocdrt.com/guides/lcu/functions/save-lnvupdate/)
- [Install-LnvUpdate](https://docs.lenovocdrt.com/guides/lcu/functions/install-lnvupdate/)
- [Get-LnvUpdateFromWMI](https://docs.lenovocdrt.com/guides/lcu/functions/get-lnvupdatefromwmi/)
- [LCU quick start](https://docs.lenovocdrt.com/guides/lcu/getting-started/quick-start/)
- [So sánh LSU và LCU, bao gồm chữ ký/lịch sử](https://docs.lenovocdrt.com/guides/lcu/comparison/)

Microsoft:

- [CmdletBinding và SupportsShouldProcess](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute?view=powershell-7.6)
- [Tạo cmdlet thay đổi hệ thống](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/creating-a-cmdlet-that-modifies-the-system?view=powershell-7.6)
- [Get-AuthenticodeSignature](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/get-authenticodesignature?view=powershell-7.5)
- [Repository PowerShell được hỗ trợ](https://learn.microsoft.com/en-us/powershell/gallery/powershellget/supported-repositories?view=powershellget-3.x)
