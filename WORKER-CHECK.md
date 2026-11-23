# Kiểm tra container worker gốc

Overlay này chạy **image worker gốc** có trong snapshot PoC Windows. Mục tiêu là kiểm tra container và trạng thái **Online** trong OASM. Gateway nội bộ chỉ chuyển tiếp `Join` và `Alive`; job discovery, scanner và lệnh từ xa nằm ngoài luồng kiểm tra. Service được tạo là `worker-check`, riêng với [worker kiểm kê từ file](WORKER-PASSIVE.md).

Nếu worker CLI chạy trực tiếp trên host báo `rpc error: code = Unavailable`, kiểm tra đường gRPC của cấu hình đang dùng. Bộ Compose chính chỉ publish cổng console `6276`. Overlay này kiểm tra gRPC trong mạng Docker, dùng riêng mạng worker và mạng API có gateway ở giữa.

## Chạy trên VM đã restore

Mở Bash trên Ubuntu hoặc WSL 2 có Docker integration. Chạy từ thư mục repo với cùng `.env` và tên project đã dùng khi restore.

```bash
docker image inspect --format '{{.Id}}' local/oasm-worker:poc-2e12e49
export OASM_CHECK_DIR="$HOME/.local/share/ncs-oasm/worker-check"
export OASM_CHECK_UID="$(id -u)" OASM_CHECK_GID="$(id -g)"
install -d -m 0700 "$OASM_CHECK_DIR" "$OASM_CHECK_DIR/state"
```

Trong OASM, chọn workspace rồi mở **Workers → Connect worker** để lấy join key một lần. Dùng join key mới cho phép thử và lưu trong file riêng trên VM.

```bash
read -r -s -p 'OASM worker join key: ' OASM_CHECK_JOIN_KEY
printf '\n'
(umask 077; printf '%s\n' "$OASM_CHECK_JOIN_KEY" > "$OASM_CHECK_DIR/join-key")
unset OASM_CHECK_JOIN_KEY
```

Áp dụng overlay. Compose có thể tạo lại container API trong lần chạy đầu để nối mạng kiểm thử, làm console mất kết nối trong chốc lát.

```bash
check_stack=(docker compose --env-file .env -f compose.yaml -f compose.worker-check.yaml)
"${check_stack[@]}" config --quiet
"${check_stack[@]}" up -d --wait --wait-timeout 240 worker-check
"${check_stack[@]}" ps worker-check worker-check-gateway
"${check_stack[@]}" logs --tail 30 worker-check worker-check-gateway
```

Trong **Workers**, tìm **OASM Stock Worker Check**. Phép thử đạt khi Docker hiện container `worker-check` đang chạy, log worker báo đã join và OASM hiện Online. Stock worker có thể ghi `Unimplemented` khi thử gọi các RPC ngoài `Join` và `Alive`; đó là hành vi dự kiến trong cấu hình kiểm tra. Nút **Run** của workflow OASM vẫn dùng hàng đợi riêng và không thuộc phép thử này.

Khi xong, dừng hai service kiểm tra bằng `"${check_stack[@]}" stop worker-check worker-check-gateway`. Giữ thư mục `state` để lần sau kiểm tra với cùng danh tính worker.
