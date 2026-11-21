# Docker Engine trên VM Linux

Trên Linux x86-64 của System, cài Docker Engine và Docker Compose v2 theo bản phân phối VM sử dụng, sau đó dùng tài khoản vận hành được cấp quyền quản lý Docker. [Docker Engine trên Ubuntu](https://docs.docker.com/engine/install/ubuntu/), [Compose plugin](https://docs.docker.com/compose/install/linux/).

```bash
docker info --format '{{.OSType}}/{{.Architecture}}'
docker compose version
```

VM cần truy cập được nơi cung cấp các image phụ trợ theo digest trong `compose.yaml` và có đủ ổ đĩa cho archive, image cùng volume sau khi giải nén. Nếu dùng registry mirror hoặc tải image offline, System cần bảo đảm các tham chiếu digest tương ứng tồn tại trên VM.

## Lần triển khai đầu tiên

```bash
git clone https://github.com/Eyblcat12/OASM.git oasm-vm-ti-siem
cd oasm-vm-ti-siem
umask 077
cp .env.example .env
chmod 600 .env
# Điền .env và kiểm tra đường mạng thử nghiệm theo README trước khi chạy.
bash deploy-test.sh /path/to/oasm-snapshot-YYYYMMDDTHHMMSSZ
```

Lệnh kiểm checksum, nạp image, phục hồi DB và đối chiếu dữ liệu trước khi mở giao diện. Cổng quản trị bind loopback. Từ máy quản trị, dùng `ssh -L 6276:127.0.0.1:6276 user@vm-host` rồi mở `http://localhost:6276`. Khi System cấp reverse proxy HTTPS, cập nhật `BASE_URL`, kiểm tra header chuyển tiếp và xác nhận đăng nhập cùng tải file.

## Trạng thái và bảo trì

```bash
docker compose --env-file .env ps -a
docker compose --env-file .env logs --tail 100 core-api console postgres
docker compose --env-file .env stop
docker compose --env-file .env up -d console
```

`stop` giữ các volume. Sau lần phục hồi đầu tiên, dùng `up -d console` để mở lại dịch vụ từ dữ liệu đã phục hồi. Xem [README](README.md) để kiểm thử TI/SIEM và xác nhận dữ liệu.
