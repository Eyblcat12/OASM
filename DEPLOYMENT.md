# Triển khai Open ASM và chuyển dữ liệu NCS OASM

Quy trình này dùng **Compose của Open ASM gốc** và bộ script NCS OASM để chuyển dữ liệu, đổi nhận diện và kết nối SIEM. Chọn **Phần 1** cho Ubuntu hoặc **Phần 2** cho Windows. Cả hai dùng cùng quy trình nghiệm thu dữ liệu và cùng cấu hình đầu nhận.

| Hạng mục | Phiên bản hoặc phạm vi |
| --- | --- |
| Docker | Linux containers trên x86-64, Compose từ **2.24.4** để dùng overlay giới hạn cổng console trên loopback. |
| Bộ Compose upstream | Layout thử nghiệm tại [oasm-docker `56dc2c6`](https://github.com/oasm-platform/oasm-docker/tree/56dc2c657743200363b65cf2168ae4f91d0a953c). |
| Snapshot PoC ngày 21/11 | Dữ liệu được tạo từ API và console dựa trên Open ASM [`2e12e49`](https://github.com/oasm-platform/open-asm/tree/2e12e49e8ab5420746d9faf43fd48f57a923db58). Importer đã đối chiếu 128 target, 163 dịch vụ, 14 findings và 14.218 bản ghi URL lịch sử trong PostgreSQL thử nghiệm. |
| Đầu nhận | Elastic, Wazuh hoặc QRadar theo môi trường của System. Phần dưới đây dùng Elastic làm ví dụ kiểm tra alert. |

Tài liệu này hoàn tất luồng dựng console, chuyển dữ liệu và chuyển tiếp sự kiện. Nghiệm thu worker quét và cảnh báo sinh từ một lượt quét mới là mốc riêng. Tài liệu OASM dùng repo `oasm-docker` để triển khai production và yêu cầu sao lưu khóa mã hóa. [Tài liệu Deployment chính thức](https://docs.oasm.io/deployment)

Chọn một luồng sau khi chuẩn bị Docker, repo và `.env`.

| Trường hợp | Linux | Windows qua WSL 2 |
| --- | --- | --- |
| Có snapshot cũ. Giữ khóa mã hóa nguồn, nhập dữ liệu vào project trống rồi đăng nhập bằng tài khoản cũ. | [Khôi phục snapshot](#linux-a-khôi-phục-snapshot-cũ) | [Khôi phục snapshot](#windows-a-khôi-phục-snapshot-cũ) |
| Cài mới. Tạo khóa riêng, khởi tạo database trống rồi tạo admin đầu tiên. | [Cài mới](#linux-b-cài-mới-từ-đầu) | [Cài mới](#windows-b-cài-mới-từ-đầu) |

## Phần 1. Triển khai trên Linux

### 1. Cài Docker trên Ubuntu 24.04

Trên VM trống, thêm kho Docker chính thức. Nếu VM đã chạy Docker và Compose đạt yêu cầu, chuyển sang bước 2. Nếu có gói như `docker.io`, `containerd` hoặc `podman-docker` đang phục vụ ứng dụng, xem phần xử lý xung đột trước khi đổi gói. [Hướng dẫn Docker Engine chi tiết](DOCKER-ENGINE.md)

```bash
sudo apt update
sudo apt install ca-certificates curl git openssl python3
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL -o /etc/apt/keyrings/docker.asc https://download.docker.com/linux/ubuntu/gpg
sudo chmod 0644 /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && printf '%s' "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker.service containerd.service
sudo docker run --rm hello-world
```

Dùng tài khoản vận hành có quyền Docker. Nếu System phê duyệt cấp quyền qua nhóm `docker`, chạy `sudo usermod -aG docker "$USER"` rồi đăng nhập lại. Nhóm này có quyền tương đương root đối với Docker host. [Quyền sử dụng Docker Engine](https://docs.docker.com/engine/install/linux-postinstall/)

```bash
docker version
docker info --format '{{.OSType}}/{{.Architecture}}'
docker compose version
docker buildx version
df -h /
```

Kết quả cần có `Server`, `linux/x86_64` và Compose từ `2.24.4`. VM phải còn dung lượng cho cả snapshot, image và volume sau khi restore.

### 2. Lấy hai repo

`oasm-upstream` chứa Compose chính thức. `ncs-oasm` cung cấp script nhập dữ liệu và collector. Nếu đã clone repo, giữ nguyên bản đang chạy và chuẩn bị thư mục đích mới khi cần tách môi trường. Chạy các lệnh Bash tiếp theo trong cùng terminal để giữ các biến đường dẫn.

```bash
export NCS="$HOME/ncs-oasm"
export UPSTREAM="$HOME/oasm-upstream"
export PROJECT=oasm-upstream-restore

[[ -d "$NCS/.git" ]] || git clone https://github.com/Eyblcat12/OASM.git "$NCS"
[[ -d "$UPSTREAM/.git" ]] || git clone https://github.com/oasm-platform/oasm-docker.git "$UPSTREAM"
git -C "$UPSTREAM" status --short
git -C "$UPSTREAM" checkout --detach 56dc2c657743200363b65cf2168ae4f91d0a953c
```

Checkout trên bản sao sạch. Compose upstream có các container và mạng nội bộ đặt tên cố định. Nếu máy hiện tại đang dùng bộ Compose upstream khác, chọn VM hoặc Docker daemon riêng để nghiệm thu. Khi dùng Docker Desktop, hai context trỏ vào cùng engine vẫn chia sẻ container và volume.

Nếu `~/ncs-oasm` đã tồn tại từ lần cài trước, cập nhật repo trước khi chạy script. Khối lệnh clone chỉ tải repo khi thư mục chưa tồn tại.

```bash
git -C "$NCS" pull --ff-only origin main
```

### 3. Dùng image phát hành và điền `.env`

Dùng image phát hành của Open ASM với Compose upstream. Đặt `IMAGE_TAG=v0.13.0` để lặp lại phép thử đã chạy với snapshot PoC. Tiến trình migration của release này đã hoàn tất và đối chiếu đúng 128 assets, 163 dịch vụ, 14 findings và 14.218 bản ghi URL. Sau khi kiểm tra console trên VM, giữ tag đã nghiệm thu khi bàn giao production. [Tài liệu triển khai upstream](https://docs.oasm.io/deployment) · [Release v0.13.0](https://github.com/oasm-platform/open-asm/releases/tag/v0.13.0)

```bash
cd "$UPSTREAM"
umask 077
[[ -e .env ]] || cp .env.example .env
chmod 0600 .env
```

Điền `.env` từ mẫu upstream. Khi chuyển từ PoC, lấy khóa mã hóa gốc và các thông tin xác thực cần giữ từ file nguồn qua kênh riêng. Cấu hình lại địa chỉ và biến theo máy đích. Mỗi lần chạy `openssl rand -hex 32` tạo một giá trị riêng cho trường cần khóa hoặc mật khẩu mới.

| Biến | Cách điền |
| --- | --- |
| `IMAGE_TAG` | `v0.13.0` để lặp lại phép thử với snapshot PoC hoặc tag chính thức đã được nhóm nghiệm thu. |
| `BASE_URL` | Khi thử local dùng `http://localhost:6276`. Khi dùng reverse proxy, nhập origin HTTPS mà người dùng mở. |
| `PORT` | Giữ `6277` cho API nội bộ của bộ Compose đã pin. Nginx upstream trỏ tới `core-api:6277`. |
| `POSTGRES_HOST`, `POSTGRES_USERNAME`, `POSTGRES_DB` | Dùng giá trị mẫu `postgres`, `postgres`, `open_asm` nếu dùng DB trong stack. Điền `POSTGRES_PASSWORD` riêng. |
| `REDIS_PASSWORD`, `REDIS_URL` | Tạo mật khẩu hex. Trong URL `redis://:<mật-khẩu>@redis:6379/0`, dùng cùng mật khẩu. |
| `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY`, `RUSTFS_ENDPOINT` | Điền thông tin xác thực object storage và giữ endpoint nội bộ `http://rustfs:9000` khi dùng RustFS trong stack. |
| `BETTER_AUTH_SECRET` | Khóa riêng của instance. |
| `ENCRYPTION_KEYS` | Cài mới dùng khóa ngẫu nhiên. Khôi phục dùng đúng khóa nguồn và giữ thứ tự nếu có nhiều khóa. |
| `OASM_CLOUD_APIKEY` | Điền giá trị theo cấu hình của môi trường; với PoC local, thay giá trị mẫu bằng khóa riêng của instance. |
| `TRUSTED_PROXIES` | Để trống khi mở trực tiếp. Nếu có reverse proxy, điền theo proxy tin cậy thực tế. |

Giữ file `.env` và khóa ở nơi lưu bí mật của môi trường. [Cấu hình và khóa mã hóa theo tài liệu OASM](https://docs.oasm.io/deployment#encryption-keys)

### 4. Chuyển dữ liệu hoặc mở instance trống

#### Linux A. Khôi phục snapshot cũ

Nếu chuyển dữ liệu, chép snapshot lên VM bên ngoài repo. Nhập dữ liệu **trước lần khởi động console đầu tiên trên project đích**, khi PostgreSQL và object storage của đích còn trống. Sửa đường dẫn `SNAP` rồi chạy:

```bash
SNAP="$HOME/Desktop/oasm-snapshot-YYYYMMDDTHHMMSSZ"
bash "$NCS/migrate-upstream-data.sh" --check "$SNAP" "$UPSTREAM" "$PROJECT" &&
  bash "$NCS/migrate-upstream-data.sh" "$SNAP" "$UPSTREAM" "$PROJECT"
```

Chờ dòng `Upstream data imported and counts matched`. Script chỉ chạy PostgreSQL để nhập dữ liệu và kiểm tra `counts.txt`. Các archive RustFS và audit được đưa vào volume của project mới. Nếu snapshot có job hoặc lịch còn hoạt động, script dừng để người vận hành rà soát. [Chi tiết và xử lý lỗi nhập dữ liệu](MIGRATE-UPSTREAM.md)

#### Linux B. Cài mới từ đầu

Dùng project và volume mới cùng `.env` đã điền các khóa dành riêng cho instance. Ví dụ đặt `export PROJECT=oasm-upstream-new`, rồi chuyển thẳng tới bước mở console. Bộ Compose khởi tạo PostgreSQL và schema tự động. Khi màn hình đầu tiên hiện lên, chọn **Create your first admin** và tạo tài khoản quản trị cho instance mới.

#### Mở console trên Linux

Sau bước A hoặc B, dùng cùng `.env`, tên project và overlay trong những lần vận hành tiếp theo. Nếu cổng `6276` đã bận, xem container nào đang giữ cổng:

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep ':6276->'
```

Nếu kết quả xác nhận **console NCS cũ** chiếm cổng và bạn đang chuyển giao diện sang Open ASM gốc, dừng riêng container console cũ. Ví dụ dưới đây dùng đúng tên của bộ cài NCS mặc định.

```bash
docker stop oasm-ti-siem-test-console-1
ss -ltn 'sport = :6276'
```

Khi cổng trống, chạy:

```bash
upstream_stack=(docker compose --project-directory "$UPSTREAM" --env-file "$UPSTREAM/.env"
  -p "$PROJECT" -f "$UPSTREAM/docker-compose.yml" -f "$NCS/compose.upstream-data.yaml")
"${upstream_stack[@]}" config --quiet &&
  "${upstream_stack[@]}" pull console core-api migration &&
  "${upstream_stack[@]}" up -d --wait --wait-timeout 240 console &&
  "${upstream_stack[@]}" ps -a
curl --fail --silent --show-error http://127.0.0.1:6276/api/health
```

Overlay giữ console tại `127.0.0.1:6276`, gắn volume audit archive và yêu cầu khởi động RustFS trước `core-api`. Health check API có 30 giây chờ khởi động. Nếu dùng trình duyệt ngay trên VM, mở [Open ASM local](http://localhost:6276). Từ máy quản trị, dùng SSH tunnel rồi mở cùng địa chỉ trên trình duyệt của máy quản trị.

```bash
ssh -N -L 6276:127.0.0.1:6276 user@vm-host
```

### 5. Nghiệm thu dữ liệu và đổi logo

1. **Cài mới:** tạo tài khoản admin từ màn hình đầu tiên. **Sau restore:** đăng nhập bằng tài khoản đã lưu trong snapshot.
2. **Cài mới:** xác nhận workspace mới mở được. **Sau restore:** chọn workspace nguồn và so **Targets**, **Assets**, **Services** và **Vulnerabilities** với `counts.txt`. Mở một bản ghi URL lịch sử, một finding và một workflow cũ. Tải thử một file đã lưu để kiểm tra RustFS.
3. Vào **Admin → Brand** (`/admin/brand`), điền tên hiển thị và tải icon. Có thể dùng [icon NCS](branding/ncs-oasm-icon.png). Đăng nhập lại và kiểm tra logo ở giao diện. [Thương hiệu và logo trong OASM](https://docs.oasm.io/brand-name-and-logo)

### 6. Thu log, findings và kiểm tra alert

Hai đầu vào SIEM đọc độc lập. **Vector** đọc stdout/stderr của Docker. **Collector kết quả** đọc audit, findings và discovery đã lưu qua API OASM. Làm theo các bước tạo cấu hình, cấp quyền và kiểm thử trong [hướng dẫn SIEM](SIEM.md). Với deployment upstream trong file này, chú ý các giá trị sau.

| Cấu hình | Giá trị cần dùng |
| --- | --- |
| Docker project trong `vector.yaml` | Dùng giá trị của `PROJECT`, mặc định ví dụ là `oasm-upstream-restore`. |
| `OASM_DOCKER_NETWORK` | `oasm_net` với Compose upstream `56dc2c6`. Kiểm tra `docker network ls` nếu System đã đổi mạng. |
| `OASM_BASE_URL` | `http://core-api:6277` từ trong mạng Docker, theo biến `PORT` của API. |
| `OASM_RESULTS_IMAGE` | Đúng image API đang chạy, ví dụ `oasm/oasm-api:v0.13.0`. |
| Endpoint Elastic | URL Elasticsearch do System cấp. Kibana dùng để tạo data view và rule. |

Dùng hai cấu hình Vector và Elasticsearch ở [mục 2 và 4 của hướng dẫn SIEM](SIEM.md) để thu log Docker. Để mở collector kết quả trên Open ASM upstream, dùng các biến sau. Vị trí `out` cần trùng thư mục file đầu vào đã gắn vào Vector.

```bash
export OASM_SIEM_DIR="$HOME/oasm-siem-collector"
export OASM_SOURCE_HOST="$(hostname)"
export OASM_COLLECTOR_UID="$(id -u)" OASM_COLLECTOR_GID="$(id -g)"
export OASM_DOCKER_NETWORK=oasm_net
export OASM_BASE_URL=http://core-api:6277
OASM_RESULTS_IMAGE=$("${upstream_stack[@]}" config --images core-api)
export OASM_RESULTS_IMAGE
install -d -m 0700 "$OASM_SIEM_DIR/private" "$OASM_SIEM_DIR/state"
install -d -m 0750 "$OASM_SIEM_DIR/out"
```

Biến `OASM_RESULTS_IMAGE` lấy từ Compose của máy đang chạy, nên collector dùng cùng tag với API. Chuẩn bị `private/oasm-session.json` với workspace và phiên đọc hợp lệ theo [phần collector kết quả](SIEM.md#chạy-collector-kết-quả). Giữ file ở ngoài repo với quyền `0600`. Sau đó chạy các lệnh bên dưới.

```bash
results="$NCS/siem/compose.results.yaml"
docker compose -f "$results" config --quiet
docker compose -f "$results" up -d
docker compose -f "$results" logs --tail 30 results
```

Trong Elastic, dùng data view `logs-oasm.finding-poc` với `@timestamp` nếu giữ tên stream của hướng dẫn SIEM. Trong **Rules**, tạo rule **Elasticsearch query** kiểu KQL. Đặt điều kiện số bản ghi lớn hơn 0 trong 5 phút, chạy mỗi phút. Nếu tên stream hoặc namespace khác, chọn đúng data view của production.

```text
event.dataset: "oasm.finding" and vulnerability.severity: ("high" or "critical")
```

Dùng **Test query** để kiểm tra điều kiện trước khi bật. Đối chiếu một finding có sẵn để xác nhận ingestion. Dùng rule thử hoặc dữ liệu giả lập trong môi trường test để xác nhận alert nếu nguồn hiện chỉ có finding mức Info. Kiểm tra alert trong SIEM trước khi nối đầu nhận thông báo của SOC. [Rule Elasticsearch query](https://www.elastic.co/docs/explore-analyze/alerting/alerts/rule-type-es-query)

### 7. Bàn giao và vận hành

| Kiểm tra trước khi bàn giao | Kết quả cần ghi nhận |
| --- | --- |
| Phiên bản | Commit Compose, tag hoặc digest API/console, và phiên bản PostgreSQL đã nghiệm thu. |
| Dữ liệu | Checksum đạt, đối soát đúng workspace, đọc được findings, URL và file cũ. |
| Giao diện | Đăng nhập được theo địa chỉ production, logo hiển thị, đường HTTPS và proxy đã được System kiểm tra. |
| SIEM | Một log mới từ host đích, một finding đã đối chiếu và một alert thử có bằng chứng trên SIEM. |
| Worker quét nếu nằm trong phạm vi bàn giao | Ghi kết quả nghiệm thu riêng của một lượt kiểm thử đã duyệt, từ job đến finding và cảnh báo. |
| Bản sao lưu | Lưu PostgreSQL, object storage, audit và khóa mã hóa theo kênh riêng. Thử khôi phục vào một môi trường trống trước lần chuyển đổi lớn. |

Khi thay đổi phiên bản, giữ nguyên VM cũ đến khi máy mới đã được nghiệm thu. Nếu lệnh mở console báo `core-api` `unhealthy`, chạy `"${upstream_stack[@]}" ps -a`. Nếu API đã chuyển sang `healthy`, chạy lại lệnh mở console trên cùng project. Nếu RustFS chưa chạy hoặc API vẫn lỗi, cập nhật repo NCS để lấy overlay mới rồi kiểm tra log `core-api`, `rustfs`, `postgres` và `migration`. Nếu importer báo project hoặc volume đã tồn tại, kiểm tra Docker context và tên project. Dùng project trống để phục hồi thử.

## Phần 2. Triển khai trên Windows

### 1. Chuẩn bị Docker Desktop và WSL 2

Trên Windows x86-64, kiểm tra ảo hóa CPU trong **Task Manager → Performance → CPU**. Nếu chưa cài WSL, mở PowerShell quyền administrator và chạy:

```powershell
wsl --install -d Ubuntu
```

Khởi động lại nếu được yêu cầu và mở Ubuntu lần đầu để tạo tài khoản. Nếu đã có WSL, cập nhật rồi kiểm tra:

```powershell
wsl --update
wsl --version
wsl --list --verbose
```

Tải Docker Desktop từ Docker, chọn backend **WSL 2**, rồi mở Docker Desktop và chọn **Linux containers**. Trong **Settings → Resources → WSL Integration**, bật distro Ubuntu bạn sẽ dùng. [Docker Desktop trên Windows](DOCKER-DESKTOP.md) · [Cài WSL](https://learn.microsoft.com/en-us/windows/wsl/install)

### 2. Mở terminal đúng môi trường

Từ PowerShell, mở distro theo tên hiển thị trong danh sách WSL.

```powershell
wsl -d Ubuntu
```

Từ đây chạy các lệnh Bash **trong Ubuntu WSL**. Docker Engine do Docker Desktop cung cấp. Cài các công cụ shell trong distro rồi kiểm tra engine hiện tại.

```bash
sudo apt update
sudo apt install git curl ca-certificates openssl python3
docker version
docker info --format '{{.OperatingSystem}} / {{.OSType}}/{{.Architecture}}'
docker compose version
docker buildx version
```

Kết quả phải hiện `Docker Desktop / linux/x86_64`. Nếu `docker` trong WSL không kết nối, bật lại integration cho đúng distro. Nếu shell trỏ nhầm Podman, chạy `unset DOCKER_HOST CONTAINER_HOST DOCKER_CONTEXT`, rồi kiểm tra lại Docker Desktop.

### 3. Clone repo, cấu hình và phục hồi

Để file repo và `.env` trong thư mục home của WSL. Làm theo [bước lấy hai repo](#2-lấy-hai-repo) và [bước chọn image và `.env`](#3-dùng-image-phát-hành-và-điền-env) của Phần 1. Hai bước này chạy nguyên trong Ubuntu WSL. Nếu Docker Desktop hiện đang chạy bản OASM Windows cũ, dùng môi trường đích riêng để tránh trùng tên container, mạng và cổng.

#### Windows A. Khôi phục snapshot cũ

Nếu snapshot nằm ở `E:\private-backup`, đặt đường dẫn dạng `/mnt/e` trong WSL và chạy từ cùng terminal đã đặt `NCS`, `UPSTREAM`, `PROJECT`.

```bash
SNAP="/mnt/e/private-backup/oasm-snapshot-YYYYMMDDTHHMMSSZ"
bash "$NCS/migrate-upstream-data.sh" --check "$SNAP" "$UPSTREAM" "$PROJECT" &&
  bash "$NCS/migrate-upstream-data.sh" "$SNAP" "$UPSTREAM" "$PROJECT"
```

Chờ `Upstream data imported and counts matched` rồi chuyển sang bước mở console. Đăng nhập bằng tài khoản đã có trong snapshot.

#### Windows B. Cài mới từ đầu

Tạo khóa mới trong `.env` và dùng project, volume trống. Ví dụ đặt `export PROJECT=oasm-upstream-new`, rồi chuyển thẳng tới bước mở console. Khi màn hình đầu tiên hiện lên, tạo admin cho instance mới.

#### Mở console trên Windows

Sau bước A hoặc B, mở console bằng đúng project đã chọn. Nếu Docker Desktop đã publish cổng `6276`, kiểm tra container giữ cổng theo [bước mở console trên Linux](#mở-console-trên-linux). Các lệnh `docker` ở đó chạy được trong Ubuntu WSL.

```bash
upstream_stack=(docker compose --project-directory "$UPSTREAM" --env-file "$UPSTREAM/.env"
  -p "$PROJECT" -f "$UPSTREAM/docker-compose.yml" -f "$NCS/compose.upstream-data.yaml")
"${upstream_stack[@]}" config --quiet &&
  "${upstream_stack[@]}" pull console core-api migration &&
  "${upstream_stack[@]}" up -d --wait --wait-timeout 240 console &&
  "${upstream_stack[@]}" ps -a
```

Trên Windows, mở [Open ASM local](http://localhost:6276). Có thể kiểm tra cổng từ PowerShell bằng `Get-NetTCPConnection -LocalPort 6276 -State Listen`. Trong Docker Desktop → **Containers**, chọn project `oasm-upstream-restore` hoặc tên đã đặt để xem log container.

### 4. Đổi logo, kết nối SIEM và bàn giao

1. Đăng nhập và đối chiếu workspace, assets, findings, URL cùng file đính kèm. Đổi tên và logo trong **Admin → Brand**. [Các bước nghiệm thu và đổi logo](#5-nghiệm-thu-dữ-liệu-và-đổi-logo)
2. Chạy Vector và collector API từ Ubuntu WSL. Dùng đường dẫn Linux khi cấu hình thư mục collector, nhập `OASM_RESULTS_IMAGE` theo tag API và `OASM_DOCKER_NETWORK=oasm_net` nếu giữ cấu hình upstream. Nếu dùng Docker Desktop cho cả OASM và Elastic PoC, kiểm tra container Vector có đường mạng tới Elasticsearch. [Các bước SIEM và alert](#6-thu-log-findings-và-kiểm-tra-alert)
3. Áp dụng [bảng nghiệm thu](#7-bàn-giao-và-vận-hành) trước khi chuyển sang production. Với production trên Linux, dùng cùng commit và phiên bản đã nghiệm thu rồi đặt lại đường dẫn, endpoint, proxy và khóa cho máy đích.
