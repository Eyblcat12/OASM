# Gửi log và sự kiện NCS OASM về SIEM

Hướng dẫn dành cho Docker Engine trên Linux và Docker Desktop trên Windows. Thu dữ liệu từ OASM một lần, chuẩn hóa thành sự kiện JSON, rồi chọn đầu ra phù hợp với SIEM đang dùng.

```text
OASM → collector → chuẩn hóa và lưu đệm → Elastic / Wazuh / QRadar / SIEM khác
```

## 1. Chọn đủ nguồn dữ liệu

| Nguồn | Nội dung | Cách đọc |
| --- | --- | --- |
| **Docker stdout và stderr** | Log giao diện, API, migration, PostgreSQL, Redis, RustFS và GeoIP. Nếu môi trường có worker, thu thêm log worker. | Collector đặt trên Docker host, lọc theo nhãn project Compose. Dùng Docker logs để lấy lại phần lịch sử Docker còn giữ. |
| **Audit Logs** | Thao tác quản trị theo workspace, người thực hiện, thời điểm, kết quả và đối tượng thay đổi. | API đọc audit, xuất CSV theo lô hoặc nhập JSONL từ audit archive khi có cấu hình lưu trữ. |
| **Findings và sự kiện OASM** | Phát hiện lỗ hổng, mức độ, tài sản và trạng thái xử lý. | Webhook cho sự kiện mới và API chỉ đọc để đối soát định kỳ. |
| **Log WAF, reverse proxy hoặc web server đích** | Lượt truy cập và cảnh báo liên quan đến website được giám sát. | Thu trực tiếp tại WAF hoặc web server bằng tích hợp tương ứng của SIEM. |

Phần thu Docker lấy các dòng container đã phát. Log của container dùng một lần có thể nằm trong chi tiết job hoặc log worker. Kiểm tra cách triển khai thực tế trước khi coi log worker là đủ. Nếu đã có yêu cầu lưu trữ, chuyển log trước khi Docker xoay file hoặc xóa container. [Lệnh Docker logs](https://docs.docker.com/reference/cli/docker/container/logs/) · [Docker log rotation](https://docs.docker.com/engine/logging/drivers/json-file/).

## 2. Xác định Docker host và project

- **Linux** chạy các lệnh trên máy Docker Engine đang chạy OASM. [Cài Docker Engine](DOCKER-ENGINE.md).
- **Windows** mở Docker Desktop và chạy từ distro WSL đã bật Docker integration. Nếu Docker trong WSL trỏ nhầm sang Podman, dùng `unset DOCKER_HOST CONTAINER_HOST` rồi `export DOCKER_CONTEXT=default`. Kiểm tra `docker info` hiển thị Docker Desktop trước khi tiếp tục. [Docker Desktop với WSL](https://docs.docker.com/desktop/features/wsl/).

```bash
docker info --format '{{.OperatingSystem}} / {{.ServerVersion}}'
docker compose ls -a
docker ps -a --filter 'label=com.docker.compose.project=oasm-ti-siem-test' \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Label "com.docker.compose.service"}}'
```

`oasm-ti-siem-test` là tên mặc định của bộ cài này. Thay bằng tên đang hiển thị nếu bạn đã đặt project name riêng. Ghi lại danh sách dịch vụ. Migration chạy theo lượt và có thể đã dừng khi bạn kiểm tra.

### Cài collector Docker độc lập

Đặt file cấu hình collector, thư mục nhận log và khóa trong một thư mục riêng bên ngoài repo. Ví dụ dùng Vector và lưu một bản log chung dạng NDJSON, mỗi dòng là một sự kiện JSON. Giữ các file này cùng thư mục.

**`compose.collector.yaml`**

```yaml
name: oasm-siem-collector
services:
  vector:
    image: timberio/vector:0.62.0-debian
    command: ["--config", "/etc/vector/vector.yaml"]
    restart: unless-stopped
    environment:
      OASM_SOURCE_HOST: ${OASM_SOURCE_HOST:?Set the name of the Docker host}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./vector.yaml:/etc/vector/vector.yaml:ro
      - ./out:/var/log/oasm
      - vector-data:/var/lib/vector
volumes:
  vector-data:
```

**`vector.yaml`**

```yaml
data_dir: /var/lib/vector
sources:
  oasm_docker:
    type: docker_logs
    include_labels:
      - com.docker.compose.project=oasm-ti-siem-test
transforms:
  normalize_oasm:
    type: remap
    inputs: [oasm_docker]
    source: |
      service_name = to_string(.label."com.docker.compose.service") ?? string!(.container_name)
      . = {
        "timestamp": .timestamp,
        "message": .message,
        "event": {"dataset": "oasm.docker"},
        "host": {"name": get_env_var!("OASM_SOURCE_HOST")},
        "service": {"name": service_name},
        "container": {"id": .container_id, "name": .container_name},
        "log": {"iostream": .stream}
      }
sinks:
  oasm_json:
    type: file
    inputs: [normalize_oasm]
    path: /var/log/oasm/oasm-%Y-%m-%d.ndjson
    encoding:
      codec: json
    framing:
      method: newline_delimited
```

Sửa nhãn project trước khi chạy. Cấp quyền đọc thư mục `out` cho agent hoặc relay được chọn. Nếu agent chạy trên Windows host, đặt thư mục ở ổ đĩa Windows cục bộ và dùng đường dẫn Windows trong agent. Vector giao tiếp với socket quản trị Docker, kể cả khi socket được bind chỉ đọc. Giới hạn quyền quản lý collector cho người vận hành host. [Vector trên Docker](https://vector.dev/docs/setup/installation/platforms/docker/) · [Bảo vệ socket Docker](https://docs.docker.com/engine/security/protect-access/).

```bash
export OASM_SOURCE_HOST="$(hostname)"
mkdir -p out
docker compose -f compose.collector.yaml config --quiet &&
docker compose -f compose.collector.yaml \
  run --rm --no-deps vector validate --no-environment /etc/vector/vector.yaml &&
docker compose -f compose.collector.yaml up -d
```

Nếu dùng NDJSON làm bộ đệm lâu dài, đặt thời hạn lưu và theo dõi dung lượng. Với dữ liệu Docker còn lưu trước khi bật collector, lấy theo mốc thời gian và nhập như một lô riêng. Đánh dấu nguồn của lô và tránh nhập trùng khoảng thời gian đang được collector đọc.

## 3. Bổ sung Audit Logs và findings

### Audit Logs

Dùng thông tin xác thực được instance OASM hỗ trợ với quyền `audit.read` trên workspace. Collector có thể đọc `GET /api/workspaces/{workspaceId}/audit`, giới hạn theo `from` và `to`, rồi tiếp tục bằng `nextCursor` tới hết trang. Giữ checkpoint qua lần chạy, đọc chồng nhẹ các cửa sổ thời gian và chống trùng theo `eventId`. Dùng `occurredAt` làm thời gian sự kiện ở SIEM.

Với lô thủ công, dùng `GET /api/workspaces/{workspaceId}/audit/export`. Bản upstream này giới hạn 10.000 dòng cho một lần xuất CSV, nên chia theo thời gian khi cần. Nếu nhập lại JSONL từ audit archive, dùng cùng quy tắc chống trùng. [Audit API upstream](https://github.com/oasm-platform/open-asm/blob/2e12e49e8ab5420746d9faf43fd48f57a923db58/core-api/src/modules/audit/audit-events.controller.ts).

### Findings và webhook

Trong **OASM → Integrations → Webhook**, điền URL của relay hoặc collector HTTP do bạn quản lý. Relay nhận JSON, ánh xạ `occurredAt`, ID sự kiện, workspace, tài sản, mức độ và CVE nếu có, rồi dùng thông tin xác thực phù hợp để ghi vào SIEM. Dùng nút **Test** để kiểm tra đường nhận.

Webhook của bản này gửi theo kiểu best effort và không tự gửi lại khi đầu nhận lỗi. Form Webhook nhận URL và các tùy chọn sự kiện. Relay có thể giữ khóa SIEM phía nhận. Để rà sự kiện bị thiếu, đọc danh sách findings ở `GET /api/vulnerabilities` với quyền `vulnerability.read`. API mặc định lấy findings đang mở, nên chọn trạng thái phù hợp nếu cần đối soát cả vòng đời. Giữ riêng ID finding và ID sự kiện cập nhật. [Webhook upstream](https://github.com/oasm-platform/open-asm/blob/2e12e49e8ab5420746d9faf43fd48f57a923db58/core-api/src/modules/integrations/schemas/webhook.schema.ts) · [Cơ chế gửi sự kiện](https://github.com/oasm-platform/open-asm/blob/2e12e49e8ab5420746d9faf43fd48f57a923db58/core-api/src/modules/event-bridge/AGENTS.md) · [Findings API](https://github.com/oasm-platform/open-asm/blob/2e12e49e8ab5420746d9faf43fd48f57a923db58/core-api/src/modules/vulnerabilities/vulnerabilities.controller.ts).

Có thể tách dữ liệu thành ba nhóm `oasm.docker`, `oasm.audit` và `oasm.finding`. Giữ ID, thời gian UTC, workspace khi có, tên host và thông điệp đã loại thông tin xác thực. Với log Docker, giữ thêm tên service và `stdout` hoặc `stderr` để tra cứu.

## 4. Chọn đầu ra SIEM

### Elastic

Trong **Kibana → Dev Tools**, tạo một API key dành cho collector. Với Docker logs, ví dụ này giới hạn quyền ghi vào `logs-oasm.docker-poc`.

```text
POST /_security/api_key
{
  "name": "oasm-docker-writer",
  "expiration": "7d",
  "role_descriptors": {
    "oasm_writer": {
      "indices": [
        {
          "names": ["logs-oasm.docker-poc"],
          "privileges": ["auto_configure", "create_doc"]
        }
      ]
    }
  }
}
```

Giữ trường `encoded` trong file secret của Vector theo cấu trúc `{"authorization":"ApiKey <encoded>"}`. Nếu lưu tại `./private/elastic-oasm.json` trong thư mục collector bên ngoài repo, thêm `./private/elastic-oasm.json:/run/secrets/elastic-oasm.json:ro` vào `services.vector.volumes`. Thêm `secret` ở cấp gốc của `vector.yaml` và thêm đầu ra `oasm_elastic` dưới mục `sinks` đang có. Có thể giữ `oasm_json` để lưu NDJSON cục bộ.

```yaml
secret:
  elastic:
    type: file
    path: /run/secrets/elastic-oasm.json
sinks:
  oasm_elastic:
    type: elasticsearch
    inputs: [normalize_oasm]
    endpoints: ["https://elastic.example.org:9200"]
    api_version: v8
    mode: data_stream
    data_stream:
      type: logs
      dataset: oasm.docker
      namespace: poc
      auto_routing: false
    request:
      headers:
        Authorization: "SECRET[elastic.authorization]"
    healthcheck:
      enabled: false
    buffer:
      type: disk
      max_size: 536870912
      when_full: block
```

Điền endpoint **Elasticsearch** và CA của môi trường nếu dùng CA nội bộ. Sau khi sửa file, kiểm tra bằng lệnh ở phần 2 và tạo lại container collector. Từ container, `127.0.0.1` mặc định là chính container. Nếu chạy Elastic cùng Docker Desktop, kết nối collector vào mạng Docker của Elastic và dùng tên service của Elasticsearch. Nếu chạy native Linux và dùng SSH tunnel ở loopback của host cho PoC, cần cấu hình mạng host cho collector. [Vector Elasticsearch sink](https://vector.dev/docs/reference/configuration/sinks/elasticsearch/) · [Vector secret file](https://vector.dev/docs/reference/configuration/secrets/#file-backend) · [Docker host networking](https://docs.docker.com/engine/network/drivers/host/).

Trong **Kibana → Discover**, tạo data view `logs-oasm.docker-poc`, chọn trường `@timestamp`. Vector chuyển thời gian Docker sang trường này khi ghi data stream. Kiểm tra tài liệu thực sự tìm được vì khóa ghi trong ví dụ không có quyền đọc hoặc kiểm tra trạng thái cluster. [Tạo data view](https://www.elastic.co/docs/explore-analyze/find-and-organize/data-views).

### Wazuh

Trên máy có **Wazuh Agent**, dùng agent để đọc NDJSON từ thư mục `out` của collector. Thêm khối dưới đây vào `ossec.conf` và thay đường dẫn bằng đường dẫn tuyệt đối trên máy chạy agent. Ví dụ dùng `/home/operator/oasm-siem-collector/out` nếu đó là nơi bạn lưu cấu hình collector trên Linux.

```xml
<localfile>
  <location>/home/operator/oasm-siem-collector/out/oasm-*.ndjson</location>
  <log_format>json</log_format>
</localfile>
```

Trên Linux, sao lưu cấu hình agent, rồi khởi động lại dịch vụ `wazuh-agent` để áp dụng. Trên Windows, dùng đường dẫn đĩa cục bộ của agent. Kiểm tra agent đã kết nối manager trước khi nghiệm thu. [Cấu hình localfile](https://documentation.wazuh.com/current/user-manual/reference/ossec-conf/localfile.html) · [Theo dõi log file trên Linux và Windows](https://documentation.wazuh.com/current/user-manual/capabilities/log-data-collection/monitoring-log-files.html).

Để tìm **mọi log đã nhận**, kể cả log không khớp rule, bật `logall_json` theo chính sách lưu trữ của Wazuh Manager. Với Wazuh self-managed dùng Filebeat, bật thêm `archives.enabled` cho module Wazuh và dùng index pattern `wazuh-archives-*` với trường `timestamp`. Cấu hình archive áp dụng cho mọi nguồn của manager, nên xác định dung lượng và thời hạn lưu trước khi bật. `wazuh-alerts-*` phục vụ các sự kiện đã tạo cảnh báo. [Wazuh archives](https://documentation.wazuh.com/current/user-manual/manager/event-logging.html).

### IBM QRadar

Đưa NDJSON đã chuẩn hóa vào Syslog relay có bộ chuyển đổi LEEF. Relay giữ thời gian sự kiện, tên nguồn, dịch vụ và ID tương quan, rồi gửi tới địa chỉ Event Collector do QRadar cung cấp. Tạo **Log Source Type = Universal LEEF**, chọn **Protocol Configuration = Syslog**, đặt **Log Source Identifier** theo hostname hoặc IP mà QRadar dùng để nhận diện nguồn. Nếu triển khai qua TLS Syslog, cấu hình listener và tuyến Log Source theo phương thức triển khai QRadar thực tế. [Universal LEEF over Syslog](https://www.ibm.com/docs/en/qsip/7.5.0?topic=leef-syslog-protocol-log-source-parameters-universal) · [Định tuyến nhiều nguồn qua TLS Syslog](https://www.ibm.com/docs/en/dsm?topic=options-multiple-log-sources-over-tls-syslog).

Ví dụ thân bản tin LEEF để kiểm tra parser. Khi gửi, relay bổ sung Syslog header hợp lệ. `devTime` dùng epoch theo mili giây. Cập nhật thời gian khi gửi bản tin thử để dễ tìm trong Log Activity. Dùng mã sự kiện ổn định như `docker.log` cho mapping QID và giữ ID tương quan ở thuộc tính riêng. Khi chuyển log thật, xử lý xuống dòng và ký tự phân cách trong giá trị trước khi tạo LEEF. [Cú pháp LEEF](https://www.ibm.com/docs/en/dsm?topic=overview-leef-event-components) · [Thuộc tính LEEF](https://www.ibm.com/docs/en/dsm?topic=overview-predefined-leef-event-attributes).

```text
LEEF:2.0|NCS|OASM|1.0|docker.log|^|cat=oasm.docker^devTime=1767225600000^service=console^correlationId=oasm-siem-example^msg=OASM SIEM verification
```

Trong **Log Activity**, lọc theo Log Source vừa tạo và tìm ID tương quan trong payload. Kiểm tra Event Name, thứ tự thời gian và trường dịch vụ. Nếu bản tin đã đến dưới dạng raw hoặc Unknown, hoàn thiện mapping QID trong DSM và kiểm tra lại với một mẫu. [IBM QRadar DSM Configuration Guide](https://www.ibm.com/docs/SS42VS_DSM/pdf/b_dsm_guide.pdf).

### SIEM khác

Nếu đích có API ingest, dùng collector hoặc relay để gửi JSON qua HTTPS với khóa ghi giới hạn. Nếu đích nhận Syslog, chuyển từ JSON sang định dạng và kiểu đóng khung mà đầu nhận yêu cầu. Giữ cùng ID tương quan khi đổi định dạng để có thể đối soát.

## 5. Kiểm thử và đối soát

Trên máy OASM, tạo một lượt mở console có mã nhận diện. Đây là request tới console đang chạy trên chính máy.

```bash
probe="oasm-siem-$(date -u +%Y%m%dT%H%M%SZ)"
curl -fsS "http://127.0.0.1:6276/?siem_probe=$probe" >/dev/null
printf '%s\n' "$probe"
bash compose.sh logs --since 2m --no-color console | grep -F "$probe"
```

Chạy lệnh trên từ repo NCS OASM. Với bản Docker cũ, có thể thay dòng cuối bằng `docker logs --since 2m oasm-console 2>&1 | grep -F "$probe"`.

1. Xác nhận mã có trong log Docker và đầu ra collector.
2. Tìm cùng mã trong **Kibana Discover**, **Wazuh archives** hoặc **QRadar Log Activity**. Kiểm tra đúng thời gian UTC, host, service và nội dung.
3. Đối soát thêm một mục audit và một finding đã có nếu hai luồng đó được cấu hình. So ID và thời gian ở nguồn với bản ghi SIEM.
4. Theo dõi số dòng đã nhận theo nhóm nguồn, lỗi xác thực, độ trễ, dung lượng lưu đệm và hạn khóa. Nếu nhận thiếu, kiểm tra trước ở nguồn, sau đó ở collector, cuối cùng ở bộ phân tích và khoảng thời gian trên SIEM.

Các đoạn cấu hình là mẫu cần áp dụng theo phiên bản và endpoint thật. [Log mẫu](fixtures/operational-log.json) và [finding mẫu](fixtures/finding.json) trong repo dùng dữ liệu tổng hợp để kiểm tra ánh xạ.
