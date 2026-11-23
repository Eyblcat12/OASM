# Gửi log và sự kiện NCS OASM về SIEM

Hướng dẫn dành cho Docker Engine trên Linux và Docker Desktop trên Windows. Thu dữ liệu từ OASM một lần, chuẩn hóa thành sự kiện JSON, rồi chọn đầu ra phù hợp với SIEM đang dùng.

Nếu dùng Elastic, bắt đầu với [bộ cấu hình collector tự đăng nhập](SIEM-QUICKSTART.md). Bộ này tạo cấu hình cho cả log Docker và kết quả OASM trong một lần. Các phần bên dưới phục vụ tùy chỉnh đầu ra, Wazuh, QRadar hoặc cách thu bằng phiên có sẵn.

```text
OASM → collector → chuẩn hóa và lưu đệm → Elastic / Wazuh / QRadar / SIEM khác
```

## 1. Chọn đủ nguồn dữ liệu

| Nguồn | Nội dung | Cách đọc |
| --- | --- | --- |
| **Docker stdout và stderr** | Log giao diện, API, migration, PostgreSQL, Redis, RustFS và GeoIP. Nếu môi trường có worker, thu thêm log worker. | Collector đặt trên Docker host, lọc theo nhãn project Compose. Dùng Docker logs để lấy lại phần lịch sử Docker còn giữ. |
| **Audit Logs** | Thao tác quản trị theo workspace, người thực hiện, thời điểm, kết quả và đối tượng thay đổi. | API đọc audit, xuất CSV theo lô hoặc nhập JSONL từ audit archive khi có cấu hình lưu trữ. |
| **Findings và sự kiện OASM** | Phát hiện lỗ hổng, mức độ, tài sản và trạng thái xử lý. | Webhook cho sự kiện mới và API chỉ đọc để đối soát định kỳ. |
| **Kết quả discovery** | Hostname, IP, cổng, mã HTTP, công nghệ, target liên quan và URL lịch sử. | Collector đọc kết quả đã lưu qua API `assets` và `assets/url`. |
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

Đặt file cấu hình collector, thư mục nhận log và khóa bên ngoài repo. Ví dụ dùng `~/oasm-siem-collector` làm thư mục làm việc cho Vector. Thư mục `out` chứa các file NDJSON, mỗi dòng là một sự kiện JSON. Collector kết quả ở phần 3 cũng ghi vào thư mục này.

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

## 3. Đồng bộ Audit Logs và kết quả quét

### Chạy collector kết quả

[Compose](siem/compose.results.yaml) và [script collector](siem/collect-results.cjs) đọc dữ liệu đã lưu trong một workspace OASM. Collector chạy riêng trên Docker Engine hoặc Docker Desktop qua WSL, dùng image API sẵn có của bộ cài để chạy Node.js. Collector gọi API đọc, ghi NDJSON vào `out` rồi lưu checkpoint theo nguồn. Lượt đầu nhập dữ liệu API đang trả về. Các lượt sau ghi sự kiện mới và thay đổi đối với những trường được đồng bộ.

| Dataset | Dữ liệu và trường để tra cứu | Khoảng nghỉ giữa hai lượt đọc |
| --- | --- | --- |
| `oasm.audit` | Hành động, tác nhân, kết quả, tài nguyên liên quan và ID sự kiện. | 10 giây |
| `oasm.finding` | Findings đã lưu, gồm tên, mức độ, CVE nếu có, trạng thái và tài sản liên quan. | 10 giây |
| `oasm.discovery` | Dịch vụ và URL lịch sử. Lọc `event.action` bằng `discovery.service` hoặc `discovery.url`. | 30 giây cho dịch vụ và 5 phút cho URL |

Tần suất thực tế gồm khoảng nghỉ trên cộng thời gian đọc và ghi. Các luồng đọc độc lập. API phân trang tối đa 100 dòng mỗi request. Với workspace nhiều URL, theo dõi thời gian mỗi lượt và tải API trước khi tăng tần suất. Audit dùng thời gian tại nguồn, findings dùng thời điểm cập nhật và discovery dùng thời điểm collector ghi nhận.

Chạy từ thư mục repo NCS OASM với tài khoản shell thông thường. Trên Windows chạy trong WSL đã bật Docker Desktop integration. Nếu đã đặt tên project hoặc mạng riêng, đổi `OASM_DOCKER_NETWORK` theo kết quả `docker network ls`.

Mặc định collector dùng image `local/oasm-api:poc-2e12e49`. Với Open ASM upstream, đặt `OASM_RESULTS_IMAGE` thành đúng tag image API đã cài, rồi kiểm tra `OASM_DOCKER_NETWORK` và tên service API theo stack thực tế. [Hướng dẫn triển khai upstream](DEPLOYMENT.md)

```bash
export OASM_REPO_ROOT="$(pwd -P)"
export OASM_SIEM_DIR="$HOME/oasm-siem-collector"
export OASM_SOURCE_HOST="$(hostname)"
export OASM_COLLECTOR_UID="$(id -u)" OASM_COLLECTOR_GID="$(id -g)"
export OASM_DOCKER_NETWORK="oasm-ti-siem-test_default"
export OASM_BASE_URL="http://core-api:6277"

mkdir -p "$OASM_SIEM_DIR"
install -d -m 0700 "$OASM_SIEM_DIR/private" "$OASM_SIEM_DIR/state"
install -d -m 0750 "$OASM_SIEM_DIR/out"
(umask 077 && nano "$OASM_SIEM_DIR/private/oasm-session.json")
chmod 0600 "$OASM_SIEM_DIR/private/oasm-session.json"
```

Dùng một phiên đăng nhập OASM có `audit.read`, `asset.read` và `vulnerability.read` cho workspace cần đồng bộ. Với bản này, sau khi chọn đúng workspace trong OASM, có thể kiểm tra một yêu cầu đọc trong **DevTools → Network** để lấy giá trị hai header `X-Workspace-ID` và `Cookie`. Điền UUID vào `workspace` và giá trị header `Cookie` vào `cookie`, bỏ tiền tố tên header. Cookie là thông tin đăng nhập, lưu trong file riêng của máy triển khai. Nếu kết nối OASM từ ngoài mạng Docker nội bộ, dùng endpoint HTTPS tin cậy.

```json
{
  "workspace": "00000000-0000-0000-0000-000000000000",
  "cookie": "<giá trị header Cookie của phiên OASM>"
}
```

```bash
results="$OASM_REPO_ROOT/siem/compose.results.yaml"
docker compose -f "$results" config --quiet
docker compose -f "$results" up -d
docker compose -f "$results" logs --tail 30 results
find "$OASM_SIEM_DIR/out" -maxdepth 1 -type f -name '*.ndjson' -print
```

Khi phiên hết hạn, cập nhật file phiên và chạy `docker compose -f "$results" up -d --force-recreate`. Giữ thư mục `state` để tiếp tục từ checkpoint. Collector có thể ghi lại cùng `event.id` nếu dừng sau khi ghi file và trước khi lưu checkpoint. Khi cần đối soát hoặc nhập lại, dùng `event.id` để nhận diện bản ghi trùng. Đặt thời hạn lưu cho file NDJSON sau khi xác nhận SIEM đã nhận đủ. Mỗi workspace cần một project collector riêng cùng file xác thực, checkpoint và thư mục `out` riêng.

### Audit Logs

Dùng thông tin xác thực được instance OASM hỗ trợ với quyền `audit.read` trên workspace. Collector có thể đọc `GET /api/workspaces/{workspaceId}/audit`, giới hạn theo `from` và `to`, rồi tiếp tục bằng `nextCursor` tới hết trang. Giữ checkpoint qua lần chạy, đọc chồng nhẹ các cửa sổ thời gian và chống trùng theo `eventId`. Dùng `occurredAt` làm thời gian sự kiện ở SIEM.

Với lô thủ công, dùng `GET /api/workspaces/{workspaceId}/audit/export`. Bản upstream này giới hạn 10.000 dòng cho một lần xuất CSV, nên chia theo thời gian khi cần. Nếu nhập lại JSONL từ audit archive, dùng cùng quy tắc chống trùng. [Audit API upstream](https://github.com/oasm-platform/open-asm/blob/2e12e49e8ab5420746d9faf43fd48f57a923db58/core-api/src/modules/audit/audit-events.controller.ts).

### Findings và webhook

Trong **OASM → Integrations → Webhook**, điền URL của relay hoặc collector HTTP do bạn quản lý. Relay nhận JSON, ánh xạ `occurredAt`, ID sự kiện, workspace, tài sản, mức độ và CVE nếu có, rồi dùng thông tin xác thực phù hợp để ghi vào SIEM. Dùng nút **Test** để kiểm tra đường nhận.

Webhook của bản này gửi theo kiểu best effort và không tự gửi lại khi đầu nhận lỗi. Form Webhook nhận URL và các tùy chọn sự kiện. Relay có thể giữ khóa SIEM phía nhận. Để rà sự kiện bị thiếu, đọc danh sách findings ở `GET /api/vulnerabilities` với quyền `vulnerability.read`. API mặc định lấy findings đang mở, nên chọn trạng thái phù hợp nếu cần đối soát cả vòng đời. Giữ riêng ID finding và ID sự kiện cập nhật. [Webhook upstream](https://github.com/oasm-platform/open-asm/blob/2e12e49e8ab5420746d9faf43fd48f57a923db58/core-api/src/modules/integrations/schemas/webhook.schema.ts) · [Cơ chế gửi sự kiện](https://github.com/oasm-platform/open-asm/blob/2e12e49e8ab5420746d9faf43fd48f57a923db58/core-api/src/modules/event-bridge/AGENTS.md) · [Findings API](https://github.com/oasm-platform/open-asm/blob/2e12e49e8ab5420746d9faf43fd48f57a923db58/core-api/src/modules/vulnerabilities/vulnerabilities.controller.ts).

### Kết quả discovery

`GET /api/assets` trả dịch vụ gắn với target. Collector giữ hostname, IP, cổng, mã HTTP và công nghệ khi OASM có giá trị. `GET /api/assets/url` trả URL lịch sử đã lưu. Các URL HTTP(S) được giữ đến hết đường dẫn, bỏ thông tin đăng nhập, query string và fragment rồi gộp trùng. Vì vậy số URL sau chuẩn hóa có thể thấp hơn số dòng trên OASM. URL lịch sử có thể đã thay đổi hoặc hết hiệu lực. [Assets API](https://github.com/oasm-platform/open-asm/blob/2e12e49e8ab5420746d9faf43fd48f57a923db58/core-api/src/modules/assets/assets.controller.ts).

File NDJSON chỉ chứa các trường đã ánh xạ. Bằng chứng quét thô, header HTTP, body, ảnh chụp và chi tiết audit tự do được giữ ở OASM. Nếu bật thêm webhook, dùng `event.id` hoặc ID finding và trạng thái để đối soát với dữ liệu polling trước khi đưa vào quy tắc cảnh báo.

## 4. Chọn đầu ra SIEM

### Elastic

Trong **Kibana → Dev Tools**, tạo một API key dành cho Vector. Ví dụ giới hạn quyền ghi vào data stream của Docker, audit, findings và discovery. Nếu chỉ bật một số nguồn, bỏ các data stream không dùng khỏi `names`.

```text
POST /_security/api_key
{
  "name": "oasm-siem-writer",
  "expiration": "7d",
  "role_descriptors": {
    "oasm_writer": {
      "indices": [
        {
          "names": ["logs-oasm.docker-poc", "logs-oasm.audit-poc", "logs-oasm.finding-poc", "logs-oasm.discovery-poc"],
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
  oasm_elastic: &elastic_output
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

Để gửi cả kết quả từ phần 3, thêm các mục sau vào cùng `vector.yaml`. Gộp `sources`, `transforms` và `sinks` vào các khóa tương ứng đã có. Ba đầu ra dùng cùng cấu hình xác thực và lưu đệm của `oasm_elastic`.

```yaml
sources:
  oasm_results:
    type: file
    include:
      - /var/log/oasm/oasm-audit-*.ndjson
      - /var/log/oasm/oasm-finding-*.ndjson
      - /var/log/oasm/oasm-discovery-*.ndjson
    read_from: beginning
transforms:
  parse_oasm_results:
    type: remap
    inputs: [oasm_results]
    drop_on_error: true
    source: |
      . = parse_json!(string!(.message))
      .collector_event_id = string!(.event.id)
  oasm_by_dataset:
    type: route
    inputs: [parse_oasm_results]
    reroute_unmatched: false
    route:
      audit: '.event.dataset == "oasm.audit"'
      finding: '.event.dataset == "oasm.finding"'
      discovery: '.event.dataset == "oasm.discovery"'
sinks:
  oasm_elastic_audit:
    <<: *elastic_output
    inputs: [oasm_by_dataset.audit]
    id_key: collector_event_id
    data_stream: {type: logs, dataset: oasm.audit, namespace: poc, auto_routing: false}
  oasm_elastic_finding:
    <<: *elastic_output
    inputs: [oasm_by_dataset.finding]
    id_key: collector_event_id
    data_stream: {type: logs, dataset: oasm.finding, namespace: poc, auto_routing: false}
  oasm_elastic_discovery:
    <<: *elastic_output
    inputs: [oasm_by_dataset.discovery]
    id_key: collector_event_id
    data_stream: {type: logs, dataset: oasm.discovery, namespace: poc, auto_routing: false}
```

Giữ `oasm_json` đọc riêng đầu vào `normalize_oasm` để file kết quả được chuyển thẳng từ collector. Kiểm tra lại Vector bằng lệnh `validate` ở phần 2. Trong **Kibana → Discover**, tạo data view `logs-oasm.*-poc` hoặc từng data stream và chọn `@timestamp`. Dùng `event.dataset` để lọc từng nguồn và `event.action` để phân biệt dịch vụ với URL. Dùng tài khoản SIEM có quyền đọc để nghiệm thu. [Vector File Source](https://vector.dev/docs/reference/configuration/sources/file/) · [Tạo data view](https://www.elastic.co/docs/explore-analyze/find-and-organize/data-views).

### Wazuh

Trên máy có **Wazuh Agent**, dùng agent để đọc NDJSON từ thư mục `out` của collector. Thêm khối dưới đây vào `ossec.conf` và thay đường dẫn bằng đường dẫn tuyệt đối trên máy chạy agent. Ví dụ dùng `/home/operator/oasm-siem-collector/out` nếu đó là nơi bạn lưu cấu hình collector trên Linux.

```xml
<localfile>
  <location>/home/operator/oasm-siem-collector/out/oasm-*.ndjson</location>
  <log_format>json</log_format>
</localfile>
```

Trên Linux, sao lưu cấu hình agent, rồi khởi động lại dịch vụ `wazuh-agent` để áp dụng. Trên Windows, dùng đường dẫn đĩa cục bộ của agent. Kiểm tra agent đã kết nối manager trước khi nghiệm thu. [Cấu hình localfile](https://documentation.wazuh.com/current/user-manual/reference/ossec-conf/localfile.html) · [Theo dõi log file trên Linux và Windows](https://documentation.wazuh.com/current/user-manual/capabilities/log-data-collection/monitoring-log-files.html).

Glob `oasm-*.ndjson` bao gồm file Docker, audit, findings và discovery nếu cùng thư mục `out`. Trong Wazuh, lọc theo `event.dataset` trong payload đã giải mã. Đối chiếu các trường lồng nhau và rule bằng một finding đã lưu và một dịch vụ có cổng.

Để tìm **mọi log đã nhận**, kể cả log không khớp rule, bật `logall_json` theo chính sách lưu trữ của Wazuh Manager. Với Wazuh self-managed dùng Filebeat, bật thêm `archives.enabled` cho module Wazuh và dùng index pattern `wazuh-archives-*` với trường `timestamp`. Cấu hình archive áp dụng cho mọi nguồn của manager, nên xác định dung lượng và thời hạn lưu trước khi bật. `wazuh-alerts-*` phục vụ các sự kiện đã tạo cảnh báo. [Wazuh archives](https://documentation.wazuh.com/current/user-manual/manager/event-logging.html).

### IBM QRadar

Đưa NDJSON đã chuẩn hóa vào Syslog relay có bộ chuyển đổi LEEF. Relay giữ thời gian sự kiện, tên nguồn, dịch vụ và ID tương quan, rồi gửi tới địa chỉ Event Collector do QRadar cung cấp. Tạo **Log Source Type = Universal LEEF**, chọn **Protocol Configuration = Syslog**, đặt **Log Source Identifier** theo hostname hoặc IP mà QRadar dùng để nhận diện nguồn. Nếu triển khai qua TLS Syslog, cấu hình listener và tuyến Log Source theo phương thức triển khai QRadar thực tế. [Universal LEEF over Syslog](https://www.ibm.com/docs/en/qsip/7.5.0?topic=leef-syslog-protocol-log-source-parameters-universal) · [Định tuyến nhiều nguồn qua TLS Syslog](https://www.ibm.com/docs/en/dsm?topic=options-multiple-log-sources-over-tls-syslog).

Ví dụ thân bản tin LEEF để kiểm tra parser. Khi gửi, relay bổ sung Syslog header hợp lệ. `devTime` dùng epoch theo mili giây. Cập nhật thời gian khi gửi bản tin thử để dễ tìm trong Log Activity. Dùng mã sự kiện ổn định như `docker.log` cho mapping QID và giữ ID tương quan ở thuộc tính riêng. Khi chuyển log thật, xử lý xuống dòng và ký tự phân cách trong giá trị trước khi tạo LEEF. [Cú pháp LEEF](https://www.ibm.com/docs/en/dsm?topic=overview-leef-event-components) · [Thuộc tính LEEF](https://www.ibm.com/docs/en/dsm?topic=overview-predefined-leef-event-attributes).

```text
LEEF:2.0|NCS|OASM|1.0|docker.log|^|cat=oasm.docker^devTime=1767225600000^service=console^correlationId=oasm-siem-example^msg=OASM SIEM verification
```

Trong **Log Activity**, lọc theo Log Source vừa tạo và tìm ID tương quan trong payload. Kiểm tra Event Name, thứ tự thời gian và trường dịch vụ. Nếu bản tin đã đến dưới dạng raw hoặc Unknown, hoàn thiện mapping QID trong DSM và kiểm tra lại với một mẫu. [IBM QRadar DSM Configuration Guide](https://www.ibm.com/docs/SS42VS_DSM/pdf/b_dsm_guide.pdf).

Với kết quả quét, dùng `event.action` làm EventID của LEEF. Giữ `event.id` làm khóa đối soát và `event.dataset` làm nhóm sự kiện. Với findings, ánh xạ `oasm.finding.cve_id` và `vulnerability.severity` sang thuộc tính tùy chỉnh khi có giá trị. Với discovery, giữ hostname, cổng hoặc URL theo loại sự kiện. URL và chuỗi công nghệ cần được escape theo dấu phân cách LEEF của relay.

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
3. Đối soát một mục audit, một finding, một dịch vụ và một URL đã có. So ID hoặc khóa tìm kiếm, workspace và các trường đã ánh xạ giữa OASM, file NDJSON và SIEM.
4. Theo dõi số dòng đã nhận theo nhóm nguồn, lỗi xác thực, độ trễ, dung lượng lưu đệm và hạn khóa. Nếu nhận thiếu, kiểm tra trước ở nguồn, sau đó ở collector, cuối cùng ở bộ phân tích và khoảng thời gian trên SIEM.

Các đoạn cấu hình là mẫu cần áp dụng theo phiên bản và endpoint thật. [Log mẫu](fixtures/operational-log.json) và [finding mẫu](fixtures/finding.json) trong repo dùng dữ liệu tổng hợp để kiểm tra ánh xạ.
