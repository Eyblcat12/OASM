# Triển khai trên Docker Desktop

Dùng cho môi trường thử nghiệm Windows x86-64. Cần Docker Desktop chạy Linux containers, Docker Compose v2 và Git Bash để chạy script phục hồi. [Cài Docker Desktop trên Windows](https://docs.docker.com/desktop/setup/install/windows-install/).

## Kiểm tra Docker

Mở Docker Desktop, chờ engine sẵn sàng và chạy:

```bash
docker info --format '{{.OSType}}/{{.Architecture}}'
docker compose version
```

Kiểm tra engine báo Linux trên x86-64 và Compose v2. Nếu CLI báo lỗi named pipe, kiểm tra trạng thái Docker Desktop và Docker context. Nếu cổng 6276 đang được bản PoC khác sử dụng, chuyển sang máy thử riêng hoặc giải phóng cổng trong cửa sổ bảo trì.

## Phục hồi và mở console

Trong Git Bash:

```bash
git clone https://github.com/Eyblcat12/OASM.git oasm-vm-ti-siem
cd oasm-vm-ti-siem
cp .env.example .env
```

Điền `.env` theo [yêu cầu bàn giao](README.md#chuẩn-bị-bàn-giao) và bảo vệ file bằng quyền truy cập Windows. Khi đã nhận snapshot và xác nhận đường mạng thử nghiệm, chạy lệnh dưới đây. Git Bash biểu diễn ổ E bằng `/e`.

```bash
bash deploy-test.sh /e/private-backup/oasm-snapshot-YYYYMMDDTHHMMSSZ
```

Mở `http://localhost:6276` và xác nhận nhận diện **NCS OASM**. Đăng nhập, đối chiếu dữ liệu và thực hiện các phép thử TI/SIEM theo [README](README.md#kiểm-tra-sau-triển-khai).

## Xem log và mở lại stack

Trong Docker Desktop, vào **Containers → oasm-ti-siem-test → container → Logs**. Khi stack đã có dữ liệu, dùng `docker compose --env-file .env up -d console` để mở lại. Nếu cần xuất snapshot từ máy PoC gốc, dùng [hướng dẫn xuất trên Windows](README.md#xuất-snapshot-nguồn-trên-windows).
