# Cài đặt và triển khai NCS OASM

Chọn cách triển khai theo dữ liệu bạn có. Cả hai quy trình chạy được trên **Ubuntu/Linux với Docker Engine** hoặc **Windows với Docker Desktop**.

| Trường hợp | Quy trình |
| --- | --- |
| Có snapshot với `oasm-images.tar`, `postgres.dump` và `SHA256SUMS` | Dùng [quy trình khôi phục snapshot](RESTORE.md) để nạp image và dữ liệu có sẵn. |
| Muốn bắt đầu với workspace và database trống | Làm lần lượt các bước dưới đây để build API và console từ mã nguồn Open ASM. |

## 1. Kiểm tra môi trường

Trên Ubuntu, chạy lệnh trong Terminal sau khi [cài Docker Engine](DOCKER-ENGINE.md). Trên Windows, mở [Docker Desktop ở chế độ Linux containers](DOCKER-DESKTOP.md), rồi dùng **Git Bash** hoặc terminal của distro **WSL 2** đã bật Docker integration.

```bash
docker version
docker info --format '{{.OSType}}/{{.Architecture}}'
docker compose version
docker buildx version
git --version
```

Kiểm tra `docker version` có phần `Server` và `docker info` hiện `linux/x86_64`. Máy đích cần truy cập GitHub, kho package và các registry được dùng khi build. Console dùng cổng `6276` trên loopback. Kiểm tra cổng còn trống trước lần khởi động đầu tiên.

## 2. Lấy mã nguồn và build

Nếu chưa clone repo triển khai, chạy lệnh sau. Nếu đã có, vào thư mục repo hiện tại.

```bash
cd "$HOME"
git clone https://github.com/Eyblcat12/OASM.git ncs-oasm
cd ncs-oasm
```

Từ thư mục repo NCS OASM, lấy source Open ASM vào thư mục kế bên rồi checkout đúng commit tương thích với bộ Compose. Dùng Docker host riêng nếu máy có bản OASM đang sử dụng cùng tag image nội bộ.

```bash
git clone --no-checkout --filter=blob:none https://github.com/oasm-platform/open-asm.git ../open-asm-src
git -C ../open-asm-src checkout --detach 2e12e49e8ab5420746d9faf43fd48f57a923db58
git -C ../open-asm-src rev-parse HEAD
```

Nếu thư mục `../open-asm-src` đã có từ lần trước, dùng lại checkout đó và kiểm tra HEAD. Khi đã đúng commit, build hai image.

```bash
docker build --platform linux/amd64 \
  --file ../open-asm-src/core-api/Dockerfile \
  --build-arg APP_VERSION=v0.12.2-poc.2e12e49 \
  --tag local/oasm-api:poc-2e12e49 ../open-asm-src

docker build --platform linux/amd64 \
  --file ../open-asm-src/console/Dockerfile \
  --tag local/oasm-console:poc-2e12e49 ../open-asm-src

docker image inspect --format '{{.Os}}/{{.Architecture}}' \
  local/oasm-api:poc-2e12e49 local/oasm-console:poc-2e12e49
```

Hai image phải hiện `linux/amd64`. Nếu build báo lỗi quyền socket, quay lại bước kiểm tra Docker của nền tảng đang dùng. PostgreSQL, Redis, RustFS và GeoIP được tải theo digest khi khởi động. [Tham chiếu Docker Build](https://docs.docker.com/reference/cli/docker/buildx/build/)

## 3. Cấu hình môi trường

```bash
umask 077
cp -n .env.example .env
```

Điền các biến dưới đây vào `.env`. Tạo một giá trị ngẫu nhiên riêng cho mỗi khóa hoặc mật khẩu. Có thể dùng `openssl rand -hex 32` nếu đã cài OpenSSL. Trên Windows, giới hạn quyền đọc file bằng ACL của thư mục.

| Biến | Giá trị khi cài mới |
| --- | --- |
| `BASE_URL` | Giữ `http://localhost:6276` nếu truy cập trực tiếp hoặc qua SSH tunnel. Nếu có reverse proxy, điền origin HTTPS thực tế. |
| `TRUSTED_PROXIES` | Để trống khi truy cập trực tiếp. Chỉ cấu hình các proxy tin cậy nếu triển khai qua proxy. |
| `POSTGRES_PASSWORD`, `REDIS_PASSWORD` | Hai mật khẩu riêng. Dùng chuỗi hex cho Redis vì mật khẩu nằm trong URI kết nối. |
| `BETTER_AUTH_SECRET`, `ENCRYPTION_KEYS` | Hai giá trị ngẫu nhiên độc lập, mỗi giá trị ít nhất 32 ký tự. Lưu `ENCRYPTION_KEYS` cùng hồ sơ khôi phục để đọc dữ liệu đã mã hóa. |
| `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY` | Một cặp thông tin xác thực riêng cho RustFS. |
| `OASM_CLOUD_APIKEY` | Compose yêu cầu giá trị khác rỗng. Với bản cài cục bộ, dùng một giá trị ngẫu nhiên dành riêng cho instance. |
| `COMPOSE_PROJECT_NAME` | Tùy chọn. Mặc định là `oasm-ti-siem-test`. Giữ cùng tên ở các lần mở lại để sử dụng đúng volume. |

## 4. Khởi động và tạo quản trị viên

```bash
bash compose.sh config --quiet
bash compose.sh up -d --wait --wait-timeout 240 console
bash compose.sh exec -T postgres \
  psql -X -v ON_ERROR_STOP=1 -U postgres -d open_asm < branding/apply.sql
curl --fail --silent --show-error http://localhost:6276/api/health
bash compose.sh ps -a
```

Mở [NCS OASM trên máy local](http://localhost:6276), chọn **Create your first admin** và điền thông tin tài khoản. Với VM từ xa, dùng [SSH tunnel](DOCKER-ENGINE.md#truy-cập-từ-máy-khác) trước khi mở địa chỉ trên.

Nếu API chưa sẵn sàng, xem `bash compose.sh logs --tail 100 core-api migration postgres`. Container `migration` hiện `Exited (0)` khi đã hoàn tất. Bộ Compose này dựng console, API và hạ tầng lưu trữ. Worker quét và collector SIEM được cấu hình riêng theo phạm vi triển khai. [Vận hành OASM](OPERATIONS.md) · [Tích hợp SIEM](SIEM.md)
