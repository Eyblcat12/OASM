# Chuyển dữ liệu bằng snapshot

Dùng quy trình này để dựng lại NCS OASM trên **Ubuntu/Linux** hoặc **Docker Desktop trên Windows** và giữ dữ liệu đã có. Snapshot mang theo tài khoản, workspace, project, target, dịch vụ, findings và cấu hình đã lưu trong PostgreSQL. Archive RustFS và audit chứa file và dữ liệu audit đã xuất. `oasm-images.tar` có image của API và console, nên có thể đi thẳng tới phục hồi từ snapshot.

## 1. Kiểm tra Docker và lấy repo

| Máy đích | Mở terminal ở đâu | Điều kiện trước khi tiếp tục |
| --- | --- | --- |
| Ubuntu hoặc VM Linux | Terminal trên VM hoặc phiên SSH vào VM | Docker Engine đang chạy. Tài khoản triển khai có quyền dùng Docker. [Cài Docker Engine](DOCKER-ENGINE.md) |
| Windows, Git Bash | **Git Bash** sau khi mở Docker Desktop | Docker Desktop đã khởi động và đang dùng Linux containers. [Cài Docker Desktop](DOCKER-DESKTOP.md) |
| Windows, WSL 2 | Terminal của distro WSL đã bật Docker integration | `docker info` từ distro kết nối tới Docker Desktop. [Thiết lập WSL 2](DOCKER-DESKTOP.md#4-chọn-terminal-để-chạy-lệnh-oasm) |

Chạy các lệnh dưới đây bằng chính tài khoản sẽ phục hồi. `docker version` cần có phần **Server**, `docker info` hiện `linux/x86_64` và `docker compose version` hiện phiên bản plugin.

```bash
docker version
docker context ls
docker info --format '{{.OSType}}/{{.Architecture}}'
docker compose version
```

Nếu chưa có repo trên máy đích, clone một lần. Nếu đã có, vào thư mục repo hiện tại. Khi triển khai production, dùng đúng commit đã nghiệm thu trên VM test.

```bash
cd "$HOME"
git clone https://github.com/Eyblcat12/OASM.git ncs-oasm
cd ncs-oasm
```

Thực hiện các bước tiếp theo từ thư mục repo. Chọn Docker daemon dành cho môi trường đích và project Compose chưa có container, volume. Project mặc định là `oasm-ti-siem-test`. Trên daemon đang dùng chung, lưu ý import snapshot có thể cập nhật các tag image OASM nội bộ. Dùng VM hoặc daemon riêng nếu cần cách ly khỏi instance đang chạy.

## 2. Chọn thư mục snapshot

Chép cả thư mục snapshot tới máy đích qua kênh có phân quyền, ngoài thư mục repo. Dùng bản được xuất sau thay đổi cuối cùng cần mang sang. Đặt biến `SNAP` theo terminal đang dùng và thay `YYYYMMDDTHHMMSSZ` bằng tên thư mục thực tế.

| Máy hoặc terminal | Ví dụ lệnh Bash |
| --- | --- |
| Ubuntu, snapshot nằm trên Desktop | `SNAP="$HOME/Desktop/oasm-snapshot-YYYYMMDDTHHMMSSZ"` |
| Windows, Git Bash, snapshot nằm trên ổ E | `SNAP="/e/private-backup/oasm-snapshot-YYYYMMDDTHHMMSSZ"` |
| Windows, WSL 2, cùng thư mục trên ổ E | `SNAP="/mnt/e/private-backup/oasm-snapshot-YYYYMMDDTHHMMSSZ"` |

```bash
ls -lh "$SNAP"
```

Thư mục cần có `SHA256SUMS`, `counts.txt`, `workspace-id.txt`, `postgres.dump`, `oasm-images.tar`, `rustfs-data.tar.gz` và `audit-archive.tar.gz`. Snapshot xuất bằng `export-data.sh` có thêm `image-ids.txt`. Snapshot từ script PoC Windows `Export-Snapshot.ps1` có `redis-data.tar.gz` và `worker-state.tar.gz` trong danh mục checksum. Redis khởi tạo mới khi restore để tránh phát lại hàng đợi cũ. Collector SIEM và đầu nhận TI được cấu hình riêng trên môi trường đích.

### Image và trạng thái worker khi chuyển từ PoC Windows

| Thành phần | Sau khi phục hồi bằng bộ cài này |
| --- | --- |
| `oasm-images.tar` do `Export-Snapshot.ps1` tạo | Chứa image API, console và worker. Script restore nạp toàn bộ archive, rồi kiểm tra ID của API và console vì hai image này được dùng để mở ứng dụng. |
| `worker-state.tar.gz` | Archive của volume trạng thái worker. Script kiểm tra checksum của file trong snapshot PoC Windows. Quy trình restore hiện tại chỉ khôi phục volume RustFS và audit. |
| Worker trên máy đích | `compose.yaml` chưa khai báo worker quét. Docker có thể đã nạp image worker từ snapshot PoC mà chưa có container worker. Sau khi restore, dùng [overlay kiểm tra worker gốc](WORKER-CHECK.md) để xác nhận container và trạng thái Online, hoặc [overlay kiểm kê thụ động](WORKER-PASSIVE.md) để đối chiếu CVE từ file. |

Sau khi restore snapshot PoC Windows, kiểm tra riêng image đã nạp và các service được khai báo.

```bash
docker image inspect --format '{{.Id}}' local/oasm-worker:poc-2e12e49
bash compose.sh config --services
```

Lệnh thứ nhất đọc thông tin image từ Docker. Lệnh thứ hai liệt kê service của bộ cài. Snapshot do `export-data.sh` tạo từ bộ Compose hiện tại chỉ đóng gói hai image API và console.

## 3. Chuẩn bị `.env` trên máy đích

```bash
umask 077
cp -n .env.example .env
```

Mở `.env` bằng trình soạn thảo trên máy đích. Trên Windows, giữ file trong thư mục chỉ tài khoản vận hành được phép đọc. Điền theo các mục trong [`.env.example`](.env.example) và giữ giá trị thật ngoài GitHub.

| Biến | Giá trị cho máy đích |
| --- | --- |
| `BASE_URL` | `http://localhost:6276` nếu mở browser ngay trên máy đích hoặc truy cập bằng SSH tunnel ở cùng cổng. Với reverse proxy HTTPS, dùng origin mà browser truy cập. |
| `TRUSTED_PROXIES` | Để trống khi truy cập trực tiếp. Điền theo proxy tin cậy của môi trường đích nếu có. |
| `POSTGRES_PASSWORD`, `REDIS_PASSWORD` | Mật khẩu của hai dịch vụ trên máy đích. Với Redis, dùng giá trị dạng hex vì Compose đưa mật khẩu vào URI kết nối. |
| `OASM_CLOUD_APIKEY`, `BETTER_AUTH_SECRET` | Điền theo cấu hình môi trường đích. Với PoC, có thể dùng cấu hình nguồn đã bàn giao. |
| `ENCRYPTION_KEYS` | Giữ nguyên giá trị từ instance đã xuất snapshot, kể cả thứ tự nếu có nhiều khóa. |
| `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY` | Điền cặp thông tin xác thực cho object storage. Dùng cặp đã bàn giao khi phục hồi PoC và thử tải file sau khi khởi động. |

`COMPOSE_PROJECT_NAME` là tùy chọn. Nếu chọn tên khác để tách project, cấu hình trước khi restore và giữ cùng tên ở các lần khởi động sau. Tài khoản đăng nhập OASM đã nằm trong PostgreSQL của snapshot.

## 4. Kiểm tra trước khi khôi phục

```bash
bash compose.sh config --quiet
bash deploy-test.sh --check "$SNAP"
```

Mỗi file trong checksum phải hiện `OK`, sau đó có dòng `Snapshot checksums and Compose configuration passed for ...`. Bước này kiểm tra file và cấu hình. Quyền kết nối Docker được xác nhận riêng bằng `docker info` ở bước 1. Trước khi chạy restore thật, kiểm tra cổng `6276` còn trống trên máy đích.

## 5. Khôi phục dữ liệu và mở console

```bash
bash deploy-test.sh "$SNAP"
```

Script nạp image API và console từ snapshot, tải image hạ tầng còn thiếu, khởi động PostgreSQL và nhập `postgres.dump`. Sau khi đối soát với `counts.txt`, script khôi phục RustFS và audit rồi áp dụng nhận diện NCS OASM. Khi hoàn tất, terminal hiện hai thông báo sau.

```text
Data restored and counts matched for oasm-ti-siem-test.
Console and API are ready at http://localhost:6276.
```

Dòng thứ nhất xác nhận restore và đối soát dữ liệu đã xong. Dòng thứ hai xác nhận console đã chạy và truy cập được API. Với máy production cần kiểm tra cấu hình tích hợp trước khi mở API, có thể tách hai giai đoạn bằng `bash restore-data.sh "$SNAP"`, rồi dùng `bash compose.sh up -d --wait --wait-timeout 240 console` sau khi đối soát xong.

## 6. Xác minh dữ liệu sau restore

```bash
bash compose.sh ps -a
curl --fail --silent --show-error http://localhost:6276/api/health
grep -E '^(targets_in_project_workspace|projects|services|findings|project_workflows)=' "$SNAP/counts.txt"
```

`migration` có thể hiện `Exited (0)` vì chỉ chạy một lần. Từ browser trên máy đích, mở [OASM](http://localhost:6276). Nếu quản trị VM từ máy khác, dùng [SSH tunnel](DOCKER-ENGINE.md#truy-cập-từ-máy-khác).

1. Mở console và đăng nhập bằng tài khoản đã có trên instance nguồn.
2. Chọn đúng workspace rồi so số target, dịch vụ và findings với `counts.txt`. Mở thử một finding cũ, một workflow hoặc profile đã chỉnh, và tải một file đính kèm nếu snapshot có.
3. Sau khi cấu hình collector, xác nhận SIEM thấy log mới từ máy đích và đối chiếu một finding cùng một bản ghi discovery đã lưu. Nếu có đầu nhận TI, thực hiện phép thử theo hướng dẫn vận hành. [Hướng dẫn SIEM](SIEM.md) · [Kiểm tra tích hợp](OPERATIONS.md#kiểm-tra-tích-hợp)

## 7. Xử lý lỗi thường gặp

| Thông báo hoặc triệu chứng | Cách xử lý |
| --- | --- |
| `permission denied ... /var/run/docker.sock` | Kiểm tra `docker version` bằng đúng tài khoản triển khai. Trên Linux xem phần cấp quyền nhóm Docker. Trên Windows kiểm tra backend Linux và WSL Integration cho distro đang dùng. |
| `Configure .env and provide a completed snapshot with SHA256SUMS` | Kiểm tra `.env` nằm ở thư mục repo, đường dẫn `SNAP` trỏ vào thư mục có `SHA256SUMS`, và file đã chép xong. |
| Checksum báo `FAILED` | Chép lại file lỗi từ bản backup nguồn rồi chạy lại `--check`. |
| `Loaded image does not match the snapshot` | Đối chiếu `oasm-images.tar` với snapshot gốc và commit bộ triển khai. Giữ nguyên đầy đủ thư mục backup khi thử lại. |
| `Destination volume already exists` hoặc `Destination project already contains containers` | Kiểm tra project hiện có bằng `bash compose.sh ps -a`. Nếu cần thử restore lại, giữ các volume cũ để đối soát và chọn một `COMPOSE_PROJECT_NAME` trống. Kiểm tra xung đột cổng `6276` nếu cả hai project dùng cùng máy. |
| Script dừng trước `Data restored and counts matched` | Xem dòng lỗi đầu tiên và log PostgreSQL bằng `bash compose.sh logs --tail 100 postgres`. Giữ snapshot và volume để chẩn đoán trước khi chạy lại. |
| Đã có `Data restored and counts matched`, console chưa sẵn sàng | Xem `bash compose.sh ps -a` và `bash compose.sh logs --tail 100 core-api console migration`. Sửa lỗi rồi mở lại console bằng `bash compose.sh up -d --wait --wait-timeout 240 console` trên chính project đó. |

Khi gửi lỗi để hỗ trợ, gửi thông báo lỗi và trạng thái container liên quan. Giữ `.env`, khóa và nội dung snapshot trong kênh bàn giao riêng.

## Xuất snapshot từ bản cài Docker Compose

Dùng Bash hoặc Git Bash trên máy đang chạy instance. Tạo trước thư mục backup riêng, bên ngoài repo. Trong cửa sổ bảo trì, dừng các ứng dụng đang ghi dữ liệu, rồi dừng console, API và RustFS. Giữ PostgreSQL hoạt động.

```bash
bash compose.sh stop console core-api rustfs
bash export-data.sh /path/to/private-backup 00000000-0000-0000-0000-000000000000
```

Thay GUID bằng ID workspace bạn muốn đối soát. Nếu cần tra ID, liệt kê các workspace bằng lệnh sau.

```bash
bash compose.sh exec -T postgres psql -X -U postgres -d open_asm \
  -c 'SELECT id, name FROM public.workspaces ORDER BY name;'
```

Script xuất toàn bộ database, đối soát workspace được chọn, rồi ghi archive và checksum. Chỉ bàn giao snapshot sau thông báo **Snapshot ready**. Lưu khóa và cấu hình môi trường riêng. Khi sao lưu xong, dùng `bash compose.sh up -d --wait --wait-timeout 240 console` để mở lại ứng dụng.

## Xuất snapshot nguồn trên Windows

Với bản PoC Windows cũ trong project `oasm-docker`, dùng [script PowerShell](Export-Snapshot.ps1) và PowerShell 7.4 trở lên. Tạo trước thư mục backup riêng. Trong cửa sổ bảo trì, kết thúc các công việc còn chạy, dừng worker, API, Redis và RustFS. Giữ PostgreSQL hoạt động trong lúc xuất.

```powershell
& .\Export-Snapshot.ps1 -PrivateBackupDirectory 'E:\private-backup' `
  -ProjectWorkspaceId '00000000-0000-0000-0000-000000000000' `
  -ExpectedProjectTargets 128
```

Thay GUID và số target bằng giá trị workspace thực tế. Chờ thông báo **Snapshot ready** và kiểm tra thư mục có `SHA256SUMS` trước khi chuyển đi.
