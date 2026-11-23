# Worker kiểm kê thụ động trên OASM

Service `worker-passive` đăng ký vào workspace OASM và giữ trạng thái kết nối trong **Workers**. Công việc kiểm thử dùng file kiểm kê và advisory đã có. Worker đối chiếu chính xác hệ sinh thái, tên và phiên bản gói, rồi lưu kết quả cục bộ. Việc so khớp dùng những phiên bản được liệt kê cụ thể trong file đầu vào.

Worker chỉ gọi hai RPC `Join` và `Alive` trên API nội bộ. Công việc đọc từ file đầu vào riêng. Workflow quét, hàng đợi job của OASM và kho findings OASM nằm ngoài luồng của service này. Bộ Compose chính tiếp tục phục vụ console, API và storage.

## 1. Chuẩn bị bộ cài và khóa

Dùng Ubuntu/Linux hoặc WSL 2 với Docker Desktop integration. Thực hiện từ thư mục repo đã restore, với cùng `.env` và tên project hiện tại. Service dùng runtime Node.js có trong image `local/oasm-api:poc-2e12e49`. Đây cũng là image API của bộ cài.

```bash
export OASM_PASSIVE_DIR="$HOME/.local/share/ncs-oasm/passive-worker"
export OASM_PASSIVE_UID="$(id -u)"
export OASM_PASSIVE_GID="$(id -g)"
install -d -m 0700 "$OASM_PASSIVE_DIR" "$OASM_PASSIVE_DIR/input" "$OASM_PASSIVE_DIR/state"
```

Trong workspace muốn dùng, mở **Workers → Connect worker**, lấy **join key dùng một lần** từ hộp thoại. Chỉ lưu phần giá trị vào file riêng trên máy triển khai. Token worker sau lần đăng ký đầu được lưu trong thư mục `state`; giữ thư mục này để worker giữ cùng danh tính khi khởi động lại.

```bash
read -r -s -p 'OASM worker join key: ' OASM_PASSIVE_JOIN_KEY
printf '\n'
(umask 077; printf '%s\n' "$OASM_PASSIVE_JOIN_KEY" > "$OASM_PASSIVE_DIR/join-key")
unset OASM_PASSIVE_JOIN_KEY
```

## 2. Khởi động service

Dùng cùng hai file Compose rồi kiểm tra cấu hình trước khi chạy. Khi áp dụng overlay lần đầu, Compose có thể tạo lại container API để nối nó vào mạng nội bộ dành cho worker. Thao tác này có thể làm giao diện mất kết nối trong chốc lát.

```bash
compose_worker=(docker compose --env-file .env -f compose.yaml -f compose.passive-worker.yaml)
"${compose_worker[@]}" config --quiet
"${compose_worker[@]}" up -d --wait --wait-timeout 240 worker-passive
"${compose_worker[@]}" logs --tail 30 worker-passive
```

Tìm `worker.online` trong log và worker tên **OASM Passive Inventory** trong **Workers**. Nếu thấy `worker.connection_error`, kiểm tra API đã sẵn sàng và join key còn hiệu lực. Nếu đã đổi workspace hoặc thu hồi worker, dùng thư mục `state` dành riêng cho danh tính mới và join key mới.

## 3. Kiểm thử đối chiếu CVE bằng dữ liệu mẫu

Chép [file mẫu](worker/inventory.example.json) thành `inventory.json` trong thư mục đầu vào. Khi cập nhật dữ liệu thật, đổi tên file tạm sau khi ghi xong để worker đọc trọn một bản.

```bash
cp worker/inventory.example.json "$OASM_PASSIVE_DIR/input/inventory.json.tmp"
mv "$OASM_PASSIVE_DIR/input/inventory.json.tmp" "$OASM_PASSIVE_DIR/input/inventory.json"
```

Sau khoảng 10 giây, kiểm tra kết quả và log.

```bash
"${compose_worker[@]}" logs --tail 30 worker-passive
cat "$OASM_PASSIVE_DIR/state/inventory-results.json"
```

File mẫu phải tạo một sự kiện `inventory.completed` với **2 gói và 1 kết quả khớp**. `inventory-results.json` giữ danh sách ứng viên CVE của công việc gần nhất. Mỗi công việc có ID theo nội dung đầu vào, nên worker bỏ qua file giữ nguyên. Khi gắn SIEM, kiểm tra log hoàn tất trong luồng Docker theo tên service `worker-passive`. [Hướng dẫn SIEM](SIEM.md)

Để tạm dừng, dùng `"${compose_worker[@]}" stop worker-passive`. Khi mở lại stack có worker, dùng cùng hai file Compose để giữ cấu hình mạng.
