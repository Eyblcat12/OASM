# Sử dụng và vận hành NCS OASM

## Dùng giao diện

| Mục | Dùng để |
| --- | --- |
| **Projects / Targets** | Mở project, kiểm tra danh sách website và target đã đăng ký. |
| **Assets / Services** | Xem host và dịch vụ đã ghi nhận. Chọn một asset để xem thông tin liên quan. |
| **Vulnerabilities** | Xem finding đã lưu theo asset, mức độ và trạng thái. Mở chi tiết để đọc bằng chứng và tham chiếu. |
| **Runs** | Mở một lần chạy cũ để xem trạng thái, thời gian và lỗi của từng job. |
| **Workflows** | Xem cấu hình đã lưu, các bước của workflow và phạm vi asset được gắn vào project. |

## Quản lý dịch vụ

Chạy lệnh trong thư mục repo NCS OASM.

```bash
bash compose.sh ps -a
bash compose.sh logs --tail 100 core-api console postgres
curl --fail --silent --show-error http://localhost:6276/api/health
```

Dịch vụ `migration` chạy theo lượt và có thể hiện `Exited (0)` sau khi hoàn tất. Các dịch vụ chạy dài hạn dùng `restart: unless-stopped` để mở lại khi Docker khởi động. Nếu console tải chậm hoặc không mở được, xem log `core-api`, `migration` và `postgres` theo thời điểm lỗi.

Dừng hoặc mở lại stack bằng các lệnh sau. Lệnh `stop` giữ volume và để dịch vụ ở trạng thái dừng cho tới khi bạn mở lại.

```bash
bash compose.sh stop
bash compose.sh up -d --wait --wait-timeout 240 console
```

Để áp dụng chính sách khởi động lại cho một instance đã cài, cập nhật repo rồi chạy `bash compose.sh up -d --wait --wait-timeout 240 console` với cùng project name và file `.env`.

Khi cập nhật logo trên một instance đã cài bằng phiên bản cũ, chạy lệnh SQL với PostgreSQL đang hoạt động, rồi tạo lại console.

```bash
git pull --ff-only
bash compose.sh exec -T postgres \
  psql -X -v ON_ERROR_STOP=1 -U postgres -d open_asm < branding/apply.sql
bash compose.sh up -d --no-deps --force-recreate console
```

## Sao lưu

Xuất PostgreSQL, RustFS, audit và image của instance theo [hướng dẫn sao lưu](RESTORE.md#xuất-snapshot-từ-bản-cài-docker-compose).

## Kiểm tra tích hợp

Bạn cần đầu nhận thử nghiệm, cơ chế xác thực và quyền tra cứu sự kiện ở hệ thống nhận.

| Luồng | Thao tác | Kiểm tra kết quả |
| --- | --- | --- |
| **TI** | Dùng [finding mẫu](fixtures/finding.json) để kiểm tra định dạng. Nếu tích hợp hỗ trợ, dùng chức năng **Test** trong OASM để kiểm tra đường truyền. | Tìm sự kiện theo ID và đối chiếu asset, mức độ, URL và loại sự kiện. |
| **SIEM** | Dùng [log mẫu](fixtures/operational-log.json) để thử ánh xạ trường dữ liệu. Sau khi cấu hình collector, gửi một log thực của môi trường cài. | Tìm log theo ID tương quan hoặc theo thời điểm và dịch vụ. |

Trước khi gửi mẫu, cập nhật thời gian UTC và dùng ID mới nếu đầu nhận chống trùng. Đối chiếu bản ghi ở đầu nhận sau khi có phản hồi tiếp nhận.
