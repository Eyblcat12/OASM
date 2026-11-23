# NCS OASM

![Logo NCS OASM](branding/ncs-oasm-wordmark.png)

NCS OASM đóng gói [Open ASM](https://github.com/oasm-platform/open-asm) để tự triển khai bảng điều khiển quản lý tài sản, theo dõi lỗ hổng và lưu lịch sử công việc. Docker Compose khởi động giao diện, API, PostgreSQL, Redis, RustFS và dịch vụ GeoIP.

Bản Compose chính phục vụ quản lý tài sản và xem kết quả đã lưu. Có overlay riêng cho worker đăng ký vào OASM và đối chiếu CVE từ file kiểm kê. Kết nối TI/SIEM sử dụng đầu nhận hoặc collector do người vận hành cấu hình.

## Bắt đầu

Yêu cầu Docker chạy Linux containers trên máy x86-64, Docker Compose plugin, Git, Bash và curl. Luồng build từ mã nguồn dùng Docker Buildx. Trên Windows, dùng Git Bash cùng Docker Desktop.

```bash
git clone https://github.com/Eyblcat12/OASM.git ncs-oasm
cd ncs-oasm
```

| Bạn muốn | Tài liệu |
| --- | --- |
| Chọn quy trình cài đặt và triển khai trên Linux hoặc Windows | [Hướng dẫn triển khai NCS OASM](INSTALL.md) |
| Chuyển tài khoản, target, kết quả và cấu hình đã có | [Khôi phục snapshot từng bước](RESTORE.md) |
| Cài Docker trên Ubuntu 24.04 hoặc VM Linux | [Docker Engine và Compose](DOCKER-ENGINE.md) |
| Cài Docker trên Windows | [Docker Desktop và WSL 2](DOCKER-DESKTOP.md) |
| Chạy worker kiểm kê và thử đối chiếu CVE từ file | [Worker kiểm kê thụ động](WORKER-PASSIVE.md) |
| Dùng giao diện, kiểm tra dịch vụ và thử TI/SIEM | [Vận hành](OPERATIONS.md) |
| Thu log Docker, audit và kết quả quét vào Elastic, Wazuh hoặc QRadar | [Gửi dữ liệu về SIEM](SIEM.md) |

## Phiên bản và giấy phép

API và console dựa trên [Open ASM tại commit `2e12e49`](https://github.com/oasm-platform/open-asm/tree/2e12e49e8ab5420746d9faf43fd48f57a923db58). Repo này cung cấp Compose, cấu hình nhận diện, công cụ chuyển dữ liệu và mẫu sự kiện. Hướng dẫn cài mới lấy mã nguồn từ upstream. Hướng dẫn khôi phục sử dụng image đã xuất cùng snapshot.

- [Giấy phép của repo này](LICENSE).
- [Giấy phép AGPL-3.0 của Open ASM](licenses/open-asm-AGPL-3.0.txt).
- [Giấy phép Apache 2.0 của OASM Connectors](licenses/oasm-connectors-Apache-2.0.txt) và [thông báo bản quyền](licenses/oasm-connectors-NOTICE.txt).
