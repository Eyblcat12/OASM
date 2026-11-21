# Docker Desktop trên Windows

Dùng hướng dẫn này cho máy Windows chạy PoC. Các container chạy ở chế độ Linux trong Docker Desktop. Cài Docker Desktop theo tài liệu chính thức và dùng Git Bash đi kèm Git for Windows cho lệnh phục hồi. [Cài Docker Desktop trên Windows](https://docs.docker.com/desktop/setup/install/windows-install/).

## Kiểm tra trước khi chạy

Mở Docker Desktop, chờ engine sẵn sàng, rồi chạy trong PowerShell hoặc Git Bash:

```text
docker info --format '{{.OSType}}/{{.Architecture}}'
docker compose version
```

Kết quả mong đợi là Linux trên x86-64 và Compose v2. Nếu không thấy named pipe của engine, kiểm tra Docker Desktop đang chạy và context đang trỏ vào engine Linux. Nếu cổng 6276 đang được bản PoC cũ sử dụng, phục hồi qua một máy thử riêng hoặc giải phóng cổng trong cửa sổ bảo trì.

## Khôi phục dữ liệu và mở giao diện

Clone repo, lấy thư mục snapshot đầy đủ từ System và tạo `.env` theo README. Chạy từ Git Bash. Ví dụ dưới đây dùng thư mục snapshot trên ổ E.

```bash
git clone https://github.com/Eyblcat12/OASM.git oasm-vm-ti-siem
cd oasm-vm-ti-siem
cp .env.example .env
# Điền .env và kiểm tra đường mạng thử nghiệm theo README trước khi chạy.
bash deploy-test.sh /e/private-backup/oasm-snapshot-YYYYMMDDTHHMMSSZ
```

Mở `http://localhost:6276` sau khi dịch vụ sẵn sàng. Trong Docker Desktop, chọn **Containers → oasm-ti-siem-test → container → Logs**. Kiểm tra API, console và kết quả restore theo README. Dùng PowerShell 7.4+ và [Export-Snapshot.ps1](Export-Snapshot.ps1) khi cần xuất dữ liệu từ máy PoC gốc.
