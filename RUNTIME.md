# Đổi timeout Nuclei bằng một lệnh

Tiện ích `manage-runtime.py` dùng trên Linux hoặc Ubuntu WSL đang kết nối đúng Docker engine của OASM. Nó giữ nguyên source/image upstream, đọc manifest hiện tại, đổi duy nhất timeout Nuclei và tạo overlay riêng. Không chạy quét tự động và không sửa rate limit, template, CPU/RAM hay cấu hình worker.

## Sử dụng

Cập nhật repo. Chạy lệnh áp dụng khi không có job đang quét vì API sẽ được tạo lại và kết nối worker có thể gián đoạn ngắn.

```bash
git -C "$HOME/ncs-oasm" pull --ff-only origin main

# Xem trước, không ghi file và không restart
python3 "$HOME/ncs-oasm/manage-runtime.py" timeout 60 --check

# Đặt 60 phút và áp dụng
python3 "$HOME/ncs-oasm/manage-runtime.py" timeout 60

# Xem file timeout trong container, giá trị đã lưu và trạng thái stack
python3 "$HOME/ncs-oasm/manage-runtime.py" status
```

Đổi sang 30 phút bằng `timeout 30`. Giới hạn hợp lệ là số nguyên từ 10 tới 1440 phút. Giới hạn dưới giữ budget job cao hơn deadline kết nối connector. Tăng timeout không giải quyết lỗi mạng, target unresponsive, OOM hoặc proxy auth và không bảo đảm quét phát hiện CVE.

Tiện ích tự nhận diện project, thư mục làm việc, env-file và tất cả file Compose từ nhãn của container `oasm-api`. Có thể dùng cả khi đã áp dụng overlay timeout thủ công trước đó. Nếu tên container khác, đặt tùy chọn trước subcommand:

```bash
python3 "$HOME/ncs-oasm/manage-runtime.py" --container my-oasm-api timeout 60
```

Không chạy tiện ích trên một bản repo/host khác không có các đường dẫn Compose gốc. Tài khoản vận hành cần đọc được repo/`.env` và có quyền Docker; không cần gửi secret vào câu lệnh.

## File cấu hình dễ sửa

Sau lần đầu, tiện ích in đường dẫn `settings.json`. Ví dụ project restore mặc định:

```text
~/.local/share/ncs-oasm/runtime/oasm-upstream-restore/settings.json
```

Nội dung:

```json
{
  "nuclei_timeout_minutes": 60
}
```

Có thể sửa số phút bằng trình soạn thảo rồi áp dụng lại:

```bash
python3 "$HOME/ncs-oasm/manage-runtime.py" apply
```

Thư mục này còn chứa manifest, overlay do tiện ích sinh ra và một bản `.previous` khi cập nhật. Không sửa trực tiếp file manifest sinh ra để quản lý timeout. Compose validation thất bại thì tiện ích khôi phục file cấu hình trước đó, không recreate API. Nếu bước khởi động/healthcheck thất bại, file mong muốn vẫn được giữ; kiểm tra API/dependency/worker trước khi chạy lại `apply`. Không coi một thông báo lỗi của tiện ích là xác nhận runtime đã rollback.

## Hiệu lực và vận hành

- Tiện ích chỉ tạo lại `core-api`, giữ nguyên volume, image và các overlay đã nhận diện. Không bật/dừng SIEM, Caddy hay job quét.
- API đọc registry lúc khởi động; sửa số phút trong file mà chưa `apply` chưa có hiệu lực. Giá trị `status` đọc từ file trong container, không kiểm tra bộ nhớ registry của tiến trình.
- Sau khi báo `Verified timeoutSeconds=3600`, kiểm tra API healthy và worker Online rồi tạo lượt quét mới trên scope nhỏ. Job đang chạy không được gia hạn bởi thao tác này; job đã được cấp phát trước đó có thể vẫn giữ budget cũ.
- Nếu sau này recreate API bằng lệnh Compose thủ công **bỏ overlay quản lý**, cấu hình có thể mất hiệu lực. Chạy lại `manage-runtime.py apply` để gắn lại overlay. Lệnh `docker restart oasm-api` giữ mount hiện có nhưng không nạp các thay đổi env-file.
- Không sửa file Compose upstream trong repo chỉ để đổi timeout. Không thêm `timeoutSeconds` vào JSON Nuclei workflow rồi coi đó là giới hạn của worker.
- Khi nâng release/image API, cần đánh giá lại manifest với release mới. Tiện ích giữ metadata từ manifest đang mount; nó không tự đồng bộ catalog mới hoặc chuyển đổi schema khi nâng version. Giữ bản sao cấu hình và thử nâng trên môi trường riêng trước.

## Kiểm thử tiện ích

Kiểm thử bằng Docker giả lập, không khởi động scanner:

```bash
python3 -B -m unittest discover -s tests -p test_manage_runtime.py -v
```

Các kiểm tra bao phủ bảo toàn manifest/overlay/env-file, giới hạn số phút, nhận diện đúng service, chế độ read-only và việc không restart API khi Compose validation lỗi. Nghiệm thu trên VM vẫn cần kiểm tra API healthy, worker Online và thời lượng job thực tế.

Tiện ích cũng từ chối nếu Compose đang chọn tag image API khác container hiện tại. Việc nâng release phải theo quy trình deployment riêng, không thực hiện ngầm khi đổi timeout.

## VM nhỏ: để job chờ ở hàng đợi thay vì hết slot

Stack upstream đang pin đặt worker concurrency bằng 10, còn pool mặc định chỉ cho một replica mỗi image. Một job Nuclei dài có thể giữ slot 60 phút trong khi các job khác đã được worker nhận về hết budget chờ slot 10 phút. Đây là hai loại timeout khác nhau; tăng timeout thực thi không tăng budget chờ slot.

Với một worker trên VM khoảng 8 GB RAM và mỗi Nuclei yêu cầu 4 GiB, khởi đầu bằng **một job được nhận tại một thời điểm**:

```bash
python3 "$HOME/ncs-oasm/manage-runtime.py" worker-jobs 1 --check

# Chỉ áp dụng sau khi lượt đang quét đã hoàn tất hoặc được Cancel
python3 "$HOME/ncs-oasm/manage-runtime.py" worker-jobs 1
```

Tiện ích chỉ recreate service `oasm-worker`, giữ API và file timeout Nuclei. Cần đúng một replica worker đang có trong project; nếu có nhiều replica, tiện ích từ chối để người vận hành đánh giá ngân sách trước. Lệnh này không tăng pool, không giảm RAM của connector, không chạy lại job failed tự động và không khắc phục container bị kẹt.

Giá trị được lưu trong `compose.worker.yaml` cùng thư mục runtime. Các lần dùng tiện ích đổi timeout/apply sau đó tự giữ overlay này. Nếu recreate worker bằng lệnh Compose ngoài tiện ích mà bỏ overlay, concurrency có thể trở về 10; chạy lại `worker-jobs 1` để áp dụng sau khi các lượt đang chạy đã kết thúc.

Khi đạt `Verified WORKER_MAX_CONCURRENCY=1`, kiểm tra Workers Online, rồi chạy lại các job lỗi chờ slot. Các job workflow khác cũng được xử lý tuần tự trên worker này, nên discovery có thể chờ lâu hơn. Đây là cấu hình khởi đầu cho VM nhỏ, không phải cam kết mọi job sẽ thành công: vẫn cần kiểm tra timeout thực thi, mạng, proxy và skipped templates.
