# Cài collector OASM cho Elastic

Bộ collector này thu log Docker, audit, findings và kết quả discovery. Chạy một lần bộ cấu hình để chọn workspace, nhập tài khoản OASM và đầu nhận Elastic. Collector tự đăng nhập và đăng nhập lại khi phiên hết hạn. File cấu hình, checkpoint và bí mật nằm trong `~/oasm-siem-managed` trên máy triển khai.

Quy trình đầy đủ gồm BASE_URL, API key, kết nối VM VMware tới Elastic trên Windows, kiểm tra bốn dataset và xử lý timeout nằm ở [Deployment, bước 6](DEPLOYMENT.md#6-kết-nối-elastic-và-kiểm-tra-dữ-liệu-alert). Với bản cài mới, nhập đúng project Docker đã chọn thay vì giữ mặc định project restore.

## 1. Chuẩn bị tài khoản và đầu nhận

Trong OASM, tạo hoặc chọn tài khoản thu thập riêng có quyền đọc workspace, audit, assets và vulnerabilities của workspace cần giám sát. Kiểm tra tài khoản này đăng nhập được. Giữ mật khẩu trong nơi lưu bí mật của môi trường.

Chuẩn bị địa chỉ Elasticsearch mà container trên VM truy cập được và một API key có quyền `auto_configure`, `create_doc` cho bốn stream `logs-oasm.docker-poc`, `logs-oasm.audit-poc`, `logs-oasm.finding-poc`, `logs-oasm.discovery-poc`. [Mẫu tạo API key](SIEM.md#elastic)

Với HTTPS dùng CA nội bộ, cài CA vào cấu hình TLS của Vector theo tiêu chuẩn môi trường trước khi chạy. Trường hợp mặc định dùng CA hệ thống có sẵn trong image Vector. [Vector TLS](https://vector.dev/docs/reference/configuration/sinks/elasticsearch/#tls)

## 2. Cấu hình một lần

Trên Linux hoặc Ubuntu WSL 2 đã bật Docker Desktop integration, chạy:

```bash
git -C "$HOME/ncs-oasm" pull --ff-only origin main
python3 "$HOME/ncs-oasm/siem/setup-elastic.py"
```

Trình cấu hình sẽ hỏi project OASM, mạng Docker, địa chỉ console, API nội bộ, tài khoản OASM, workspace và đầu nhận Elastic. Với VM đã restore theo hướng dẫn upstream, giữ mặc định `oasm-upstream-restore`, `oasm_net`, `http://localhost:6276` và `http://core-api:6277`. Image API được tự nhận diện từ container đang chạy.

Địa chỉ Elasticsearch phải truy cập được từ container. Khi Elastic ở máy Windows bên ngoài VM, dùng địa chỉ mạng Windows có thể kết nối từ VM. Với PoC có SSH tunnel hoặc mạng riêng, xác nhận đường đi từ container theo [hướng dẫn mạng SIEM](SIEM.md#elastic).

Sau khi lưu, trình cấu hình in lệnh kiểm tra Vector, khởi động và xem log. Có thể chạy bằng các lệnh cố định dưới đây.

```bash
siem=(docker compose --env-file "$HOME/oasm-siem-managed/collector.env"
  -f "$HOME/ncs-oasm/siem/compose.elastic.yaml")
"${siem[@]}" run --rm --no-deps vector validate --no-environment /etc/vector/vector.yaml &&
  "${siem[@]}" up -d
"${siem[@]}" logs --tail 30
```

## 3. Xác nhận dữ liệu

Trong log collector `results`, tìm `Sync complete` và `Discovery synced`. Trong Kibana → Discover, tạo data view `logs-oasm.*-poc` với trường thời gian `@timestamp`. Chọn khoảng thời gian đủ rộng để xem findings cũ.

| Dataset | Kết quả cần kiểm tra |
| --- | --- |
| `oasm.docker` | Log mới từ console/API/worker của đúng host và project. |
| `oasm.audit` | Một sự kiện audit đã có, trùng `event.id` với nguồn. |
| `oasm.finding` | Một finding đã lưu, trùng `oasm.finding.id`, mức độ và CVE nếu có. |
| `oasm.discovery` | Dịch vụ hoặc URL đã lưu trong workspace. |

Audit và findings được đọc sau khoảng nghỉ 10 giây. Dịch vụ được đọc sau khoảng nghỉ 30 giây và URL sau khoảng nghỉ 5 phút. Tần suất thực tế cộng thời gian đọc và ghi. Vector giữ bộ đệm trên đĩa khi đầu nhận tạm gián đoạn. Lượt đầu nhập kết quả API đang trả về. Log Docker thu từ thời điểm collector kết nối; lịch sử Docker còn lưu cần nhập theo lô nếu muốn backfill.

Sau migrate vào cùng SIEM, audit/discovery trùng ID có thể giữ tên host cũ. Đối soát ID nguồn trên toàn stream trước khi kết luận thiếu dữ liệu khi lọc host mới. `Sync complete` xác nhận collector ghi cục bộ; đủ bốn dataset trên SIEM xác nhận đường gửi, cần đối soát riêng để kết luận đủ lịch sử và đo độ trễ cập nhật.

## 4. Vận hành

Mở lại terminal thì khai báo lại biến `siem` như ở bước 2. Dùng `"${siem[@]}" ps` để xem trạng thái và `"${siem[@]}" logs --tail 80` khi có lỗi. Khởi động lại sau khi đổi mật khẩu OASM hoặc khóa Elastic bằng `"${siem[@]}" up -d --force-recreate`.

Thông tin tài khoản nằm trong `private/oasm-account.json`. Khóa Elastic nằm trong `private/elastic.json`. Giữ thư mục `state` và volume Vector qua các lần restart. Theo dõi hạn của API key và dung lượng đĩa cho NDJSON cùng bộ đệm. Bộ cài xác minh đăng nhập và quyền đọc OASM; nghiệm thu mạng và quyền ghi Elastic bằng một sự kiện thật sau khi khởi động. [Chi tiết Wazuh, QRadar và alert](SIEM.md)

## 5. Lỗi đăng nhập hoặc quyền đọc OASM

Nếu bộ cấu hình báo HTTP 401/403, cập nhật repo rồi chạy lại. Thông báo mới ghi endpoint bị từ chối và mã lỗi xác thực nếu API cung cấp. Khi chưa chọn workspace, bộ cài chưa kết nối Elasticsearch và chưa tạo file bí mật.

| Điểm lỗi | Kiểm tra và xử lý |
| --- | --- |
| `/api/auth/sign-in/email`, `INVALID_ORIGIN` | Nhập đúng origin console theo `BASE_URL` của API đang chạy, gồm giao thức và cổng. `localhost` và `127.0.0.1` là hai origin khác nhau. |
| `/api/auth/sign-in/email`, `BANNED_USER`, `USER_BANNED` hoặc `EMAIL_NOT_VERIFIED` | Quản trị viên kiểm tra trạng thái tài khoản, xác minh email và duyệt tài khoản theo cấu hình OASM. |
| `/api/auth/sign-in/email`, HTTP 401 hoặc `INVALID_EMAIL_OR_PASSWORD` | Đăng nhập thử cùng tài khoản tại đúng console bằng cửa sổ riêng tư để kiểm tra mật khẩu, tránh dùng phiên trình duyệt đã lưu. |
| `/api/workspaces`, HTTP 401 | Kiểm tra session cookie và HTTPS của console. |
| `/api/workspaces` hoặc endpoint đọc dữ liệu, HTTP 403 | Kiểm tra thành viên workspace và quyền đọc audit, assets, vulnerabilities của tài khoản collector. |

Xem log xác thực gần thời điểm thử bằng `docker logs --since 5m --tail 100 oasm-api`. Chỉ chia sẻ dòng lỗi liên quan đã che thông tin nhạy cảm; không gửi mật khẩu, cookie hoặc nội dung `.env`. Nếu không có mã lỗi và log API không ghi request tương ứng, kiểm tra access/error log của reverse proxy console. Giữ cơ chế xác thực của OASM khi xử lý lỗi.
