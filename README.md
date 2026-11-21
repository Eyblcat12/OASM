# NCS OASM

![Logo NCS OASM](branding/ncs-oasm-wordmark.png)

Bộ triển khai NCS OASM để phục hồi môi trường quản lý trên VM từ dữ liệu PoC, xem kết quả đã lưu và kết nối **Threat Intelligence (TI)** và **SIEM**. Bộ Compose khởi động giao diện, API và các dịch vụ dữ liệu.

| Môi trường | Hướng dẫn |
| --- | --- |
| VM Linux x86-64 trên ESXi | [Docker Engine và Compose v2](DOCKER-ENGINE.md) |
| Máy Windows x86-64 | [Docker Desktop với Linux containers](DOCKER-DESKTOP.md) |

## Chuẩn bị bàn giao

| Đầu vào | Yêu cầu |
| --- | --- |
| **Snapshot nguồn** | PostgreSQL dump, archive RustFS và audit, image PoC, số liệu đối soát và `SHA256SUMS`. Chọn snapshot được xuất sau những thay đổi cuối cùng trên máy local. Snapshot lưu riêng Redis và worker-state cùng kỳ. Bộ Compose này dùng Redis mới và chưa khởi động worker. |
| **Cấu hình môi trường** | Tạo `.env` từ [mẫu](.env.example). Lấy khóa và mật khẩu từ kho bí mật của System. Cần giữ `ENCRYPTION_KEYS` nguồn để mở dữ liệu đã mã hóa. Đối chiếu thông tin xác thực RustFS theo môi trường. |
| **Đầu nhận thử nghiệm** | Đội TI/SIEM cung cấp endpoint hoặc collector, cơ chế xác thực và nơi tra cứu kết quả. System xác nhận đường mạng của VM trước khi mở API. Snapshot có thể chứa endpoint tích hợp từ môi trường nguồn. |

Repo công khai chứa mã triển khai, tài liệu và dữ liệu mẫu. Chuyển snapshot và image PoC qua kênh nội bộ có mã hóa và phân quyền. Giá trị `REDIS_PASSWORD` cần tương thích với URI trong Compose.

## Triển khai và phục hồi

```bash
git clone https://github.com/Eyblcat12/OASM.git oasm-vm-ti-siem
cd oasm-vm-ti-siem
cp .env.example .env
```

Điền `.env`. Dùng tùy chọn `--check` để xác minh các file bàn giao và cấu hình Compose trước khi phục hồi. Bước này chỉ đọc file.

```bash
bash deploy-test.sh --check /path/to/oasm-snapshot-YYYYMMDDTHHMMSSZ
bash deploy-test.sh /path/to/oasm-snapshot-YYYYMMDDTHHMMSSZ
```

Script kiểm tra checksum, nạp image, khôi phục database và đối soát số dòng trước khi mở giao diện. Snapshot chứa toàn bộ PostgreSQL, gồm các workflow, quy tắc scope, profile công cụ và cấu hình tích hợp đã lưu. Snapshot xuất bằng script hiện tại có thêm số đếm của các bảng cấu hình trong `counts.txt`. File và bằng chứng cũ được phục hồi từ RustFS và audit archive. Bộ cài kiểm tra API qua console trước khi báo sẵn sàng.

Để kiểm tra riêng dữ liệu trước khi mở API, dùng `bash restore-data.sh /path/to/snapshot`, rồi chạy `docker compose --env-file .env up -d console` khi System xác nhận đường mạng. Sau lần phục hồi đầu tiên, dùng `up -d console` để mở lại stack.

## Xuất snapshot nguồn trên Windows

Trong cửa sổ bảo trì, kết thúc các công việc còn chạy và dừng worker, API, Redis và RustFS. Giữ PostgreSQL hoạt động để xuất dữ liệu. Chạy lệnh bằng PowerShell 7.4 trở lên, thay ID ví dụ bằng workspace ID thực tế:

```powershell
& .\Export-Snapshot.ps1 -PrivateBackupDirectory 'E:\private-backup' -ProjectWorkspaceId '00000000-0000-0000-0000-000000000000'
```

Script mặc định kiểm tra workspace có **128 Target**. Chỉ bàn giao thư mục snapshot sau khi có thông báo **Snapshot ready** và file checksum.

## Kiểm tra sau triển khai

```bash
docker compose --env-file .env ps -a
curl --fail --silent --show-error http://localhost:6276/api/health
```

Giao diện quản trị nghe ở loopback. Truy cập tại `http://localhost:6276` trên máy chạy Docker hoặc qua SSH tunnel theo [hướng dẫn Linux](DOCKER-ENGINE.md). Đăng nhập, đối chiếu 128 Target cùng số project, job và finding trong `counts.txt`. Mở một finding cũ, tải một file đã biết và so sánh một workflow cùng profile đã chỉnh trên máy local.

| Luồng | Cách thử | Điều kiện đạt |
| --- | --- | --- |
| **OASM → TI** | Gửi [finding mẫu](fixtures/finding.json) tới endpoint test theo cơ chế đã thống nhất. Nếu tương thích, dùng thêm chức năng Test của OASM để kiểm tra kết nối từ ứng dụng. | Tìm thấy sự kiện theo ID và đối chiếu được asset, mức độ, URL cùng loại sự kiện. |
| **OASM → SIEM** | Dùng [log mẫu](fixtures/operational-log.json) để kiểm tra mapping. Kiểm tra thêm một log thực từ dịch vụ OASM khi collector đã cấu hình. | Tìm thấy log theo correlation ID hoặc timestamp và service. |
| **NCS OASM** | Mở lại giao diện sau khi triển khai. | Màn hình tải hiển thị logo ngang. Màn hình đăng nhập và thanh bên hiển thị biểu tượng vòng quét cùng tên NCS OASM. |

Trước khi gửi mẫu, cập nhật thời gian UTC và dùng ID mới nếu đầu nhận chống trùng. Ghi lại phản hồi và kết quả tra cứu ở đầu nhận. HTTP 2xx xác nhận tiếp nhận ở tầng giao thức. Kết quả tra cứu xác nhận việc xử lý và mapping.

## Nguồn và giấy phép

- Cấu hình Nginx và manifest dựa trên Open ASM tại commit `2e12e49e8ab5420746d9faf43fd48f57a923db58`. Bản triển khai đổi cổng upstream thành 6277, bổ sung nhận diện giao diện và giữ timeout Nuclei 3600 giây của PoC. [Giấy phép Open ASM](licenses/open-asm-AGPL-3.0.txt).
- Tham chiếu OASM Connectors đi kèm [giấy phép Apache 2.0](licenses/oasm-connectors-Apache-2.0.txt) và [thông báo bản quyền](licenses/oasm-connectors-NOTICE.txt).
- [Docker image save](https://docs.docker.com/reference/cli/docker/image/save/) và [PostgreSQL pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html).
