# NCS OASM

![Logo NCS OASM](branding/ncs-oasm-wordmark.png)

NCS OASM đóng gói [Open ASM](https://github.com/oasm-platform/open-asm) để tự triển khai bảng điều khiển quản lý tài sản, theo dõi lỗ hổng và lưu lịch sử công việc. Docker Compose khởi động giao diện, API, PostgreSQL, Redis, RustFS và dịch vụ GeoIP.

Luồng triển khai đầy đủ trong [DEPLOYMENT.md](DEPLOYMENT.md) dùng Compose upstream với **worker gốc** để thực thi connector quét, có hai nhánh cài mới hoặc khôi phục snapshot, cùng cấu hình collector kết quả và log cho SIEM. File `compose.yaml` ở gốc repo là bộ PoC trước đây; các overlay worker kiểm kê/kiểm tra cũ không thay thế worker gốc trong luồng deployment này.

## Bắt đầu

Yêu cầu Docker chạy Linux containers trên máy x86-64, Docker Compose plugin và Git. Trên Linux dùng Docker Engine; trên Windows có thể cài mới và vận hành bằng PowerShell + Docker Desktop. Các script restore/collector cần Bash, Python 3 và môi trường Linux/Ubuntu WSL có Docker integration. Quy trình triển khai chính dùng image phát hành đã chọn và không yêu cầu tự build source.

```bash
git clone https://github.com/Eyblcat12/OASM.git ncs-oasm
cd ncs-oasm
```

| Bạn muốn | Tài liệu |
| --- | --- |
| Chốt kiến trúc, cấu hình và tiêu chí bàn giao production cho 128 website | [Phương án production](PRODUCTION.md) |
| Đổi timeout Nuclei bằng một lệnh, giữ source gốc | [Cấu hình runtime](RUNTIME.md) |
| Dựng Open ASM gốc, chuyển dữ liệu, đổi logo và kết nối SIEM | [Deployment từ đầu tới cuối trên Linux và Windows](DEPLOYMENT.md) |
| Chọn quy trình cài đặt và triển khai trên Linux hoặc Windows | [Hướng dẫn triển khai NCS OASM](INSTALL.md) |
| Chuyển tài khoản, target, kết quả và cấu hình đã có | [Khôi phục snapshot từng bước](RESTORE.md) |
| Nhập dữ liệu snapshot vào bộ Compose Open ASM gốc | [Chuyển dữ liệu vào Open ASM upstream](MIGRATE-UPSTREAM.md) |
| Cài Docker trên Ubuntu 24.04 hoặc VM Linux | [Docker Engine và Compose](DOCKER-ENGINE.md) |
| Cài Docker trên Windows | [Docker Desktop và WSL 2](DOCKER-DESKTOP.md) |
| Chạy worker kiểm kê và thử đối chiếu CVE từ file | [Worker kiểm kê thụ động](WORKER-PASSIVE.md) |
| Xác nhận image worker gốc khởi động và đăng ký Online | [Kiểm tra worker gốc](WORKER-CHECK.md) |
| Dùng giao diện, kiểm tra dịch vụ và thử TI/SIEM | [Vận hành](OPERATIONS.md) |
| Thu log Docker, audit và kết quả quét vào Elastic, Wazuh hoặc QRadar | [Gửi dữ liệu về SIEM](SIEM.md) |
| Bật collector cho Elastic qua một lần cấu hình | [SIEM quickstart](SIEM-QUICKSTART.md) |

## Phiên bản và giấy phép

Snapshot PoC ban đầu được tạo từ [Open ASM tại commit `2e12e49`](https://github.com/oasm-platform/open-asm/tree/2e12e49e8ab5420746d9faf43fd48f57a923db58). Luồng deployment upstream hiện dùng release `v0.13.0` để cài mới hoặc nhập dữ liệu snapshot, theo phiên bản và giới hạn nghiệm thu trong [DEPLOYMENT.md](DEPLOYMENT.md). Repo này cung cấp công cụ chuyển dữ liệu, tài nguyên nhận diện và collector SIEM; dữ liệu thật cùng bí mật được chuyển qua kênh riêng.

- [Giấy phép của repo này](LICENSE).
- [Giấy phép AGPL-3.0 của Open ASM](licenses/open-asm-AGPL-3.0.txt).
- [Giấy phép Apache 2.0 của OASM Connectors](licenses/oasm-connectors-Apache-2.0.txt) và [thông báo bản quyền](licenses/oasm-connectors-NOTICE.txt).
