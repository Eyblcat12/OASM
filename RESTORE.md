# Chuyển dữ liệu bằng snapshot

Dùng quy trình này để phục hồi NCS OASM từ bản cài Docker Compose hoặc từ snapshot PoC Windows. Snapshot giữ tài khoản, workspace, project, target, dịch vụ, kết quả và cấu hình đã lưu trong PostgreSQL. RustFS và audit được xuất riêng để chuyển file và bằng chứng.

## 1. Chuẩn bị

- Chọn snapshot được xuất sau các thay đổi cuối cùng ở instance nguồn. Thư mục cần có `SHA256SUMS`, `counts.txt`, `workspace-id.txt`, `postgres.dump`, `rustfs-data.tar.gz`, `audit-archive.tar.gz` và `oasm-images.tar`. Snapshot mới có thêm `image-ids.txt`. Snapshot PoC cũ có `redis-data.tar.gz` và `worker-state.tar.gz`.
- Dùng Docker host hoặc Docker context dành cho môi trường đích. Chọn project Compose chưa có container và volume. Mặc định là `oasm-ti-siem-test`. Có thể đặt `COMPOSE_PROJECT_NAME` trong `.env` trước khi phục hồi, rồi dùng cùng giá trị khi mở console và bảo trì.
- Tạo `.env` từ [mẫu](.env.example) và điền các biến theo [hướng dẫn cấu hình](INSTALL.md#3-cấu-hình-môi-trường). Giữ đúng `ENCRYPTION_KEYS` từ nguồn, gồm cả thứ tự các khóa nếu có nhiều khóa. Kiểm tra origin truy cập và thông tin RustFS cho môi trường đích.
- Chuyển snapshot và khóa cấu hình qua kênh có phân quyền. Khi phục hồi, Compose dùng Redis mới để tránh phát lại hàng đợi cũ.

## 2. Phục hồi

Trong thư mục repo NCS OASM, chạy trong Bash hoặc Git Bash.

```bash
bash deploy-test.sh --check /path/to/oasm-snapshot-YYYYMMDDTHHMMSSZ
bash deploy-test.sh /path/to/oasm-snapshot-YYYYMMDDTHHMMSSZ
```

`--check` xác minh checksum, file bàn giao và cấu hình Compose. Lệnh thứ hai nạp các image, phục hồi PostgreSQL, đối soát số dòng rồi giải nén RustFS và audit. Bộ cài áp dụng nhận diện NCS OASM và kiểm tra API qua console trước khi báo sẵn sàng.

Nếu cần đối soát trước khi mở API, chạy `bash restore-data.sh /path/to/snapshot`. Khi đã kiểm tra các endpoint tích hợp và đường mạng của môi trường đích, mở console bằng `bash compose.sh up -d console`.

Nếu phục hồi gián đoạn, giữ volume và log để kiểm tra lỗi. Khi cần thử lại, dùng một project trống khác và mở console sau khi đã xử lý xung đột cổng `6276`.

## 3. Xác minh dữ liệu

1. Mở console và đăng nhập bằng tài khoản đã có trên instance nguồn.
2. So sánh số target, project, dịch vụ, job và finding với `counts.txt`. Snapshot mới còn đối soát số workflow, quy tắc scope, profile công cụ và cấu hình tích hợp.
3. Mở một finding cũ, một workflow đã chỉnh và một profile công cụ. Tải một file đã biết để xác nhận object storage đã phục hồi.
4. Nếu cần kết nối TI/SIEM, kiểm tra theo [hướng dẫn vận hành](OPERATIONS.md#kiểm-tra-tích-hợp).

## Xuất snapshot từ bản cài Docker Compose

Dùng Bash hoặc Git Bash trên máy đang chạy instance. Tạo trước thư mục backup riêng, bên ngoài repo. Trong cửa sổ bảo trì, dừng các ứng dụng đang ghi dữ liệu, rồi dừng console, API và RustFS. Giữ PostgreSQL hoạt động.

```bash
bash compose.sh stop console core-api rustfs
bash export-data.sh /path/to/private-backup 00000000-0000-0000-0000-000000000000
```

Thay GUID bằng ID workspace bạn muốn đối soát. Nếu cần tra ID, liệt kê các workspace bằng lệnh sau.

```bash
bash compose.sh exec -T postgres psql -X -U postgres -d open_asm \
  -c 'SELECT id, name FROM public.workspaces ORDER BY name;'
```

Script xuất toàn bộ database, đối soát workspace được chọn, rồi ghi archive và checksum. Chỉ bàn giao snapshot sau thông báo **Snapshot ready**. Lưu khóa và cấu hình môi trường riêng. Khi sao lưu xong, dùng `bash compose.sh up -d --wait --wait-timeout 240 console` để mở lại ứng dụng.

## Xuất snapshot nguồn trên Windows

Với bản PoC Windows cũ trong project `oasm-docker`, dùng [script PowerShell](Export-Snapshot.ps1) và PowerShell 7.4 trở lên. Tạo trước thư mục backup riêng. Trong cửa sổ bảo trì, kết thúc các công việc còn chạy, dừng worker, API, Redis và RustFS. Giữ PostgreSQL hoạt động trong lúc xuất.

```powershell
& .\Export-Snapshot.ps1 -PrivateBackupDirectory 'E:\private-backup' `
  -ProjectWorkspaceId '00000000-0000-0000-0000-000000000000' `
  -ExpectedProjectTargets 128
```

Thay GUID và số target bằng giá trị workspace thực tế. Chờ thông báo **Snapshot ready** và kiểm tra thư mục có `SHA256SUMS` trước khi chuyển đi.
