# Triển khai trên Docker Engine

Dùng cho VM Linux x86-64 do System quản lý. Cài Docker Engine và Compose v2 theo bản phân phối của VM. Tài khoản triển khai cần truy cập Docker, registry của các image phụ trợ và thư mục chứa snapshot. [Docker Engine trên Ubuntu](https://docs.docker.com/engine/install/ubuntu/), [Docker Compose plugin](https://docs.docker.com/compose/install/linux/).

## Chuẩn bị VM

Mức đề xuất cấp cho dự án 128 website là 8 vCPU, 32 GB RAM và 300 GB SSD. Nếu chỉ phục hồi dữ liệu và kiểm tra kết nối TI/SIEM, có thể bắt đầu với 4 vCPU, 8 GB RAM và 120 GB SSD sau khi đối chiếu dung lượng snapshot và volume. Đây là cấu hình dự kiến, cần đo lại khi nghiệm thu.

```bash
docker info --format '{{.OSType}}/{{.Architecture}}'
docker compose version
git clone https://github.com/Eyblcat12/OASM.git oasm-vm-ti-siem
cd oasm-vm-ti-siem
umask 077
cp .env.example .env
chmod 600 .env
```

Điền `.env` theo [yêu cầu bàn giao](README.md#chuẩn-bị-bàn-giao). Dành đủ dung lượng cho archive, image và volume sau khi khôi phục. Với registry mirror hoặc image offline, kiểm tra các digest trong [Compose](compose.yaml) đã có trên VM.

## Lần triển khai đầu tiên

Sau khi System xác nhận đường mạng thử nghiệm và thư mục snapshot:

```bash
bash deploy-test.sh --check /path/to/oasm-snapshot-YYYYMMDDTHHMMSSZ
bash deploy-test.sh /path/to/oasm-snapshot-YYYYMMDDTHHMMSSZ
```

Trên máy quản trị, mở SSH tunnel:

```bash
ssh -L 6276:127.0.0.1:6276 user@vm-host
```

Mở `http://localhost:6276`. Nếu System cấp reverse proxy HTTPS, cấu hình `BASE_URL` theo origin HTTPS và kiểm tra header chuyển tiếp, đăng nhập và tải file. Xem [các bước nghiệm thu](README.md#kiểm-tra-sau-triển-khai).

## Cập nhật bản VM đã phục hồi

Khi muốn áp dụng logo **NCS OASM** cho stack đã phục hồi từ commit cũ, chạy trong repo trên VM khi database đang hoạt động:

```bash
git pull --ff-only
docker compose --env-file .env exec -T postgres psql -X -v ON_ERROR_STOP=1 -U postgres -d open_asm < branding/apply.sql
docker compose --env-file .env up -d --no-deps --force-recreate console
```

Lệnh SQL đặt tên thương hiệu và sử dụng icon đóng gói của console. Nếu trình duyệt còn favicon cũ, tải lại trang hoặc mở cửa sổ riêng tư. Lần triển khai đầu tiên qua `deploy-test.sh` đã áp dụng cấu hình này.

## Vận hành

```bash
docker compose --env-file .env ps -a
docker compose --env-file .env logs --tail 100 core-api console postgres
docker compose --env-file .env stop
docker compose --env-file .env up -d console
```

`stop` giữ các volume. Nếu phục hồi dừng giữa chừng, lưu thông báo lỗi và xác định bước chưa hoàn tất trước khi thực hiện lại trên môi trường trống.
