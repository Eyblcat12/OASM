# Phương án triển khai production

Phạm vi ban đầu là quản lý 128 website, discovery theo lịch, quét lỗ hổng trên phạm vi được phép và chuyển kết quả về SIEM. Tài liệu này chốt kiến trúc bàn giao sau PoC; [DEPLOYMENT.md](DEPLOYMENT.md) chứa lệnh cài đặt Linux/Windows, worker, restore và collector.

## 1. Kiến trúc được chọn

| Thành phần | Phương án |
| --- | --- |
| Hạ tầng | VM Ubuntu 24.04 LTS x86-64 trên ESXi, Docker Engine và Compose. |
| Tài nguyên ban đầu | 8 vCPU, 32 GB RAM, SSD 500 GB cho OASM và worker; SIEM cùng backup ở hạ tầng riêng. Đây là mức khởi đầu đề xuất, cần đo tải thực tế. |
| Ứng dụng | Compose upstream `56dc2c657743200363b65cf2168ae4f91d0a953c`, API/console/worker `v0.13.0`. Ghi lại digest các image thực dùng, gồm PostgreSQL/Redis/RustFS/GeoIP; không tự nâng `latest` trong lần bàn giao. |
| Dịch vụ | Console, core API, PostgreSQL, Redis, RustFS, GeoIP, migration một lần và worker gốc thường trực. Migration Exited (0) là bình thường. |
| Worker | Một replica khi khởi đầu. Giới hạn số job và pool theo ngân sách tài nguyên; đo tải trước khi tăng song song. |
| Dashboard | Caddy cung cấp HTTPS trước console. Dùng domain quản trị và chứng chỉ được máy người dùng tin cậy. |
| Đầu ra quét | Giữ proxy nội bộ worker, đi qua firewall/gateway với IP public cố định do System cấp. Chưa nối Squid ngoài vào worker. |
| SIEM | Vector/collector gửi trực tiếp tới endpoint SIEM qua HTTPS và API key riêng; không dựng thêm reverse proxy riêng cho đường SIEM trong phạm vi này. |
| Dữ liệu | Chuyển dữ liệu mới nhất từ instance đang vận hành, cùng khóa mã hóa tương ứng, qua kênh riêng. Không đẩy snapshot hoặc `.env` lên GitHub. |

Luồng truy cập:

```text
Người quản trị -> Caddy HTTPS -> Console -> Core API
Core API -> PostgreSQL / Redis / RustFS / GeoIP
Core API -> Worker -> Connector -> Proxy nội bộ worker -> Gateway/NAT -> Website
Collector kết quả + log Docker -> Vector -> SIEM HTTPS
```

Một VM là triển khai một nút, chưa có HA. Nếu cần SLA khi host/VM hỏng, chốt thêm phương án phục hồi hoặc phân tách dịch vụ; không coi restart policy là HA.

## 2. Thông tin System cần cấp

| Đầu vào | Giá trị phải ghi khi bàn giao |
| --- | --- |
| VM | IP nội bộ ổn định, CPU/RAM/SSD thực cấp, DNS, NTP, đường quản trị và người phụ trách. |
| Dashboard | Domain, đường truy cập nội bộ/VPN, chứng chỉ và cách gia hạn. |
| Đầu ra | IP NAT/public cố định, rule firewall, DNS và đích/cổng được phép cho các công cụ sử dụng. |
| SIEM | Endpoint HTTPS, CA tin cậy, API key quyền ghi, thời hạn key, namespace/stream và người quản trị đầu nhận. |
| Vận hành | Phạm vi và lịch quét, giới hạn tải, đầu mối dừng, thời gian lưu dữ liệu, lịch backup, RPO/RTO. |

Không chuyển tiếp tùy tiện mọi cổng ra Internet. Chỉ công khai cổng dashboard theo chính sách mạng. Giữ database, Redis, RustFS, callback worker và Docker socket trong phạm vi nội bộ cần thiết. Thu hồi/đổi khóa PoC trước bàn giao theo kế hoạch có bảo toàn dữ liệu; giữ đúng khóa giải mã dữ liệu hiện có.

## 3. Reverse proxy dashboard

Dùng Caddy làm TLS termination. Backend là `console:80` trong mạng Docker OASM. Caddy và console trao đổi trong cùng host/network; TLS của trình duyệt kết thúc tại Caddy. Nếu backend chuyển sang host khác, đánh giá và cấu hình TLS trên đoạn đó.

Domain production phải được xác định trước khi sửa origin. Nếu domain và mạng đáp ứng ACME, Caddy có thể quản lý chứng chỉ tự động; môi trường chỉ nội bộ dùng chứng chỉ CA tổ chức hoặc cơ chế cấp phát được System chọn. Không đưa nguyên cấu hình lab `tls internal` vào production khi chưa phân phối CA tin cậy.

Sau khi có URL HTTPS chính thức:

1. Đặt `BASE_URL=https://<domain-dashboard>` trong `.env` của API.
2. Recreate API khi không có job đang chạy; kiểm tra worker kết nối lại.
3. Cập nhật `origin` trong file tài khoản collector, giữ API nội bộ `http://core-api:6277` nếu cùng mạng Docker hiện tại.
4. Kiểm tra login/logout, assets/findings, file lưu trữ và sự kiện cập nhật. Xác nhận log IP người dùng và cấu hình proxy tin cậy đúng từng hop, không dùng wildcard tin mọi proxy.

Lab đã nhận HTTP 200 qua Caddy tại `https://192.168.44.159:8443` và người dùng đã mở được dashboard từ Windows. Lab dùng IP DHCP, CA nội bộ và thêm `default_sni` cho client truy cập IP không gửi SNI. Đây là bằng chứng đường proxy/HTTPS hoạt động, chưa xác nhận đầy đủ cấu hình đăng nhập/origin production.

## 4. Dữ liệu và chuyển đổi

Chọn instance nguồn đang vận hành thực tế, không lấy các container PoC cũ đã dừng làm nguồn nếu dữ liệu mới đang ở upstream. Snapshot ngày 21/11 chỉ là mốc thử trước đây. Cần xuất bản mới sau khi chốt thay đổi và dừng lịch/job đang hoạt động trong cửa sổ chuyển đổi.

Bộ bàn giao dữ liệu cần PostgreSQL, object storage, audit archive và khóa mã hóa phù hợp, kèm checksum, số đếm và nhận diện workspace. Các secret môi trường đích phải được cấu hình riêng. Không sao chép mù quáng Redis queue hoặc token worker cũ làm phát sinh job ngoài lịch. Đối chiếu từng thành phần với định dạng importer trước khi nhập; không giả định script export của bộ PoC tự chọn đúng stack upstream hiện tại.

Khôi phục vào đích trống theo hướng dẫn migration, đối soát target/asset/service/finding/URL và thử đọc file cũ. Kích hoạt worker đích rồi nghiệm thu trên scope nhỏ được duyệt. Chỉ chuyển lịch giám sát sang đích khi kiểm tra đạt. Giữ nguồn cũ dừng job để rollback; không cho hai môi trường cùng chạy toàn bộ lịch.

## 5. SIEM và bảo mật đường truyền

Lab đã xác nhận đủ bốn dataset từ VM: Docker, audit, finding và discovery. Bộ collector đọc theo polling và Vector gửi liên tục; chưa có phép đo SLA độ trễ production hoặc đối soát đầy đủ mọi bản ghi lịch sử.

Production dùng endpoint SIEM HTTPS có xác minh CA/hostname. Không giữ endpoint lab HTTP `192.168.44.1:9200` hoặc phụ thuộc Windows portproxy. Giới hạn firewall theo nguồn, dùng API key chỉ ghi đúng stream và có lịch thay key. Không cần proxy riêng nếu đầu nhận đã hỗ trợ HTTPS.

Giữ checkpoint, NDJSON và buffer qua restart, theo dõi dung lượng và thời gian mất kết nối. Khi SIEM ngừng, dữ liệu chỉ được giữ trong giới hạn đĩa/buffer. Khi collector dừng, không cam kết thu bù đầy đủ log Docker trong thời gian nghỉ. Các bản ghi audit/discovery trùng ID sau migrate có thể giữ host cũ; đối soát ID nguồn trên toàn stream.

Alert phải được tạo và nghiệm thu trên SIEM, không tự có sau khi ingestion thành công. Finding lịch sử có timestamp cũ có thể không khớp cửa sổ rule theo thời gian hiện tại. Chốt chống trùng và cách xử lý cập nhật trạng thái trước khi nối thông báo SOC.

## 6. Lịch chạy và tiêu chí nghiệm thu

Chia 128 website thành nhóm, rải lịch discovery và vulnerability scan. Bắt đầu một job Nuclei đồng thời, thử hai sau khi đã đo tải và điều chỉnh đúng pool/budget. Quét CVE mới theo template liên quan công nghệ, quét rộng theo lịch riêng. Tính tổng lưu lượng theo backend/IP dùng chung, không chỉ theo số domain.

Các điểm PoC còn cần xử lý/đối soát trước bàn giao:

- Lượt quét đã có trường hợp dừng khoảng 10 phút, trả kết quả một phần. Xác minh timeout runtime/manifest trên đích; chưa coi quét rộng hoàn tất.
- Có request bị proxy nội bộ từ chối `reason=auth`; cần xác định connector/request bị ảnh hưởng. Không kết luận WAF chặn hoặc bỏ xác thực proxy để che lỗi.
- Chưa có benchmark đủ 128 website trong một cửa sổ quét đã chốt; tăng tài nguyên không tự tăng độ bao phủ hoặc chất lượng phát hiện CVE.
- Chưa nghiệm thu HTTPS tới SIEM production, rule/notification thực tế, backup mới và restore trên hạ tầng production.
- Chưa xác nhận nối tiếp proxy ngoài cho worker. Squid chưa được triển khai; thư mục lab trống không phải một thành phần cần migrate.

Biên bản nghiệm thu ghi: phiên bản/digest, checksum và số đếm dữ liệu mới nhất, worker Online, job thực thi đúng scope, không ngắt sớm, kết quả lưu được, đủ luồng SIEM cần dùng, đối chiếu một finding và một sự kiện mới, alert thử nếu thuộc phạm vi, khôi phục backup và người nhận bàn giao. Tách bằng chứng hạ tầng chạy được với bằng chứng scanner phát hiện đúng lỗ hổng.

## 7. Trình tự triển khai

1. System cấp VM, domain/cert, mạng đầu ra và endpoint SIEM.
2. Cài Docker Engine và triển khai đúng upstream/version theo DEPLOYMENT.md.
3. Chuyển dữ liệu mới nhất, cấu hình secret và khôi phục vào đích trống.
4. Mở console, worker và Caddy; xác nhận HTTPS cùng origin.
5. Bật collector tới SIEM HTTPS; kiểm tra dữ liệu mới, dữ liệu cũ và rule thử.
6. Chạy scope nhỏ được phép, xử lý lỗi còn tồn tại và ghi số đo CPU/RAM/I/O, thời gian job, lỗi/skipped và độ trễ SIEM.
7. Mở rộng theo nhóm tới 128 website, bật lịch, xác nhận backup/rollback và bàn giao vận hành.

Có thể chốt kiến trúc và bắt đầu triển khai có kiểm soát theo phương án này. Chưa kết luận PoC hiện tại đã chứng minh độ bao phủ mọi CVE, quét không bị chặn hoặc production sẵn sàng mà không cần nghiệm thu trên đích.
