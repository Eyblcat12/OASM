# Docker Desktop trên Windows

Dùng Windows x86-64 với Docker Desktop ở chế độ Linux containers. Cài Git Bash để chạy các lệnh Bash trong tài liệu. [Docker Desktop trên Windows](https://docs.docker.com/desktop/setup/install/windows-install/).

## Kiểm tra Docker

Mở Docker Desktop và chờ engine sẵn sàng. Trong Git Bash, chạy các lệnh sau.

```bash
docker info --format '{{.OSType}}/{{.Architecture}}'
docker compose version
```

Nếu CLI báo lỗi named pipe, kiểm tra Docker Desktop đang chạy và context hiện tại trỏ đúng Linux engine. Nếu cổng `6276` đã được dùng, cài vào một môi trường khác hoặc giải phóng cổng trước khi khởi động.

## Chọn phương thức cài đặt

- [Cài mới từ mã nguồn](INSTALL.md) để tạo instance trống.
- [Khôi phục từ snapshot](RESTORE.md) để mang theo dữ liệu cũ. Trong Git Bash, dùng đường dẫn dạng `/e/private-backup/oasm-snapshot-YYYYMMDDTHHMMSSZ` cho thư mục trên ổ E.

Sau khi cài, mở [NCS OASM trên máy local](http://localhost:6276).

## Xem log

Trong Docker Desktop, vào **Containers → oasm-ti-siem-test**, mở container cần kiểm tra rồi chọn **Logs**. Hoặc dùng [các lệnh vận hành trên CLI](OPERATIONS.md#quản-lý-dịch-vụ).
