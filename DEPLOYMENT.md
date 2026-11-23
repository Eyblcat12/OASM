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

### 4. Bật worker, đổi logo, kết nối SIEM và bàn giao

1. Bật worker gốc theo [bước 5](#5-bật-worker-gốc-nghiệm-thu-dữ-liệu-và-đổi-logo), gồm GID Docker socket và một replica. Kiểm tra container Up và worker Online. Đăng nhập, đối chiếu workspace, assets, findings, URL cùng file đính kèm; đổi tên và logo trong **Admin → Brand**.
2. Chạy setup, Vector và collector API từ Ubuntu WSL theo [bước 6](#6-kết-nối-elastic-và-kiểm-tra-dữ-liệu-alert). Dùng đường dẫn Linux và xác nhận endpoint Elastic truy cập được từ container. Nếu Ubuntu là VM VMware riêng thay vì WSL, áp dụng mục 6.2 cho đường mạng Windows/VMware. Kiểm tra dữ liệu theo host mới và đối soát chống trùng sau migrate.
3. Áp dụng [bảng nghiệm thu](#7-bàn-giao-và-vận-hành) trước khi chuyển sang production. Với production trên Linux, dùng cùng commit và phiên bản đã nghiệm thu rồi đặt lại đường dẫn, endpoint, proxy và khóa cho máy đích.
