# Docker Engine trên Linux

Dùng hướng dẫn này cho máy Linux x86-64, máy chủ hoặc VM. Cài Docker Engine và Compose plugin theo bản phân phối. Tài khoản cài đặt cần quyền chạy Docker CLI. [Docker Engine trên Ubuntu](https://docs.docker.com/engine/install/ubuntu/) · [Docker Compose plugin](https://docs.docker.com/compose/install/linux/).

```bash
docker info --format '{{.OSType}}/{{.Architecture}}'
docker compose version
```

## Chọn phương thức cài đặt

- [Cài mới từ mã nguồn](INSTALL.md) nếu muốn bắt đầu với database trống.
- [Khôi phục từ snapshot](RESTORE.md) nếu muốn sử dụng lại dữ liệu và image của một instance đã chạy.

Với VM dùng để phục hồi và thử tích hợp, mức khởi điểm dự kiến là 4 vCPU, 8 GB RAM và 120 GB SSD. Với môi trường quản lý khoảng 128 website, có thể cấp 8 vCPU, 32 GB RAM và 300 GB SSD. Đối chiếu các mức này với kích thước snapshot, volume, thời gian lưu dữ liệu và số liệu đo trên máy đích.

## Truy cập từ máy khác

Console mặc định nghe tại `127.0.0.1:6276` trên máy cài. Từ máy quản trị, mở SSH tunnel trong một terminal riêng.

```bash
ssh -N -L 6276:127.0.0.1:6276 user@vm-host
```

Mở [console qua SSH tunnel](http://localhost:6276). Nếu truy cập qua reverse proxy HTTPS, đặt `BASE_URL` theo origin trên trình duyệt và cấu hình `TRUSTED_PROXIES` theo hạ tầng. Kiểm tra cả đăng nhập và tải file qua origin đó.

## Vận hành

Xem [lệnh kiểm tra log, dừng và mở lại dịch vụ](OPERATIONS.md#quản-lý-dịch-vụ).
