# Chuyển bản OASM hiện tại lên VM để thử TI/SIEM

Gói dành cho VM Linux x86-64 trên ESXi, dùng Docker Engine và Compose v2. PostgreSQL lưu Target, project, người dùng, cấu hình, lịch sử job và finding. RustFS lưu file và artifact. Audit archive được chuyển cùng snapshot. Snapshot cũng giữ bản sao Redis và worker-state để đối chiếu khi bàn giao. Môi trường thử tích hợp dùng Redis mới để tránh phát lại hàng đợi cũ.

## Clone trên VM

System có thể clone repo dưới đây. Nếu repo yêu cầu xác thực, dùng quyền đọc do chủ repo cấp cho VM. Với SSH, có thể dùng SSH deploy key chỉ đọc.

```bash
git clone https://github.com/Eyblcat12/OASM.git oasm-vm-ti-siem
cd oasm-vm-ti-siem
```

Repo chứa cấu hình triển khai, script và mẫu dữ liệu thử. Chuyển snapshot chứa dữ liệu và file image của bản PoC qua kênh nội bộ. Tạo `.env` trên VM bằng giá trị lấy từ kho bí mật System.

- [Docker Engine trên VM Linux](DOCKER-ENGINE.md)
- [Docker Desktop trên Windows](DOCKER-DESKTOP.md)

## 1. Xuất snapshot từ máy Windows

1. Chuẩn bị thư mục backup riêng có quyền truy cập giới hạn và đủ chỗ cho dữ liệu cùng image. Chuyển snapshot qua kênh nội bộ có mã hóa và phân quyền do System quản lý.
2. Trong cửa sổ bảo trì nguồn, kết thúc các công việc đang chạy và dừng worker, API, Redis và RustFS. Giữ PostgreSQL hoạt động để xuất dữ liệu. Thao tác dừng thực hiện theo quy trình vận hành OASM hiện có.
3. Chạy PowerShell 7.4 trở lên. Thay đường dẫn và UUID ví dụ bằng thư mục backup riêng và ID của workspace cần chuyển.

```powershell
& .\Export-Snapshot.ps1 -PrivateBackupDirectory 'E:\private-backup' -ProjectWorkspaceId '00000000-0000-0000-0000-000000000000'
```

Script đối chiếu 128 Target của workspace dự án, tạo PostgreSQL dump, đóng gói các volume cùng image đã triển khai, rồi ghi checksum. Snapshot sẵn sàng khi script báo **Snapshot ready**. Các bản backup trước khi đủ 128 Target có thể dùng đối chiếu lịch sử.

Dùng kho bí mật của System để chuyển **ENCRYPTION_KEYS** đang có, **BETTER_AUTH_SECRET** nếu cần giữ tương thích phiên, và cấu hình bí mật của RustFS. Tạo thông tin kết nối PostgreSQL, Redis và khóa dành riêng cho bản test theo chuẩn nội bộ. Dùng mật khẩu Redis dạng URL-safe vì Compose đưa giá trị vào URI. File `.env` mẫu chỉ chứa tên biến. Snapshot dữ liệu và worker-state vẫn chứa dữ liệu nội bộ cần bảo vệ.

## 2. Khôi phục trên VM thử tích hợp

Copy gói cấu hình và thư mục snapshot bằng kênh đã chốt. Mở thư mục gói trên VM, tạo `.env` quyền hạn chế và điền các giá trị từ kho bí mật. Giữ `BASE_URL=http://localhost:6276` khi truy cập bằng SSH tunnel trên cổng 6276. Khi dùng reverse proxy, đặt BASE_URL theo origin HTTPS đã cấp và xác nhận cấu hình proxy tin cậy của bản triển khai.

```bash
umask 077
cp .env.example .env
chmod 600 .env
```

Sau khi điền `.env` và xác nhận đường mạng thử nghiệm, dùng `bash deploy-test.sh /path/to/snapshot` để phục hồi và mở giao diện trong một lệnh. Nếu cần kiểm tra sau khi phục hồi dữ liệu, dùng quy trình hai bước dưới đây. Restore dừng nếu các volume chính đã tồn tại. Script so khớp checksum, nạp image, restore DB và kiểm tra số hàng trước khi khôi phục object storage và audit archive. Các image phụ trợ được kéo theo digest.

```bash
bash restore-data.sh /path/to/oasm-snapshot-YYYYMMDDTHHMMSSZ
```

Trước khi mở API, System giới hạn đường ra của VM/container tới các dịch vụ nội bộ cần thiết và endpoint **test** đã xác nhận. DB sao chép có thể chứa tích hợp cũ, nên kiểm tra lại cấu hình tích hợp trên VM. Bộ Compose thử nghiệm chỉ gồm dịch vụ quản trị và lưu trữ.

```bash
docker compose --env-file .env up -d console
docker compose --env-file .env ps -a
curl --fail --silent --show-error http://localhost:6276/api/health
```

Từ máy quản trị, có thể mở SSH tunnel bằng `ssh -L 6276:127.0.0.1:6276 user@vm-host` rồi truy cập `http://localhost:6276`. Đăng nhập, đối soát 128 Target, project và lịch sử. Mở ít nhất một finding cũ và một file/artifact đã biết. Nếu restore dừng giữa chừng, giữ log bước lỗi để System quyết định phục hồi trên project trống tiếp theo.

## 3. Kiểm thử đầu nhận

| Hạng mục | Cách kiểm tra | Tiêu chí đạt |
|---|---|---|
| TI hoặc đầu nhận webhook thử | Đội TI cung cấp URL thử và xác thực qua kênh nội bộ. Dùng `fixtures/finding.json` để kiểm tra schema JSON, hoặc chức năng Test của OASM nếu đầu nhận tương thích. | Đầu nhận trả 2xx và tìm thấy ID mẫu, loại sự kiện, asset, severity và affected URL. |
| SIEM nhận log | Đội SIEM cung cấp collector hoặc cơ chế ingest và index/dataset thử. Gửi mẫu `fixtures/operational-log.json` theo cơ chế đó, rồi cấu hình collector đọc log dịch vụ OASM nếu nằm trong phạm vi triển khai. | SIEM truy vấn được correlation ID, timestamp, service và nội dung. Collector nhận được một dòng log từ VM. |
| Dữ liệu gốc | So khớp `counts.txt`, mở hồ sơ cũ và kiểm tra một file trong giao diện. | 128 Target của workspace dự án và số project/job/finding khớp snapshot. |

Sự kiện mẫu dùng tên miền giả lập và timestamp cố định. Khi chạy thử, đổi timestamp sang UTC hiện tại và dùng ID mới nếu bộ nhận có chống trùng. Ghi lại mã phản hồi và kết quả truy vấn đầu nhận. HTTP 2xx xác nhận tiếp nhận ở tầng giao thức. Kết quả tìm được trong TI/SIEM mới xác nhận việc xử lý và mapping.

Tài liệu tham chiếu [Docker image save](https://docs.docker.com/reference/cli/docker/image/save/) và [PostgreSQL pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html).

## Nguồn và giấy phép

- `nginx.conf` lấy từ `console/nginx.conf` của Open ASM tại commit `2e12e49e8ab5420746d9faf43fd48f57a923db58`. Cổng upstream được chỉnh thành 6277 theo bản triển khai hiện tại. Xem [giấy phép Open ASM](licenses/open-asm-AGPL-3.0.txt).
- Manifest runtime dựa trên manifest của Open ASM tại cùng commit, với thời gian chờ Nuclei được đặt thành 3600 giây theo cấu hình PoC. Xem thêm [giấy phép](licenses/oasm-connectors-Apache-2.0.txt) và [thông báo bản quyền](licenses/oasm-connectors-NOTICE.txt) của OASM Connectors.
