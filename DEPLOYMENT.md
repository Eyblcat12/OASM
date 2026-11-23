# Triển khai Open ASM và chuyển dữ liệu NCS OASM

Quy trình này dùng **Compose của Open ASM gốc** và bộ script NCS OASM để chuyển dữ liệu, đổi nhận diện và kết nối SIEM. Chọn **Phần 1** cho Ubuntu hoặc **Phần 2** cho Windows. Cả hai dùng cùng quy trình nghiệm thu dữ liệu và cùng cấu hình đầu nhận.

| Hạng mục | Phiên bản hoặc phạm vi |
| --- | --- |
| Docker | Linux containers trên x86-64, Compose từ **2.24.4** để dùng overlay giới hạn cổng console trên loopback. |
| Bộ Compose upstream | Layout thử nghiệm tại [oasm-docker `56dc2c6`](https://github.com/oasm-platform/oasm-docker/tree/56dc2c657743200363b65cf2168ae4f91d0a953c). |
| Snapshot PoC ngày 21/11 | Dữ liệu được tạo từ API và console dựa trên Open ASM [`2e12e49`](https://github.com/oasm-platform/open-asm/tree/2e12e49e8ab5420746d9faf43fd48f57a923db58). Importer đã đối chiếu 128 target, 163 dịch vụ, 14 findings và 14.218 bản ghi URL lịch sử trong PostgreSQL thử nghiệm. |
| Đầu nhận | Elastic, Wazuh hoặc QRadar theo môi trường của System. Phần dưới đây dùng Elastic làm ví dụ kiểm tra alert. |

Quy trình gồm console, dữ liệu, **worker gốc**, collector và đối soát kết quả trên SIEM. Worker phải được khởi động ở bước 5; chỉ mở console chưa đủ để thực thi các job quét. Chạy quét và thử alert là hai bước nghiệm thu riêng sau khi hạ tầng đã sẵn sàng. Tài liệu OASM dùng repo `oasm-docker` để triển khai production và yêu cầu sao lưu khóa mã hóa. [Tài liệu Deployment chính thức](https://docs.oasm.io/deployment)

Chọn một luồng sau khi chuẩn bị Docker, repo và `.env`.

| Trường hợp | Linux | Windows |
| --- | --- | --- |
| Có snapshot cũ. Giữ khóa mã hóa nguồn, nhập dữ liệu vào project trống rồi đăng nhập bằng tài khoản cũ. | [Khôi phục snapshot](#linux-a-khôi-phục-snapshot-cũ) | [Khôi phục qua WSL](#6-khôi-phục-snapshot-qua-ubuntu-wsl-2) |
| Cài mới. Tạo khóa riêng, khởi tạo database trống rồi tạo admin đầu tiên. | [Cài mới](#linux-b-cài-mới-từ-đầu) | [Cài mới bằng PowerShell](#3-cài-mới-bằng-powershell) |

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
| `BASE_URL` | Bắt buộc điền trong quy trình này. Khi thử local dùng `http://localhost:6276`. Khi dùng reverse proxy, nhập origin HTTPS mà người dùng mở, không thêm đường dẫn hoặc dấu `/` cuối. Để trống có thể gây `INVALID_ORIGIN` khi collector đăng nhập. |
| `PORT` | Giữ `6277` cho API nội bộ của bộ Compose đã pin. Nginx upstream trỏ tới `core-api:6277`. |
| `POSTGRES_HOST`, `POSTGRES_USERNAME`, `POSTGRES_DB` | Dùng giá trị mẫu `postgres`, `postgres`, `open_asm` nếu dùng DB trong stack. Điền `POSTGRES_PASSWORD` riêng. |
| `REDIS_PASSWORD`, `REDIS_URL` | Tạo mật khẩu hex. Trong URL `redis://:<mật-khẩu>@redis:6379/0`, dùng cùng mật khẩu. |
| `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY`, `RUSTFS_ENDPOINT` | Điền thông tin xác thực object storage và giữ endpoint nội bộ `http://rustfs:9000` khi dùng RustFS trong stack. |
| `BETTER_AUTH_SECRET` | Khóa riêng của instance. |
| `ENCRYPTION_KEYS` | Cài mới dùng khóa ngẫu nhiên. Khôi phục dùng đúng khóa nguồn và giữ thứ tự nếu có nhiều khóa. |
| `OASM_CLOUD_APIKEY` | Điền giá trị theo cấu hình của môi trường; với PoC local, thay giá trị mẫu bằng khóa riêng của instance. |
| `TRUSTED_PROXIES` | Để trống khi mở trực tiếp. Nếu có reverse proxy, điền theo proxy tin cậy thực tế. |
| `DOCKER_GID` | Chạy `stat -c '%g' /var/run/docker.sock` trên Docker host và điền kết quả. Worker cần GID này để dùng Docker socket. |
| `WORKER_REPLICAS` | Bắt đầu với `1` cho PoC, tăng sau khi đo CPU/RAM và xác nhận ngân sách connector. |

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

### 5. Bật worker gốc, nghiệm thu dữ liệu và đổi logo

Sau khi API healthy, khởi động một worker của upstream. Lệnh áp dụng cho cả cài mới và restore, trên Linux hoặc Ubuntu WSL có Docker integration.

```bash
export DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
export WORKER_REPLICAS=1
"${upstream_stack[@]}" config --services
"${upstream_stack[@]}" pull oasm-worker &&
  "${upstream_stack[@]}" up -d --scale oasm-worker=1 oasm-worker
"${upstream_stack[@]}" ps -a oasm-worker
"${upstream_stack[@]}" logs --since 5m --tail 100 oasm-worker
```

Lưu cùng giá trị `DOCKER_GID` và `WORKER_REPLICAS=1` trong `.env` để lần vận hành sau không phụ thuộc biến terminal. `config --services` phải có `oasm-worker`; `ps` phải có container Up; trang **Workers** phải có worker Online. Worker chạy thường trực và tạo connector container khi nhận job. Các connector có thể được tái sử dụng hoặc xóa sau job theo pool của worker.

Nếu `config --services` không có worker, kiểm tra đang dùng đúng `docker-compose.yml` upstream và hai file trong biến `upstream_stack`. Có image worker trong Docker chưa đồng nghĩa service đã được tạo. Nếu worker không Online, đọc log trước khi chạy thử job; xem kiểm tra mạng `core-api:16276`, khóa đăng ký và quyền Docker socket. Không xóa token/state khi chưa xác định nguyên nhân.

1. **Cài mới:** tạo tài khoản admin từ màn hình đầu tiên. **Sau restore:** đăng nhập bằng tài khoản đã lưu trong snapshot.
2. **Cài mới:** xác nhận workspace mới mở được. **Sau restore:** chọn workspace nguồn và so **Targets**, **Assets**, **Services** và **Vulnerabilities** với `counts.txt`. Mở một bản ghi URL lịch sử, một finding và một workflow cũ. Tải thử một file đã lưu để kiểm tra RustFS.
3. Vào **Admin → Brand** (`/admin/brand`), điền tên hiển thị và tải icon. Có thể dùng [icon NCS](branding/ncs-oasm-icon.png). Đăng nhập lại và kiểm tra logo ở giao diện. [Thương hiệu và logo trong OASM](https://docs.oasm.io/brand-name-and-logo)

4. Khi được phép kiểm thử, chọn một mục tiêu nhỏ và một workflow phù hợp. Xác nhận job được nhận, connector thực thi, kết quả được lưu và job kết thúc không có cảnh báo ngắt sớm. `success=true` kèm `connector disconnected before Done` chỉ là kết quả một phần. Số findings bằng 0 không đủ chứng minh mục tiêu không có lỗ hổng. Ghi cấu hình, phạm vi, template, thời gian và lỗi bỏ qua vào biên bản.

### 6. Kết nối Elastic và kiểm tra dữ liệu, alert

Thực hiện phần này trên Docker host OASM. Trên Windows, các lệnh Bash chạy trong Ubuntu WSL có Docker Desktop integration. Elastic có thể nằm trên host khác. [Cấu hình một lần](SIEM-QUICKSTART.md) · [Đầu nhận Wazuh, QRadar và cấu hình thủ công](SIEM.md)

#### 6.1. Chọn địa chỉ và kiểm tra origin

| Giá trị | Ví dụ | Công dụng |
| --- | --- | --- |
| Origin console / `BASE_URL` | `http://localhost:6276` | Địa chỉ trình duyệt, dùng khi đăng nhập OASM. |
| API nội bộ / `OASM_BASE_URL` | `http://core-api:6277` | Collector kết nối API trong mạng Docker `oasm_net`. |
| Elasticsearch | `http://<SIEM-IP>:9200` hoặc URL HTTPS do quản trị cấp | Đầu nhận dữ liệu. |
| Kibana | `http://<SIEM-IP>:5601` hoặc URL HTTPS do quản trị cấp | Giao diện tra cứu, tạo key và alert. |
| RustFS | `http://rustfs:9000` | Object storage nội bộ OASM, không phải đầu nhận Elastic. |

Kiểm tra `BASE_URL` trong container API đang chạy; lệnh chỉ in địa chỉ:

```bash
docker exec oasm-api node -p 'process.env.BASE_URL || "(unset)"'
```

Nếu trống hoặc sai, sửa `BASE_URL` trong `$UPSTREAM/.env`. Dùng đúng origin thực tế, ví dụ `BASE_URL=http://localhost:6276` cho PoC qua trình duyệt local/SSH tunnel. Sau đó áp dụng khi không có job đang thực thi vì API sẽ gián đoạn ngắn:

```bash
"${upstream_stack[@]}" up -d --no-deps --force-recreate --wait --wait-timeout 180 core-api
docker exec oasm-api node -p 'process.env.BASE_URL'
```

`restart` không nạp giá trị `.env` mới. Không đổi `ENCRYPTION_KEYS` hoặc mật khẩu database để xử lý lỗi origin. `localhost` và `127.0.0.1` là hai origin khác nhau. Khi đổi sang HTTPS production, cập nhật cả BASE_URL, cấu hình reverse proxy và origin trong tài khoản collector.

#### 6.2. Chuẩn bị đường mạng Elasticsearch

Từ Docker host OASM thử endpoint thật, dùng `https://` khi đầu nhận bật TLS:

```bash
curl --connect-timeout 5 --max-time 10 -sS -o /dev/null \
  -w '%{http_code}\n' "http://<SIEM-IP>:9200"
```

HTTP `401` cho thấy endpoint trả lời và yêu cầu xác thực; chưa chứng minh API key có quyền ghi. HTTP `200` cho thấy endpoint trả lời thành công. Timeout hoặc connection refused cần kiểm tra listener, route và firewall trước. Kết nối từ host chỉ là bước đầu; kết quả ghi thật mới xác nhận đường đi từ container Vector.

Không nhập `localhost` làm endpoint của Elastic ở host khác: với Vector đó là loopback của container. Nếu OASM và Elastic cùng Docker host, dùng DNS và network chung đã cấu hình hoặc địa chỉ host truy cập được từ container. Với Docker Desktop, `host.docker.internal` là một lựa chọn cần kiểm tra trong môi trường thực tế. Với Linux Engine, không mặc định tên này có sẵn.

**Trường hợp PoC: Ubuntu VMware gửi tới Elastic trên Windows.** Ví dụ VM NAT có IP `192.168.44.159`, Windows VMnet8 có IP `192.168.44.1`. Đây là địa chỉ minh họa, phải thay theo `ip -4 addr` trên VM và `ipconfig` trên Windows. Nếu Docker Desktop chỉ publish Elastic tại `127.0.0.1:9200`, VM chưa thể truy cập qua VMnet8.

Trên PowerShell Windows kiểm tra:

```powershell
docker ps --format 'table {{.Names}}\t{{.Ports}}'
Get-NetTCPConnection -LocalPort 9200 -State Listen
netsh interface portproxy show v4tov4
```

Nếu cần giữ listener Elastic trên loopback, chuyển tiếp riêng cổng VMnet8 và giới hạn firewall cho VM. Chạy **PowerShell bằng Run as Administrator**, thay hai IP đúng môi trường:

```powershell
$ElasticHostIp = "192.168.44.1"
$OasmVmIp = "192.168.44.159"
netsh interface portproxy add v4tov4 listenaddress=$ElasticHostIp listenport=9200 connectaddress=127.0.0.1 connectport=9200
New-NetFirewallRule -DisplayName "OASM VM to Elasticsearch" -Direction Inbound -Action Allow -Protocol TCP -LocalAddress $ElasticHostIp -LocalPort 9200 -RemoteAddress $OasmVmIp
```

Kiểm tra lại bằng curl từ VM tới `http://192.168.44.1:9200`. Không cần chuyển tiếp Kibana để collector ghi dữ liệu. Dùng IP VM ổn định hoặc cập nhật firewall khi DHCP đổi IP. Đây là phương án lab trên máy Windows luôn bật; production dùng endpoint SIEM ổn định, mạng riêng và HTTPS theo cấu hình hệ thống. Portproxy chuyển tiếp TCP, không tự thêm mã hóa TLS.

Khi bỏ đường chuyển tiếp lab, dùng PowerShell administrator với cùng `$ElasticHostIp`:

```powershell
netsh interface portproxy delete v4tov4 listenaddress=$ElasticHostIp listenport=9200
Remove-NetFirewallRule -DisplayName "OASM VM to Elasticsearch"
```

Nếu Elastic nằm trong Docker Engine riêng của WSL thay vì Docker Desktop, kiểm tra listener và đường chuyển tiếp WSL trước; không áp dụng giả định Windows loopback đã có Elastic.

#### 6.3. Tạo tài khoản và API key

Tài khoản collector là tài khoản **OASM có thật**, đăng nhập được và có quyền đọc workspace, audit, assets và vulnerabilities. Sau restore dùng tài khoản có trong snapshot; cài mới tạo tài khoản theo chính sách của instance. Tên project Docker như `oasm-upstream-restore` khác tên project/workspace trong giao diện. Project Docker chỉ dùng chữ thường, số, `_`, `-`, bắt đầu bằng chữ thường hoặc số.

Trong Kibana → **Dev Tools → Console**, đăng nhập bằng tài khoản có quyền tạo API key và cấp quyền ghi, chạy:

```http
POST /_security/api_key
{
  "name": "oasm-siem-writer",
  "expiration": "7d",
  "role_descriptors": {
    "oasm_writer": {
      "indices": [{
        "names": [
          "logs-oasm.docker-poc", "logs-oasm.audit-poc",
          "logs-oasm.finding-poc", "logs-oasm.discovery-poc"
        ],
        "privileges": ["auto_configure", "create_doc"]
      }]
    }
  }
}
```

Lưu giá trị **`encoded`** trả về vào nơi quản lý bí mật và nhập trực tiếp vào setup. Không thêm tiền tố `ApiKey ` vào ô hỏi. Key mẫu hết hạn sau 7 ngày; production cần quy định thời hạn và lịch thay key. Quyền thực tế bị giới hạn bởi quyền của tài khoản tạo key. [API key Elasticsearch](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-security-create-api-key)

#### 6.4. Cấu hình và bật collector

```bash
git -C "$NCS" pull --ff-only origin main
python3 "$NCS/siem/setup-elastic.py"
```

| Câu hỏi | Giá trị |
| --- | --- |
| OASM Compose project | Giá trị `$PROJECT`; sau restore mặc định `oasm-upstream-restore`, cài mới ví dụ `oasm-upstream-new`. |
| OASM Docker network | `oasm_net` nếu giữ upstream. |
| OASM browser origin | Giống BASE_URL đã xác nhận, ví dụ `http://localhost:6276`. |
| OASM internal API origin | `http://core-api:6277`. |
| Collector account email/password | Tài khoản OASM đã chuẩn bị; mật khẩu nhập không hiển thị. |
| Workspace number | Chọn workspace chứa dữ liệu cần thu. Một bộ cấu hình chọn một workspace. |
| Elasticsearch URL | Endpoint vừa kiểm tra ở bước 6.2. |
| Elasticsearch API key | Chỉ giá trị `encoded` từ bước 6.3. |

Bộ cài lưu cấu hình vào `~/oasm-siem-managed`, ngoài Git. `Configuration saved` xác nhận đã lưu và kiểm tra đọc OASM; chưa xác nhận ghi được Elastic. Bật hai service:

```bash
siem=(docker compose --env-file "$HOME/oasm-siem-managed/collector.env"
  -f "$HOME/ncs-oasm/siem/compose.elastic.yaml")
"${siem[@]}" run --rm --no-deps vector validate --no-environment /etc/vector/vector.yaml &&
  "${siem[@]}" up -d
"${siem[@]}" ps
"${siem[@]}" logs --since 5m --tail 100
```

`results` đọc API và ghi NDJSON. `vector` đọc NDJSON cùng stdout/stderr Docker của project OASM, rồi gửi sang Elastic. Cả hai phải Up. Các dòng `Sync complete` và `Discovery synced` chỉ xác nhận bước đọc/ghi cục bộ. Vector validate dùng `--no-environment` và sink healthcheck tắt, nên không thay thế kiểm thử gửi thật. [Chi tiết cấu hình, dữ liệu và quyền](SIEM-QUICKSTART.md)

#### 6.5. Xác nhận trên Kibana

Trên OASM host lấy đúng tên host mà collector gắn vào dữ liệu:

```bash
grep '^OASM_SOURCE_HOST=' "$HOME/oasm-siem-managed/collector.env"
```

Trong Kibana → Dev Tools, thay `YOUR-OASM-HOST` bằng giá trị trên, bỏ dấu nháy bao quanh của file env:

```http
GET /logs-oasm.*-poc/_search
{
  "size": 0,
  "query": {"term": {"host.name": "YOUR-OASM-HOST"}},
  "aggs": {
    "datasets": {"terms": {"field": "event.dataset", "size": 10}}
  }
}
```

| Dataset | Nghiệm thu |
| --- | --- |
| `oasm.docker` | Có log mới của host đích, đúng container/service và thời gian. |
| `oasm.audit` | Đối chiếu ID, hành động, thời gian của sự kiện audit với OASM. |
| `oasm.finding` | Đối chiếu ID finding, mức độ, trạng thái và CVE nếu có. |
| `oasm.discovery` | Đối chiếu dịch vụ và URL; có dữ liệu discovery không tự chứng minh đã thu đủ cả hai loại. |

Nếu workspace có dữ liệu ở cả bốn nguồn, cần thấy đủ bốn nhóm. Với cài mới chưa có finding hoặc URL, ghi rõ nguồn đang trống; không tạo lỗ hổng trên mục tiêu thật để làm đủ số. Tăng từ 0 lên số bản ghi dương xác nhận có dữ liệu từ host đích. Có đủ bốn nhóm xác nhận bốn đường gửi hoạt động, **chưa chứng minh toàn bộ lịch sử đồng bộ đủ**.

Audit và discovery có ID chống trùng không gắn tên host. Khi chuyển snapshot sang VM rồi nhập vào cùng SIEM cũ, bản ghi trùng có thể giữ tên host nguồn. Đối soát theo `event.id`, workspace và ID tài sản trên toàn stream, không cộng số host VM rồi kết luận mất dữ liệu. Finding hiện tạo phiên bản từ nội dung chuẩn hóa có host, nên số đếm giữa các loại nguồn có thể khác cách chống trùng. Dòng `appended` là số ghi vào file collector, không phải số tài liệu Elastic chấp nhận.

Trong **Discover**, tạo data view `logs-oasm.*-poc`, chọn `@timestamp` và khoảng thời gian bao phủ kết quả cũ. `@timestamp` của audit/finding có thể là thời gian sự kiện nguồn, không phải thời điểm vừa nhập. Với discovery, đọc log `results` để kiểm tra riêng `source=service` và `source=url`. Polling: audit/findings khoảng nghỉ 10 giây, service 30 giây, URL 5 phút, cộng thời gian xử lý. Log Docker thu từ lúc Vector bắt đầu theo dõi. Đây là thu thập liên tục theo polling/stream, cần đo độ trễ thật khi nghiệm thu.

Để thử cập nhật mới, tạo một thay đổi quản trị vô hại được phép trong OASM, ghi lại ID/thời gian sự kiện, rồi tìm trên SIEM. Kiểm tra log mới từ API/worker theo cùng thời điểm. Không cần chạy lại toàn bộ scope để nghiệm thu collector.

#### 6.6. Alert và vận hành collector

Trong Kibana, tạo rule **Elasticsearch query** với data view findings và điều kiện ví dụ:

```text
event.dataset: "oasm.finding" and vulnerability.severity: ("high" or "critical")
```

Chạy mỗi phút, cửa sổ 5 phút, ngưỡng lớn hơn 0 là cấu hình lab để thử. Finding lịch sử nhập hôm nay có `@timestamp` cũ có thể không khớp cửa sổ này. Dùng Test query và sự kiện thử được phân biệt rõ trong môi trường lab để nghiệm thu alert, tránh lặp thông báo cùng finding; chốt khóa nhóm/chống trùng và cửa sổ theo dữ liệu thực tế trước bàn giao. Ingestion thành công không tự tạo alert hoặc tự gửi thông báo cho SOC. [Elasticsearch query rule](https://www.elastic.co/docs/explore-analyze/alerting/alerts/rule-type-es-query)

Khi mở terminal mới, khai báo lại mảng `siem` ở bước 6.4. Các lệnh thường dùng:

```bash
"${siem[@]}" ps
"${siem[@]}" logs --since 10m --tail 150 results vector
"${siem[@]}" stop
"${siem[@]}" up -d
```

`stop` ở đây chỉ dừng collector, không dừng OASM. Giữ `state`, file `out` và volume `oasm-siem_vector-data` qua restart. Theo dõi dung lượng NDJSON và buffer; buffer không lưu vô hạn. Không dùng `down -v` cho môi trường cần giữ dữ liệu.

Thư mục bí mật chứa `private/oasm-account.json` và `private/elastic.json`. Khi đổi mật khẩu/key, cập nhật file tương ứng qua trình soạn thảo trên host, giữ cấu trúc JSON, quyền và thư mục riêng, rồi chạy `"${siem[@]}" up -d --force-recreate`. File Elastic dùng dạng `{"authorization":"ApiKey <encoded>"}`. Nếu đổi endpoint, cập nhật cả `collector.env` và `vector.yaml` đã render, validate lại trước khi recreate Vector. Bộ setup chưa có chức năng ghi đè cấu hình đã tồn tại; không xóa checkpoint chỉ để chạy lại wizard.

#### 6.7. Xử lý lỗi thường gặp

| Hiện tượng | Kiểm tra và xử lý |
| --- | --- |
| Docker permission denied | Kiểm tra Docker context, quyền user và GID socket của worker. Đăng nhập lại sau khi thêm nhóm docker. |
| Không thấy worker / job queued | Thực hiện bước 5, kiểm tra service `oasm-worker`, container Up, trang Workers Online và log đăng ký. |
| Connector `registration rejected: invalid token` | Đọc log worker cùng job/execution, kiểm tra callback đúng replica và image tương thích. Phân biệt token connector với tài khoản collector. Không reset mọi khóa vì lỗi này. |
| `pool exhausted`, `busy=1 max=1` | Kiểm tra job đang giữ connector và ngân sách RAM/CPU. Chạy tuần tự hoặc cấp tài nguyên theo đo tải, không tăng replicas mù quáng. |
| Dừng sau khoảng 10 phút, `disconnected before Done` | Xác minh timeout thực tế của job/manifest và lý do dừng. Kết quả thu trước đó là một phần. Thiết lập timeout 60 phút ở PoC cũ không tự chuyển sang runtime upstream mới; không tự thêm khóa timeout ngoài schema Nuclei. |
| `egress deny ... reason=auth` | Proxy worker từ chối xác thực request. Kiểm tra log cùng execution và đường proxy connector; không kết luận website chặn IP hoặc bỏ xác thực để hết lỗi. |
| Setup `INVALID_ORIGIN` | Kiểm tra BASE_URL trong container, sửa `.env` và recreate API theo bước 6.1; nhập cùng browser origin. |
| Setup HTTP 401/403 khác | Xem endpoint/mã lỗi; kiểm tra account active, mật khẩu, membership và quyền đọc. [Bảng chẩn đoán](SIEM-QUICKSTART.md#5-lỗi-đăng-nhập-hoặc-quyền-đọc-oasm) |
| Vector `Request timed out` ở cả bốn sink | Kiểm tra endpoint, listener, route, firewall từ host rồi từ container. Với VMware → Windows xem bước 6.2. Chưa tăng timeout để che lỗi đường mạng. |
| Vector HTTP 401 | Key sai, hết hạn hoặc sai định dạng; thay encoded key trong secret. |
| Vector HTTP 403 | Kiểm tra quyền key trên đúng stream và quyền tài khoản cấp key; không cấp quyền toàn cluster để thử. |
| Vector HTTP 400 / mapping hoặc parse error | Xem lỗi chi tiết theo sink, kiểu field và dữ liệu nguồn; giữ file/buffer để đối soát, không xóa index để xử lý nhanh. |
| Không thấy tài liệu của host VM | Kiểm tra OASM_SOURCE_HOST, log results/vector và query bước 6.5; phân biệt dữ liệu cũ dưới tên host khác. |
| Index `yellow`, `rep=1` trên một node | Có thể do replica chưa được cấp phát. Kiểm tra cluster health; trạng thái này không tự chứng minh ingestion lỗi. Production cần kế hoạch replica/phục hồi. |
| API unhealthy sau restore | Xem `ps -a`, log migration/Postgres/RustFS/API; dùng overlay có phụ thuộc RustFS và thời gian khởi động healthcheck. |

### 7. Bàn giao và vận hành

| Kiểm tra trước khi bàn giao | Kết quả cần ghi nhận |
| --- | --- |
| Phiên bản | Commit Compose, tag hoặc digest API/console, và phiên bản PostgreSQL đã nghiệm thu. |
| Dữ liệu | Checksum đạt, đối soát đúng workspace, đọc được findings, URL và file cũ. |
| Giao diện | Đăng nhập được theo địa chỉ production, logo hiển thị, đường HTTPS và proxy đã được System kiểm tra. |
| SIEM | Một log mới từ host đích, một finding đã đối chiếu và một alert thử có bằng chứng trên SIEM. |
| Worker quét | Container Up, worker Online; có bằng chứng một job đã thực thi connector và lưu kết quả. Ghi riêng việc nghiệm thu alert và giới hạn phạm vi scan. |
| Bản sao lưu | Lưu PostgreSQL, object storage, audit và khóa mã hóa theo kênh riêng. Thử khôi phục vào một môi trường trống trước lần chuyển đổi lớn. |

Khi thay đổi phiên bản, giữ nguyên VM cũ đến khi máy mới đã được nghiệm thu. Nếu lệnh mở console báo `core-api` `unhealthy`, chạy `"${upstream_stack[@]}" ps -a`. Nếu API đã chuyển sang `healthy`, chạy lại lệnh mở console trên cùng project. Nếu RustFS chưa chạy hoặc API vẫn lỗi, cập nhật repo NCS để lấy overlay mới rồi kiểm tra log `core-api`, `rustfs`, `postgres` và `migration`. Nếu importer báo project hoặc volume đã tồn tại, kiểm tra Docker context và tên project. Dùng project trống để phục hồi thử.

Sau khi đóng terminal, khai báo lại đường dẫn và mảng Compose trước khi dùng các lệnh vận hành. Thay `PROJECT` bằng đúng project đang chạy, không tạo project mới để sửa một instance hiện có:

```bash
export NCS="$HOME/ncs-oasm"
export UPSTREAM="$HOME/oasm-upstream"
export PROJECT=oasm-upstream-restore
upstream_stack=(docker compose --project-directory "$UPSTREAM" --env-file "$UPSTREAM/.env"
  -p "$PROJECT" -f "$UPSTREAM/docker-compose.yml" -f "$NCS/compose.upstream-data.yaml")
"${upstream_stack[@]}" ps -a
```

Trước go-live, lưu commit của hai repo, digest các image, kết quả đếm dữ liệu và cấu hình đã nghiệm thu. Sao lưu dữ liệu hiện tại trước nâng cấp; snapshot PoC cũ không chứa các thay đổi phát sinh sau thời điểm xuất. Giữ `.env`, khóa mã hóa, mật khẩu và archive ngoài GitHub. Chốt lịch backup/restore, cấp phát tài nguyên, endpoint HTTPS, phạm vi quét, đầu mối dừng, nơi nhận alert và chính sách thay khóa. Chưa gọi production sẵn sàng chỉ vì console mở hoặc collector Up.

## Phần 2. Triển khai trên Windows

### 1. Phân biệt Docker backend và terminal

**OASM gốc cần Docker chạy Linux containers; không bắt buộc mở Ubuntu WSL để chạy Docker Compose.** Có thể cài mới và vận hành stack bằng PowerShell. Hướng dẫn có hai luồng:

| Nhu cầu | Luồng dùng |
| --- | --- |
| Cài mới OASM, bật worker và vận hành từ Windows | PowerShell + Docker Desktop, bước 2–5 dưới đây. |
| Khôi phục snapshot bằng `migrate-upstream-data.sh` hoặc chạy `setup-elastic.py` của repo này | Ubuntu WSL 2 tích hợp Docker Desktop, bước 6–7. Hai script hiện chưa có phiên bản Windows native. |
| Production trên Ubuntu/ESXi | Docker Engine trực tiếp, làm Phần 1; không cần Docker Desktop/WSL. |

Docker Desktop thường dùng **WSL 2 backend**, nhưng không yêu cầu cài riêng distro Ubuntu để dùng CLI từ PowerShell. Hyper-V backend là lựa chọn khi edition Windows, phần cứng và kiểu cài Docker Desktop hỗ trợ; kiểm tra yêu cầu hiện hành của Docker. Nếu dự kiến dùng các script restore/collector qua Ubuntu WSL, chọn WSL 2 backend ngay từ đầu và bật integration cho distro. [Docker Desktop trên Windows](https://docs.docker.com/desktop/setup/install/windows-install/) · [WSL integration](https://docs.docker.com/desktop/features/wsl/)

Đừng đổi backend hoặc Docker context để xử lý một lỗi ứng dụng mà chưa xác nhận container/volume đang nằm ở engine nào. Docker Desktop không được hỗ trợ trên Windows Server; với máy chủ đó dùng VM Linux phù hợp. [Yêu cầu và nền tảng hỗ trợ](https://docs.docker.com/desktop/setup/install/windows-install/#system-requirements)

### 2. Chuẩn bị Docker Desktop, Git và PowerShell

Kiểm tra **Task Manager → Performance → CPU → Virtualization: Enabled**. Cài Docker Desktop bản x86-64 và [Git for Windows](https://git-scm.com/install/windows), mở Docker Desktop, chọn **Linux containers** và chờ engine hoạt động. Xem [hướng dẫn Docker Desktop](DOCKER-DESKTOP.md) nếu cần cài backend WSL/Hyper-V.

Mở **PowerShell** mới, chạy:

```powershell
git --version
docker version
docker context ls
docker info --format '{{.OperatingSystem}} / {{.OSType}}/{{.Architecture}}'
docker compose version
docker run --rm hello-world
```

Cần có cả Client/Server, hệ điều hành container `linux`, kiến trúc x86-64/amd64 và Compose từ `2.24.4`. `hello-world` thoát sau khi in kết quả là bình thường. Chỉ dùng context đã xác nhận là Docker Desktop Linux engine; nếu `desktop-linux` hiện trong danh sách nhưng context hiện tại sai, kiểm tra `docker --context desktop-linux info` trước khi chọn. Không dùng chế độ Windows containers cho các image OASM này.

Phần PowerShell dưới đây tương thích cú pháp Windows PowerShell 5.1, không dùng `&&` hoặc mảng Bash. Trong Docker Desktop, có thể xem container, Logs và Stats qua giao diện; Compose CLI vẫn là nguồn cấu hình khi cần tạo lại container.

### 3. Cài mới bằng PowerShell

#### 3.1. Clone repo và chuẩn bị `.env`

Dùng thư mục trong tài khoản Windows, ví dụ dưới đây. Không chạy hai bộ upstream có tên container cố định trên cùng Docker engine.

```powershell
$NcsPath = Join-Path $env:USERPROFILE 'ncs-oasm'
$UpstreamPath = Join-Path $env:USERPROFILE 'oasm-upstream'
$OasmProject = 'oasm-upstream-new'

if (-not (Test-Path (Join-Path $NcsPath '.git'))) {
    git clone https://github.com/Eyblcat12/OASM.git $NcsPath
    if ($LASTEXITCODE -ne 0) { throw 'Clone NCS repo failed' }
}
if (-not (Test-Path (Join-Path $UpstreamPath '.git'))) {
    git clone https://github.com/oasm-platform/oasm-docker.git $UpstreamPath
    if ($LASTEXITCODE -ne 0) { throw 'Clone upstream repo failed' }
}
git -C $NcsPath pull --ff-only origin main
if ($LASTEXITCODE -ne 0) { throw 'Update NCS repo failed' }
git -C $UpstreamPath status --short
```

Xác nhận checkout upstream sạch trước khi pin commit. Giữ các thay đổi đang dùng của môi trường khác bằng cách chọn thư mục triển khai riêng.

```powershell
git -C $UpstreamPath checkout --detach 56dc2c657743200363b65cf2168ae4f91d0a953c
if ($LASTEXITCODE -ne 0) { throw 'Pin upstream commit failed' }
$OasmEnvPath = Join-Path $UpstreamPath '.env'
if (-not (Test-Path $OasmEnvPath)) {
    Copy-Item -LiteralPath (Join-Path $UpstreamPath '.env.example') -Destination $OasmEnvPath
}
notepad.exe $OasmEnvPath
```

Điền đầy đủ theo [bảng biến môi trường](#3-dùng-image-phát-hành-và-điền-env). Cho bản cài mới này, tối thiểu xác nhận các giá trị sau cùng toàn bộ mật khẩu/khóa riêng trong bảng:

```dotenv
IMAGE_TAG=v0.13.0
PORT=6277
BASE_URL=http://localhost:6276
DOCKER_GID=0
WORKER_REPLICAS=1
WORKER_NAME=oasm-builtin-worker
```

`DOCKER_GID=0` phù hợp Docker Desktop trong cấu hình này; native Linux phải đọc GID socket thực tế. Đừng mang `COMPOSE_FILE` hoặc `COMPOSE_PATH_SEPARATOR` từ bộ PoC cũ sang `.env` upstream vì có thể trộn các file Compose khác.

Nếu cần tạo khóa hex mà Windows chưa có OpenSSL, chạy hàm PowerShell sau rồi gọi mỗi lần cho một khóa riêng. Đây chỉ là tạo giá trị; vẫn cần điền vào đúng trường `.env` và giữ REDIS_URL khớp REDIS_PASSWORD. Không đưa các giá trị đã tạo vào Git hoặc chat.

```powershell
function New-OasmSecret {
    $secretBytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($secretBytes) } finally { $rng.Dispose() }
    return -join ($secretBytes | ForEach-Object { $_.ToString('x2') })
}
New-OasmSecret
```

Với restore, giữ đúng khóa mã hóa nguồn; không tạo khóa mới thay `ENCRYPTION_KEYS` đã dùng để xuất snapshot. Bảo vệ `.env` bằng quyền truy cập tài khoản Windows và kho bí mật của môi trường.

#### 3.2. Tạo lệnh Compose dùng lại

Sau khi lưu `.env`, khai báo mảng tham số và hàm dưới đây trong **cùng PowerShell**. Hàm dừng khi Docker báo lỗi để tránh tiếp tục trên một stack chưa sẵn sàng.

```powershell
$OasmCompose = @(
    'compose', '--project-directory', $UpstreamPath,
    '--env-file', (Join-Path $UpstreamPath '.env'),
    '-p', $OasmProject,
    '-f', (Join-Path $UpstreamPath 'docker-compose.yml'),
    '-f', (Join-Path $NcsPath 'compose.upstream-data.yaml')
)
function Invoke-Oasm {
    & docker @OasmCompose @args
    if ($LASTEXITCODE -ne 0) { throw "OASM Compose failed: $LASTEXITCODE" }
}
Invoke-Oasm config --quiet
Invoke-Oasm config --services
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Danh sách service phải có `oasm-worker`. Kiểm tra không có console cũ giữ cổng 6276 hoặc container upstream cùng tên. Nếu có, xác định đúng instance và bàn giao/dừng riêng service cũ trước khi tiếp tục; đổi project name không tránh được tên container cố định upstream.

#### 3.3. Mở console và bật worker

**Cài mới** trên project/volume trống thì chạy ngay khối dưới. **Khôi phục snapshot** thì làm bước 6 trước; không khởi tạo console trên database đích trước khi importer chạy.

```powershell
Invoke-Oasm pull console core-api migration oasm-worker
Invoke-Oasm up -d --wait --wait-timeout 240 console
Invoke-Oasm up -d --scale oasm-worker=1 oasm-worker
Invoke-Oasm ps -a
Invoke-Oasm logs --since 5m --tail 100 oasm-worker
curl.exe --fail --silent --show-error http://localhost:6276/api/health
docker exec oasm-api node -p 'process.env.BASE_URL || "(unset)"'
```

Mở [Open ASM local](http://localhost:6276) bằng trình duyệt Windows. Với cài mới, tạo admin đầu tiên; với restore đăng nhập bằng tài khoản trong snapshot. Xác nhận **Workers → Online** và container worker Up. Worker là service thường trực, connector được tạo khi job thực thi; console mở được chưa chứng minh worker hoạt động.

### 4. Kiểm tra chức năng và vận hành bằng PowerShell

Làm [nghiệm thu dữ liệu và logo](#5-bật-worker-gốc-nghiệm-thu-dữ-liệu-và-đổi-logo). Khi được phép quét, dùng scope nhỏ để xác nhận job được nhận, connector chạy và kết quả được lưu. Không khởi chạy toàn bộ 128 website chỉ để kiểm tra cài đặt.

```powershell
Invoke-Oasm ps -a
Invoke-Oasm logs --since 10m --tail 100 core-api oasm-worker
Get-NetTCPConnection -LocalPort 6276 -State Listen -ErrorAction SilentlyContinue
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Nếu sửa `.env`, áp dụng bằng recreate đúng service. Ví dụ BASE_URL cần cập nhật API; thực hiện khi không có job đang chạy vì kết nối worker có thể gián đoạn:

```powershell
Invoke-Oasm up -d --no-deps --force-recreate --wait --wait-timeout 180 core-api
docker exec oasm-api node -p 'process.env.BASE_URL'
```

`restart` chỉ khởi động lại container cũ, không nạp biến `.env` mới. Sau khi mở PowerShell khác, khai báo lại `$NcsPath`, `$UpstreamPath`, `$OasmProject`, `$OasmCompose` và hàm Invoke-Oasm. Giữ đúng project của instance đang chạy. Trong Docker Desktop → **Containers**, chọn project để xem Logs/Stats; không xóa volume khi xử lý lỗi.

### 5. Trường hợp không muốn dùng terminal WSL

Cài mới OASM và bật worker theo bước 3–4 có thể thực hiện hoàn toàn từ PowerShell. Nếu chỉ dùng Compose upstream thì không cần Ubuntu WSL làm terminal. Git Bash cũng chạy được các lệnh Docker Compose, nhưng phải dùng cú pháp Bash và chú ý chuyển đổi đường dẫn khi mount; không dán nguyên mảng Bash vào PowerShell.

**Giới hạn hiện tại của repo:** importer dữ liệu là Bash và bộ setup Elastic kiểm tra môi trường POSIX. Không chạy `python setup-elastic.py` trực tiếp trên Windows Python hoặc đổi tên `.sh` thành `.ps1`. Để dùng các tiện ích này, chọn bước 6–7 qua WSL. Đường cấu hình SIEM thủ công được mô tả ở [SIEM.md](SIEM.md); luồng cài đầy đủ tự động từ PowerShell chưa được cung cấp. Nếu cần giữ hoàn toàn môi trường Windows native cho vận hành, ghi rõ phần restore/collector còn phải giải quyết trước bàn giao.

### 6. Khôi phục snapshot qua Ubuntu WSL 2

Nếu đã cài mới xong ở bước 3 thì bỏ qua bước restore này. Restore yêu cầu đích trống. Dùng **cùng Docker Desktop engine** với PowerShell; WSL integration không tạo một môi trường OASM độc lập. Không cài thêm Docker Engine riêng trong distro khi mục tiêu là dùng dữ liệu/container của Docker Desktop.

Để chuẩn bị distro Ubuntu nếu chưa có, mở PowerShell administrator, chạy và khởi động lại khi Windows yêu cầu:

```powershell
wsl --install -d Ubuntu
wsl --update
wsl --list --verbose
```

Mở Ubuntu lần đầu để tạo tài khoản. Đảm bảo distro dùng VERSION 2. Trong Docker Desktop chọn WSL 2 backend và **Settings → Resources → WSL Integration → Ubuntu → Enable**. Mở terminal:

```powershell
wsl -d Ubuntu
```

Các lệnh sau chạy **trong Ubuntu WSL**:

```bash
sudo apt update
sudo apt install git curl ca-certificates openssl python3
docker info --format '{{.OperatingSystem}} / {{.OSType}}/{{.Architecture}}'
docker compose version
```

Phải thấy Docker Desktop/Linux. Nếu shell trỏ nhầm Podman hoặc daemon khác, kiểm tra `docker context ls` và các biến DOCKER_HOST, CONTAINER_HOST, DOCKER_CONTEXT trước khi tiếp tục.

Chọn **một bộ repo/cấu hình đích duy nhất**. Cách thuận tiện cho restore là đặt repo trong home WSL và thực hiện [bước lấy hai repo](#2-lấy-hai-repo), [điền env](#3-dùng-image-phát-hành-và-điền-env) của Phần 1. Khi đó vận hành stack bằng Bash của Phần 1, không dùng thêm bộ `.env` Windows khác. Đặt project:

```bash
export PROJECT=oasm-upstream-restore
SNAP="/mnt/e/private-backup/oasm-snapshot-YYYYMMDDTHHMMSSZ"
bash "$NCS/migrate-upstream-data.sh" --check "$SNAP" "$UPSTREAM" "$PROJECT" &&
  bash "$NCS/migrate-upstream-data.sh" "$SNAP" "$UPSTREAM" "$PROJECT"
```

Đường dẫn `/mnt/e/...` tương ứng ổ E của Windows; thay bằng vị trí snapshot thật. Chờ `Upstream data imported and counts matched`, rồi làm [mở console trên Linux](#mở-console-trên-linux) và [bật worker bước 5](#5-bật-worker-gốc-nghiệm-thu-dữ-liệu-và-đổi-logo) trong cùng WSL. Mở console trên trình duyệt Windows và đối chiếu dữ liệu với snapshot. Không restore vào stack đã có dữ liệu cài mới.

### 7. Collector SIEM qua WSL khi OASM chạy từ PowerShell

OASM và collector không cần clone repo ở cùng đường dẫn, nhưng phải nhìn thấy cùng Docker daemon và cùng network `oasm_net`. Với OASM đã cài bằng PowerShell, giữ nguyên `$UpstreamPath/.env` và project của nó. Trong Ubuntu WSL tích hợp Docker Desktop, clone repo hỗ trợ vào home WSL nếu chưa có:

```bash
sudo apt update
sudo apt install git curl ca-certificates python3
[[ -d "$HOME/ncs-oasm/.git" ]] || git clone https://github.com/Eyblcat12/OASM.git "$HOME/ncs-oasm"
git -C "$HOME/ncs-oasm" pull --ff-only origin main
docker ps --format 'table {{.Names}}\t{{.Ports}}'
python3 "$HOME/ncs-oasm/siem/setup-elastic.py"
```

Chọn project **`oasm-upstream-new`** nếu đã cài mới bằng PowerShell ở bước 3; không giữ mặc định `oasm-upstream-restore` khi instance có tên khác. Các giá trị mạng, origin, API nội bộ và key làm theo [bước 6 SIEM](#6-kết-nối-elastic-và-kiểm-tra-dữ-liệu-alert). Collector lưu `~/oasm-siem-managed` trong home WSL và dùng đường dẫn Linux. Không chép mật khẩu sang dòng lệnh PowerShell.

Chạy các lệnh validate/up mà setup in ra **trong WSL**. Nghiệm thu đủ bốn dataset trên SIEM theo tên host được ghi trong `collector.env`; với collector này tên host có thể là tên distro WSL, không phải hostname Windows. Không giả định `host.docker.internal:9200` truy cập được một listener Elastic chỉ bind loopback; kiểm tra từ container và đối soát ghi thật. Nếu Elastic ở máy khác, dùng endpoint mạng do quản trị cấp. Mục Windows/VMware ở 6.2 chỉ áp dụng khi có VM VMware riêng.

### 8. Nghiệm thu và bàn giao Windows

Áp dụng [bảng nghiệm thu](#7-bàn-giao-và-vận-hành), gồm worker Online, job thật trên scope được phép, kết quả lưu được, SIEM ghi thật và alert thử nếu nằm trong phạm vi. Ghi rõ backend Docker Desktop, context, project, nơi lưu `.env`, nơi lưu snapshot và đường dẫn collector. Docker Desktop phải chạy để các container hoạt động; kiểm tra lại sau khi Windows reboot và người vận hành đăng nhập. Đặt quy trình khởi động, theo dõi và backup phù hợp trước khi bàn giao.

Khi chuyển lên Ubuntu/ESXi production, giữ release/commit và dữ liệu đã nghiệm thu, dùng Docker Engine native theo Phần 1, đặt lại endpoint/proxy/GID theo máy đích. Snapshot mới phải được xuất từ instance đang vận hành, không dùng lại snapshot PoC cũ nếu muốn mang theo thay đổi mới nhất.
