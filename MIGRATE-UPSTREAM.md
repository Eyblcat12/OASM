# Chuyển dữ liệu cũ vào Open ASM gốc

Dùng quy trình này để nhập PostgreSQL, file RustFS và audit archive từ snapshot NCS OASM vào **một instance Open ASM gốc mới**. Image ứng dụng, cấu hình Docker và phiên bản Open ASM do bộ cài upstream quản lý. Script chỉ khởi động PostgreSQL trong lúc nhập dữ liệu và đối soát.

## Chuẩn bị máy đích

1. Chuẩn bị **VM Linux hoặc Docker daemon riêng** với Docker Compose từ 2.24.4 và Python 3. Compose upstream có các container đặt tên cố định, nên chọn máy đích riêng nếu máy cũ vẫn chạy OASM. [Docker trên Ubuntu](DOCKER-ENGINE.md)
2. Đặt repo triển khai Open ASM gốc và `.env` của máy đích trong cùng thư mục. Chọn phiên bản API/console tương thích với schema snapshot. Snapshot PoC này xuất từ Open ASM commit `2e12e49`. Ưu tiên xác nhận dữ liệu với phiên bản tương thích trước khi nâng cấp. [Mã nguồn upstream tại commit đã test](https://github.com/oasm-platform/open-asm/tree/2e12e49e8ab5420746d9faf43fd48f57a923db58)
3. Giữ đúng `ENCRYPTION_KEYS` của nguồn để đọc dữ liệu đã mã hóa. Kiểm tra thông tin xác thực RustFS và `BASE_URL` của máy đích. Chuyển snapshot và cấu hình qua kênh có phân quyền.
4. Chọn tên project Compose mới, tập trung vào dữ liệu đã lưu. Giữ nguyên stack đang hoạt động để đối chiếu cho tới khi nghiệm thu máy đích.

Ví dụ dưới đây giả định bộ script nằm tại `~/ncs-oasm`, bộ Compose upstream tại `~/oasm-upstream` và snapshot đã chép lên Desktop của VM. Thay tên snapshot và đường dẫn theo máy thực tế.

```bash
NCS="$HOME/ncs-oasm"
UPSTREAM="$HOME/oasm-upstream"
SNAP="$HOME/Desktop/oasm-snapshot-YYYYMMDDTHHMMSSZ"
PROJECT=oasm-upstream-restore
```

Nếu chưa có thư mục bộ cài upstream, clone bộ Compose gốc. Layout dưới đây được kiểm tra với `oasm-docker` tại commit `56dc2c6`. [Bộ Compose upstream đã đối chiếu](https://github.com/oasm-platform/oasm-docker/tree/56dc2c657743200363b65cf2168ae4f91d0a953c)

```bash
git clone https://github.com/oasm-platform/oasm-docker.git "$UPSTREAM"
git -C "$UPSTREAM" checkout --detach 56dc2c657743200363b65cf2168ae4f91d0a953c
```

Sau khi điền file `"$UPSTREAM/.env"` với cấu hình máy đích, chạy từ cùng terminal.

```bash
bash "$NCS/migrate-upstream-data.sh" --check "$SNAP" "$UPSTREAM" "$PROJECT" &&
  bash "$NCS/migrate-upstream-data.sh" "$SNAP" "$UPSTREAM" "$PROJECT"
```

`--check` xác minh checksum của năm file dữ liệu và kiểm tra project đích chưa có container, volume. Lệnh thật nhập PostgreSQL bằng một transaction, so với `counts.txt`, kiểm tra job và lịch còn hoạt động rồi mới nhập hai archive RustFS và audit. Script giữ lịch sử job đã kết thúc và yêu cầu rà soát nếu phát hiện job hoặc lịch còn hoạt động. Image archive, Redis và trạng thái worker nằm ngoài dữ liệu nhập của quy trình này.

## Mở console và đối chiếu

Khi script in `Upstream data imported and counts matched`, dùng cùng project, `.env` và overlay để mở console upstream. Overlay gắn audit archive và giới hạn console ở `127.0.0.1:6276`. Các lệnh này chọn service `console` và những phụ thuộc của nó trong bộ Compose gốc.

```bash
upstream_stack=(docker compose --project-directory "$UPSTREAM" --env-file "$UPSTREAM/.env"
  -p "$PROJECT" -f "$UPSTREAM/docker-compose.yml" -f "$NCS/compose.upstream-data.yaml")
"${upstream_stack[@]}" up -d --wait --wait-timeout 240 console
"${upstream_stack[@]}" ps -a
```

Mở console theo `BASE_URL` đã cấu hình ở máy đích. Đăng nhập bằng tài khoản trong snapshot, chọn đúng workspace rồi đối chiếu target, dịch vụ và findings với `counts.txt`. Mở một bản ghi URL lịch sử và tải thử một file đã lưu để nghiệm thu RustFS. Snapshot là bản sao toàn bộ cơ sở dữ liệu nên cũng giữ tài khoản, project, cấu hình và nội dung đã lưu trong các workspace.

## Đổi logo sau khi nghiệm thu dữ liệu

Đăng nhập bằng tài khoản admin rồi mở **Admin → Brand** (`/admin/brand`). Đặt tên hiển thị và tải icon từ [thư mục branding](branding/) nếu dùng lại nhận diện NCS. Mở lại console trong phiên trình duyệt khác để kiểm tra logo tải được từ object storage. Cách này dùng chức năng có sẵn của Open ASM.

Nếu log báo project hoặc volume đã tồn tại, kiểm tra tên project và Docker context trước khi tiếp tục. Nếu bước đối soát dừng giữa chừng, giữ project và log đó để chẩn đoán, rồi dùng một project trống cho lần thử tiếp theo.
