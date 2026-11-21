# Chuyển dữ liệu bằng snapshot

Dùng quy trình này để phục hồi NCS OASM từ bản PoC Windows được hỗ trợ bởi [script xuất snapshot](Export-Snapshot.ps1). Snapshot giữ tài khoản, workspace, project, target, dịch vụ, kết quả và cấu hình đã lưu trong PostgreSQL. RustFS và audit được xuất riêng để chuyển file và bằng chứng.

## 1. Chuẩn bị

- Chọn snapshot được xuất sau các thay đổi cuối cùng ở instance nguồn. Thư mục cần có `SHA256SUMS`, `counts.txt`, `workspace-id.txt`, `postgres.dump`, `rustfs-data.tar.gz`, `audit-archive.tar.gz`, `redis-data.tar.gz`, `worker-state.tar.gz` và `oasm-images.tar`.
- Dùng Docker host hoặc Docker context dành cho môi trường đích. Script phục hồi tạo các volume mới và kiểm tra image ID có trong snapshot. Sau khi đã phục hồi dữ liệu, dùng quy trình [mở lại stack](OPERATIONS.md#quản-lý-dịch-vụ).
- Tạo `.env` từ [mẫu](.env.example) và điền các biến theo [hướng dẫn cấu hình](INSTALL.md#3-cấu-hình-môi-trường). Giữ đúng `ENCRYPTION_KEYS` từ nguồn, gồm cả thứ tự các khóa nếu có nhiều khóa. Kiểm tra origin truy cập và thông tin RustFS cho môi trường đích.
- Chuyển snapshot và khóa cấu hình qua kênh có phân quyền. Snapshot lưu riêng Redis và worker-state. Khi phục hồi, Compose dùng Redis mới để các job cũ không phát lại.

## 2. Phục hồi

Trong thư mục repo NCS OASM, chạy trong Bash hoặc Git Bash.

```bash
bash deploy-test.sh --check /path/to/oasm-snapshot-YYYYMMDDTHHMMSSZ
bash deploy-test.sh /path/to/oasm-snapshot-YYYYMMDDTHHMMSSZ
```

`--check` xác minh checksum, file bàn giao và cấu hình Compose. Lệnh thứ hai nạp các image, phục hồi PostgreSQL, đối soát số dòng rồi giải nén RustFS và audit. Bộ cài áp dụng nhận diện NCS OASM và kiểm tra API qua console trước khi báo sẵn sàng.

Nếu cần đối soát trước khi mở API, chạy `bash restore-data.sh /path/to/snapshot`. Khi đã kiểm tra các endpoint tích hợp và đường mạng của môi trường đích, mở console bằng `docker compose --env-file .env up -d console`.

## 3. Xác minh dữ liệu

1. Mở console và đăng nhập bằng tài khoản đã có trên instance nguồn.
2. So sánh số target, project, dịch vụ, job và finding với `counts.txt`. Snapshot mới còn đối soát số workflow, quy tắc scope, profile công cụ và cấu hình tích hợp.
3. Mở một finding cũ, một workflow đã chỉnh và một profile công cụ. Tải một file đã biết để xác nhận object storage đã phục hồi.
4. Nếu cần kết nối TI/SIEM, kiểm tra theo [hướng dẫn vận hành](OPERATIONS.md#kiểm-tra-tích-hợp).

## Xuất snapshot nguồn trên Windows

Dùng PowerShell 7.4 trở lên. Tạo trước thư mục backup riêng. Trong cửa sổ bảo trì, kết thúc các công việc còn chạy, dừng worker, API, Redis và RustFS. Giữ PostgreSQL hoạt động trong lúc xuất.

```powershell
& .\Export-Snapshot.ps1 -PrivateBackupDirectory 'E:\private-backup' `
  -ProjectWorkspaceId '00000000-0000-0000-0000-000000000000' `
  -ExpectedProjectTargets 128
```

Thay GUID và số target bằng giá trị workspace thực tế. Chờ thông báo **Snapshot ready** và kiểm tra thư mục có `SHA256SUMS` trước khi chuyển đi.
