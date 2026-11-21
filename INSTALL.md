# Cài mới NCS OASM

Hướng dẫn này tạo một instance trống từ mã nguồn Open ASM. Nếu bạn cần mang theo tài khoản, target, kết quả và cấu hình cũ, bắt đầu với [hướng dẫn khôi phục snapshot](RESTORE.md).

## 1. Kiểm tra môi trường

Dùng [Docker Engine trên Linux](DOCKER-ENGINE.md) hoặc [Docker Desktop trên Windows](DOCKER-DESKTOP.md). Chạy lệnh trong Bash, hoặc Git Bash trên Windows.

```bash
docker info --format '{{.OSType}}/{{.Architecture}}'
docker compose version
git --version
```

Docker cần chạy Linux containers trên x86-64. Máy cài cần truy cập GitHub và các registry được dùng để tải image, base image và dependency khi build. Console dùng cổng local `6276`. Đảm bảo cổng còn trống trước lần khởi động đầu tiên.

## 2. Lấy mã nguồn và build

Sau khi [clone repo NCS OASM](README.md#bắt-đầu), chạy các lệnh dưới đây từ thư mục repo để lấy source Open ASM vào thư mục kế bên. Dùng Docker host riêng nếu máy có bản OASM đang sử dụng cùng tag image nội bộ.

```bash
git clone --no-checkout --filter=blob:none https://github.com/oasm-platform/open-asm.git ../open-asm-src
git -C ../open-asm-src checkout --detach 2e12e49e8ab5420746d9faf43fd48f57a923db58

docker build --platform linux/amd64 \
  --file ../open-asm-src/core-api/Dockerfile \
  --build-arg APP_VERSION=v0.12.2-poc.2e12e49 \
  --tag local/oasm-api:poc-2e12e49 ../open-asm-src

docker build --platform linux/amd64 \
  --file ../open-asm-src/console/Dockerfile \
  --tag local/oasm-console:poc-2e12e49 ../open-asm-src
```

Hai tag `local/oasm-...` được dùng bởi [Compose](compose.yaml). PostgreSQL, Redis, RustFS và GeoIP được tải theo digest khi khởi động. [Tham chiếu Docker Build](https://docs.docker.com/reference/cli/docker/buildx/build/).

## 3. Cấu hình môi trường

```bash
umask 077
cp .env.example .env
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
```

Mở [NCS OASM trên máy local](http://localhost:6276), chọn **Create your first admin** và điền thông tin tài khoản. Với VM từ xa, dùng [SSH tunnel](DOCKER-ENGINE.md#truy-cập-từ-máy-khác) trước khi mở địa chỉ trên.

Sau khi đăng nhập, xem [hướng dẫn vận hành](OPERATIONS.md) để tìm các màn hình quản lý và cách xem log. [Tham chiếu Docker Compose up](https://docs.docker.com/reference/cli/docker/compose/up/).
