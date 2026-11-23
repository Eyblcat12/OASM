# Docker Desktop trên Windows

Dùng Docker Desktop chạy **Linux containers** để triển khai OASM trên Windows x86-64. Có thể cài mới và vận hành Compose upstream bằng PowerShell theo [Deployment trên Windows](DEPLOYMENT.md#phần-2-triển-khai-trên-windows), không bắt buộc mở terminal Ubuntu WSL. Docker Desktop có thể dùng WSL 2 backend hoặc backend Hyper-V trên cấu hình được Docker hỗ trợ. Hướng dẫn dưới đây trình bày cách phổ biến dùng backend WSL 2; cài distro Ubuntu và bật integration khi cần chạy các script restore/collector POSIX của repo.

## 1. Chuẩn bị Windows và WSL 2

Kiểm tra phiên bản Windows bằng `winver` và đối chiếu yêu cầu hiện hành của Docker Desktop. Trong **Task Manager → Performance → CPU**, kiểm tra **Virtualization** hiện `Enabled`. Nếu tính năng này đang tắt, bật hỗ trợ ảo hóa CPU trong BIOS/UEFI theo hướng dẫn của hãng máy. [Yêu cầu Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/#system-requirements)

Nếu chưa cài WSL, mở **PowerShell với quyền administrator** rồi chạy lệnh sau. Khởi động lại Windows nếu được yêu cầu, mở Ubuntu lần đầu và tạo tài khoản Linux.

```powershell
wsl --install -d Ubuntu
```

Nếu đã có WSL, cập nhật và kiểm tra phiên bản.

```powershell
wsl --update
wsl --version
wsl --list --verbose
```

Khi định chạy Bash trong một distro WSL, cột `VERSION` của distro đó cần là `2`. Nếu đang dùng WSL 1, chuyển bằng `wsl --set-version Ubuntu 2` với đúng tên hiển thị trong danh sách. [Cài đặt và chuyển phiên bản WSL](https://learn.microsoft.com/en-us/windows/wsl/install)

## 2. Cài Docker Desktop

1. Tải bộ cài **Windows x86_64** từ Docker và chạy `Docker Desktop Installer.exe`. Chọn backend **WSL 2** khi bộ cài hỏi. [Tải Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/)
2. Mở **Docker Desktop** từ Start menu. Kiểm tra điều kiện sử dụng áp dụng cho tổ chức rồi hoàn tất lần mở đầu tiên. Chờ ứng dụng báo engine đang chạy. [Điều khoản sử dụng Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/#start-docker-desktop)
3. Trong **Settings → General**, kiểm tra **Use the WSL 2 based engine** nếu tùy chọn này hiển thị. Nếu menu Docker ở khay hệ thống có **Switch to Linux containers**, chọn mục đó. [Backend WSL 2](https://docs.docker.com/desktop/features/wsl/)

## 3. Kiểm tra Docker và Compose

Mở cửa sổ PowerShell mới sau khi cài.

```powershell
docker version
docker context ls
docker info --format '{{.OSType}}/{{.Architecture}}'
docker compose version
docker buildx version
docker run --rm hello-world
```

Kết quả mong đợi là `docker version` có cả `Client` và `Server`, `docker info` trả `linux/x86_64`, Compose và Buildx hiện phiên bản. `hello-world` tải image thử nếu cần, in thông báo thành công rồi thoát.

## 4. Chọn terminal để chạy lệnh OASM

### Git Bash

Cài [Git for Windows](https://git-scm.com/install/windows), mở **Git Bash** từ Start menu và kiểm tra CLI. Với file ở ổ E, dùng đường dẫn dạng `/e/private-backup`.

```bash
git --version
docker compose version
```

### WSL 2

Trong Docker Desktop, vào **Settings → Resources → WSL Integration**, bật distro bạn định dùng rồi chọn **Apply**. Trong PowerShell, mở distro bằng `wsl -d Ubuntu` hoặc thay `Ubuntu` bằng tên distro của bạn. CLI trong distro sẽ dùng Engine của Docker Desktop. Ổ E của Windows xuất hiện ở `/mnt/e` theo cấu hình mount mặc định của WSL. [Tích hợp distro WSL](https://docs.docker.com/desktop/features/wsl/#enable-docker-in-a-wsl-2-distribution)

```bash
docker info --format '{{.OperatingSystem}} / {{.OSType}}/{{.Architecture}}'
docker compose version
git --version
```

Kiểm tra `OperatingSystem` hiển thị **Docker Desktop**. Nếu distro Ubuntu chưa có Git và curl, chạy `sudo apt update` rồi `sudo apt install git curl` trong distro.

### Xử lý lỗi thường gặp

| Triệu chứng | Cách kiểm tra |
| --- | --- |
| `docker` không được nhận diện trong PowerShell | Kiểm tra Docker Desktop đã cài xong, mở cửa sổ PowerShell mới rồi chạy `Get-Command docker`. |
| Lỗi `dockerDesktopLinuxEngine` hoặc named pipe | Mở Docker Desktop, chờ engine chạy và kiểm tra Linux containers. Kiểm tra context bằng `docker context ls`. Nếu `desktop-linux` có trong danh sách, thử `docker --context desktop-linux info`. |
| Docker Desktop chạy nhưng nhận `windows/...` | Chuyển sang Linux containers từ menu Docker ở khay hệ thống, rồi chạy lại `docker info`. |
| WSL không tìm thấy Docker hoặc CLI trỏ tới `podman.sock` | Bật WSL Integration cho đúng distro rồi mở terminal mới. Nếu shell kế thừa biến Podman, chạy `unset DOCKER_HOST CONTAINER_HOST DOCKER_CONTEXT` rồi thử `docker --context default info`. Kiểm tra kết quả hiện Docker Desktop. |
| Cổng `6276` đã có tiến trình nghe | Trong PowerShell, chạy `Get-NetTCPConnection -LocalPort 6276 -State Listen` để xem PID và xử lý cổng trước khi mở OASM. |

## Chọn phương thức cài đặt

Luồng triển khai đầy đủ hiện tại là [Deployment Windows](DEPLOYMENT.md#phần-2-triển-khai-trên-windows): cài mới bằng PowerShell, restore snapshot qua WSL, bật worker gốc và gửi SIEM. Các tài liệu INSTALL/RESTORE bên dưới mô tả bộ PoC trước đây; chọn đúng luồng và không trộn hai bộ Compose vào một instance.

- [Cài mới từ mã nguồn](INSTALL.md) để tạo instance trống.
- [Khôi phục từ snapshot](RESTORE.md) để mang theo dữ liệu cũ. Chuẩn bị `.env` trong repo rồi chạy `bash deploy-test.sh --check "$snapshot"` trước khi restore. Đặt biến `snapshot` theo đúng đường dẫn của terminal đang dùng.

```bash
# Git Bash
snapshot="/e/private-backup/oasm-snapshot-YYYYMMDDTHHMMSSZ"
```

```bash
# WSL 2
snapshot="/mnt/e/private-backup/oasm-snapshot-YYYYMMDDTHHMMSSZ"
```

Sau khi cài, mở [NCS OASM trên máy local](http://localhost:6276).

## Xem log

Trong Docker Desktop, vào **Containers** rồi chọn project Compose tương ứng. Tên mặc định là **oasm-ti-siem-test**. Mở container cần kiểm tra và chọn **Logs**. Hoặc dùng [các lệnh vận hành trên CLI](OPERATIONS.md#quản-lý-dịch-vụ).
