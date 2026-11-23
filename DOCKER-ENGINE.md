# Docker Engine trên Linux

Dùng các bước dưới đây cho máy chủ hoặc VM **Ubuntu 24.04 LTS x86-64**. Máy cần quyền `sudo`, kết nối tới kho APT và các registry dùng để tải image. Với bản phân phối khác, dùng kho Docker tương ứng với hệ điều hành. [Docker Engine theo bản phân phối](https://docs.docker.com/engine/install/)

## 1. Kiểm tra máy và Docker hiện có

```bash
cat /etc/os-release
uname -m
dpkg --print-architecture
df -h /
```

Trên VM dùng để phục hồi snapshot này, kết quả cần là Ubuntu `24.04`, kiến trúc `x86_64` và gói `amd64`. Nếu đã có Docker, chạy `docker version` và `docker compose version`. Có thể dùng tiếp khi CLI kết nối được tới Engine và Compose plugin hoạt động.

Trước khi đổi sang kho Docker chính thức, kiểm tra các gói có thể xung đột.

```bash
dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' \
  docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc \
  2>/dev/null | awk '$1 == "ii" { print $2 }'
```

Trên VM cài mới, nếu lệnh liệt kê gói xung đột, xem trước kế hoạch gỡ bằng `apt -s remove <tên-gói>`, rồi dùng `sudo apt remove <tên-gói>` với các gói đã xác định. Trên host đang phục vụ ứng dụng, kiểm tra các dịch vụ phụ thuộc trước khi đổi gói, đặc biệt là `containerd` và `runc`. [Danh sách gói xung đột](https://docs.docker.com/engine/install/ubuntu/#uninstall-old-versions)

## 2. Thêm kho Docker chính thức

```bash
sudo apt update
sudo apt install ca-certificates curl git
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL -o /etc/apt/keyrings/docker.asc https://download.docker.com/linux/ubuntu/gpg
sudo chmod 0644 /etc/apt/keyrings/docker.asc

docker_ubuntu_suite="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $docker_ubuntu_suite
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
apt-cache policy docker-ce docker-compose-plugin
```

Trên Ubuntu 24.04, suite là `noble`. Kiểm tra `apt-cache policy` có phiên bản ứng viên từ `download.docker.com` trước khi cài. [Cài từ kho APT của Docker](https://docs.docker.com/engine/install/ubuntu/#install-using-the-apt-repository)

## 3. Cài Engine, Compose và Buildx

```bash
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker.service containerd.service
systemctl is-active docker.service containerd.service
sudo docker run --rm hello-world
```

Hai service cần báo `active`. Container thử sẽ tải image từ Docker Hub nếu chưa có trên máy. Khi chạy thành công, nó in `Hello from Docker!` rồi thoát. Lệnh `docker compose` dùng Compose plugin và `docker buildx` dùng Buildx để build khi cài từ mã nguồn. [Các bước sau khi cài Docker Engine](https://docs.docker.com/engine/install/linux-postinstall/)

## 4. Cấp quyền cho tài khoản triển khai

Nếu System cho phép tài khoản triển khai điều khiển Docker daemon, thêm tài khoản vào nhóm `docker`. Quyền này tương đương quyền root trên host. Chỉ cấp cho tài khoản vận hành được phê duyệt. [Quyền của nhóm Docker](https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user)

```bash
sudo usermod -aG docker "$USER"
```

Đăng xuất rồi đăng nhập lại, hoặc mở phiên SSH mới để nhận quyền nhóm. Dùng cùng tài khoản này khi cấu hình và chạy NCS OASM.

## 5. Xác nhận trước khi triển khai OASM

```bash
id -nG
docker version
docker info --format '{{.OSType}}/{{.Architecture}}'
docker compose version
docker buildx version
ss -ltn 'sport = :6276'
```

Kết quả mong đợi là `docker version` có cả `Client` và `Server`, `docker info` trả `linux/x86_64`, Compose và Buildx hiện phiên bản. Trước khi mở OASM lần đầu, kiểm tra chưa có tiến trình nghe trên địa chỉ loopback cổng `6276`.

### Xử lý lỗi thường gặp

| Triệu chứng | Cách kiểm tra |
| --- | --- |
| `Cannot connect to the Docker daemon` | Chạy `systemctl is-active docker.service`, rồi xem `sudo journalctl -u docker.service -n 50 --no-pager` nếu service lỗi. Kiểm tra thêm `docker context ls` nếu CLI có nhiều engine. |
| `permission denied` trên `/var/run/docker.sock` | So sánh `docker info` và `sudo docker info`. Nếu chỉ lệnh có `sudo` thành công, kiểm tra nhóm của phiên hiện tại bằng `id -nG` và đăng nhập lại sau khi được cấp quyền. |
| CLI trỏ nhầm Podman hoặc máy Docker khác | Trên host dùng daemon hệ thống, chạy `unset DOCKER_HOST DOCKER_CONTEXT` rồi `docker --context default info` trong shell đang kiểm tra. |
| `docker: 'compose' is not a docker command` | Kiểm tra đã cài `docker-compose-plugin` từ cùng kho với Docker CLI, rồi chạy lại `docker compose version`. |
| `Unable to locate package docker-ce` hoặc lỗi kho APT | Kiểm tra kết quả `sudo apt update`, suite `noble`, kiến trúc, quyền đọc `/etc/apt/keyrings/docker.asc` và kết nối mạng. Nếu APT báo xung đột `Signed-By`, kiểm tra các mục khai báo cùng kho trong `/etc/apt/sources.list.d/`. |
| Tải image lỗi DNS, proxy hoặc TLS | Kiểm tra kết nối của VM, trạng thái registry và CA của tổ chức. Nếu VM cần proxy, cấu hình proxy cho Docker daemon. [Docker daemon proxy](https://docs.docker.com/engine/daemon/proxy/) |

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
