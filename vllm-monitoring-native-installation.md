# vLLM 모니터링 - Native 설치 가이드

## 아키텍처 개요

```
┌─────────────────────────────────────────┐
│  Server A (vLLM 서버)                    │
│  - vLLM serve (Inbound only)            │
│  - Promtail (로그 수집 → Loki)          │
│  - Loki (로그 저장)                      │
│  - /metrics endpoint (Prometheus용)     │
└────────────────────────────────────────┘
                 ↑ Pull
┌────────────────────────────────────────┐
│  Server B (모니터링 서버)                │
│  - Prometheus (Server A에서 pull)       │
│  - Grafana (시각화)                     │
└────────────────────────────────────────┘
```

---

## Server A: vLLM 서버 설정

### 1. vLLM 설치 및 실행

#### vLLM 설치
```bash
# Python 가상환경 생성 (권장)
python3 -m venv /opt/vllm-env
source /opt/vllm-env/bin/activate

# vLLM 설치
pip install vllm

# 또는 특정 버전
pip install vllm==0.3.0
```

#### vLLM 실행 스크립트 작성

`/opt/vllm/start-vllm.sh`:
```bash
#!/bin/bash

# vLLM 환경 활성화
source /opt/vllm-env/bin/activate

# 로그 디렉토리 생성
mkdir -p /var/log/vllm

# vLLM 서버 실행 (로그를 파일과 stdout 모두 출력)
vllm serve /home/models/model-vlm-8b \
  --max-model-len 16384 \
  --async-scheduling \
  --mm-encoder-tp-mode data \
  --served-model-name model-vlm-8b \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 1 \
  --trust-remote-code \
  --limit-mm-per-prompt image=3 \
  --limit-mm-per-prompt video=0 \
  --max-num-batched-tokens 6384 \
  --max-num-seqs 3 \
  2>&1 | tee -a /var/log/vllm/vllm.log
```

실행 권한 부여:
```bash
chmod +x /opt/vllm/start-vllm.sh
```

#### Systemd 서비스 등록

`/etc/systemd/system/vllm.service`:
```ini
[Unit]
Description=vLLM Serving Service
After=network.target

[Service]
Type=simple
User=vllm
Group=vllm
WorkingDirectory=/opt/vllm
Environment="PATH=/opt/vllm-env/bin:/usr/local/bin:/usr/bin:/bin"
Environment="CUDA_VISIBLE_DEVICES=0"

# 로그를 파일로 저장
StandardOutput=append:/var/log/vllm/vllm.log
StandardError=append:/var/log/vllm/vllm-error.log

ExecStart=/opt/vllm-env/bin/vllm serve /home/models/model-vlm-8b \
  --max-model-len 16384 \
  --async-scheduling \
  --mm-encoder-tp-mode data \
  --served-model-name model-vlm-8b \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 1 \
  --trust-remote-code \
  --limit-mm-per-prompt image=3 \
  --limit-mm-per-prompt video=0 \
  --max-num-batched-tokens 6384 \
  --max-num-seqs 3

Restart=always
RestartSec=10

# 리소스 제한 (선택사항)
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
```

사용자 및 디렉토리 설정:
```bash
# vLLM 사용자 생성 (이미 있다면 생략)
sudo useradd -r -s /bin/bash -d /opt/vllm vllm

# 디렉토리 권한 설정
sudo mkdir -p /var/log/vllm
sudo chown -R vllm:vllm /var/log/vllm
sudo chown -R vllm:vllm /opt/vllm
sudo chown -R vllm:vllm /opt/vllm-env

# 모델 디렉토리 읽기 권한
sudo chmod -R 755 /home/models
```

서비스 시작:
```bash
# Systemd 리로드
sudo systemctl daemon-reload

# vLLM 서비스 시작
sudo systemctl start vllm

# 부팅 시 자동 시작 설정
sudo systemctl enable vllm

# 상태 확인
sudo systemctl status vllm

# 로그 확인
sudo journalctl -u vllm -f

# 또는 파일로 확인
tail -f /var/log/vllm/vllm.log
```

확인:
```bash
# vLLM API 확인
curl http://localhost:8000/v1/models

# Prometheus metrics 확인
curl http://localhost:8000/metrics
```

---

### 2. Loki 설치 및 설정

#### Loki 다운로드 및 설치

```bash
# Loki 바이너리 다운로드 (최신 버전 확인: https://github.com/grafana/loki/releases)
cd /tmp
wget https://github.com/grafana/loki/releases/download/v2.9.3/loki-linux-amd64.zip
unzip loki-linux-amd64.zip

# 설치
sudo mv loki-linux-amd64 /usr/local/bin/loki
sudo chmod +x /usr/local/bin/loki

# 버전 확인
loki --version
```

#### Loki 설정 파일

`/etc/loki/loki-config.yml`:
```yaml
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: info

common:
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory: /var/lib/loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h

storage_config:
  boltdb_shipper:
    active_index_directory: /var/lib/loki/boltdb-shipper-active
    cache_location: /var/lib/loki/boltdb-shipper-cache
    cache_ttl: 24h
    shared_store: filesystem
  filesystem:
    directory: /var/lib/loki/chunks

compactor:
  working_directory: /var/lib/loki/boltdb-shipper-compactor
  shared_store: filesystem
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 2h
  retention_delete_worker_count: 150

limits_config:
  # 로그 수집 제한
  reject_old_samples: true
  reject_old_samples_max_age: 168h  # 1주일
  ingestion_rate_mb: 10
  ingestion_burst_size_mb: 20
  max_query_series: 100000
  max_query_lookback: 720h  # 30일

chunk_store_config:
  max_look_back_period: 720h  # 30일

table_manager:
  retention_deletes_enabled: true
  retention_period: 720h  # 30일

ruler:
  storage:
    type: local
    local:
      directory: /var/lib/loki/rules
  rule_path: /var/lib/loki/rules-temp
  alertmanager_url: http://localhost:9093
  ring:
    kvstore:
      store: inmemory
  enable_api: true
```

#### Loki 디렉토리 및 권한 설정

```bash
# Loki 사용자 생성
sudo useradd -r -s /bin/false loki

# 디렉토리 생성
sudo mkdir -p /etc/loki
sudo mkdir -p /var/lib/loki/{chunks,rules,boltdb-shipper-active,boltdb-shipper-cache,boltdb-shipper-compactor,rules-temp}

# 권한 설정
sudo chown -R loki:loki /var/lib/loki
sudo chown -R loki:loki /etc/loki
```

#### Loki Systemd 서비스

`/etc/systemd/system/loki.service`:
```ini
[Unit]
Description=Loki Log Aggregation System
After=network.target

[Service]
Type=simple
User=loki
Group=loki
ExecStart=/usr/local/bin/loki -config.file=/etc/loki/loki-config.yml
Restart=always
RestartSec=5

# 리소스 제한
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

서비스 시작:
```bash
# 설정 파일 이동
sudo mv loki-config.yml /etc/loki/

# Systemd 리로드
sudo systemctl daemon-reload

# Loki 시작
sudo systemctl start loki
sudo systemctl enable loki

# 상태 확인
sudo systemctl status loki

# 로그 확인
sudo journalctl -u loki -f

# Loki API 확인
curl http://localhost:3100/ready
curl http://localhost:3100/metrics
```

---

### 3. Promtail 설치 및 설정

#### Promtail 다운로드 및 설치

```bash
# Promtail 바이너리 다운로드
cd /tmp
wget https://github.com/grafana/loki/releases/download/v2.9.3/promtail-linux-amd64.zip
unzip promtail-linux-amd64.zip

# 설치
sudo mv promtail-linux-amd64 /usr/local/bin/promtail
sudo chmod +x /usr/local/bin/promtail

# 버전 확인
promtail --version
```

#### Promtail 설정 파일

`/etc/promtail/promtail-config.yml`:
```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0
  log_level: info

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://localhost:3100/loki/api/v1/push
    batchwait: 1s
    batchsize: 102400
    timeout: 10s

scrape_configs:
  # vLLM 로그 수집
  - job_name: vllm
    static_configs:
      - targets:
          - localhost
        labels:
          job: vllm
          __path__: /var/log/vllm/*.log
    
    pipeline_stages:
      # 타임스탬프 파싱 (vLLM 로그 형식에 맞춰 조정 필요)
      - regex:
          expression: '^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})'
      - timestamp:
          source: timestamp
          format: '2006-01-02 15:04:05'
      
      # vLLM 요청 완료 로그 파싱
      # 실제 vLLM 로그 형식에 맞춰 수정 필요
      - regex:
          expression: '.*Finished request (?P<request_id>\S+)'
      
      # 성능 메트릭 추출 (vLLM 로그에 있는 경우)
      - regex:
          expression: '.*time_to_first_token[:\s]+(?P<ttft>[0-9.]+)'
      - regex:
          expression: '.*generation_time[:\s]+(?P<gen_time>[0-9.]+)'
      - regex:
          expression: '.*total_time[:\s]+(?P<total_time>[0-9.]+)'
      - regex:
          expression: '.*prompt_tokens[:\s]+(?P<prompt_tokens>[0-9]+)'
      - regex:
          expression: '.*completion_tokens[:\s]+(?P<completion_tokens>[0-9]+)'
      
      # 라벨 추가
      - labels:
          request_id:
      
      # Prometheus 메트릭 생성
      - metrics:
          vllm_ttft_seconds:
            type: Gauge
            description: "Time to first token per request"
            source: ttft
            config:
              action: set
          
          vllm_generation_time_seconds:
            type: Gauge
            description: "Generation time per request"
            source: gen_time
            config:
              action: set
          
          vllm_total_time_seconds:
            type: Gauge
            description: "Total request time"
            source: total_time
            config:
              action: set
          
          vllm_prompt_tokens_count:
            type: Gauge
            description: "Prompt tokens per request"
            source: prompt_tokens
            config:
              action: set
          
          vllm_completion_tokens_count:
            type: Gauge
            description: "Completion tokens per request"
            source: completion_tokens
            config:
              action: set
          
          vllm_requests_total:
            type: Counter
            description: "Total number of requests"
            config:
              action: inc

  # Systemd journal에서 vLLM 로그 수집 (대안)
  - job_name: vllm-journal
    journal:
      max_age: 12h
      labels:
        job: vllm-systemd
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: 'unit'
      - source_labels: ['__journal__systemd_unit']
        regex: 'vllm.service'
        action: keep
    pipeline_stages:
      # 위와 동일한 파싱 로직 적용
      - regex:
          expression: '.*Finished request (?P<request_id>\S+)'
      - labels:
          request_id:
```

#### Promtail 디렉토리 및 권한 설정

```bash
# Promtail 사용자 생성
sudo useradd -r -s /bin/false promtail

# 디렉토리 생성
sudo mkdir -p /etc/promtail
sudo mkdir -p /var/lib/promtail

# vLLM 로그 디렉토리 읽기 권한
sudo usermod -a -G vllm promtail
sudo chmod g+r /var/log/vllm/*.log

# 권한 설정
sudo chown -R promtail:promtail /var/lib/promtail
sudo chown -R promtail:promtail /etc/promtail
```

#### Promtail Systemd 서비스

`/etc/systemd/system/promtail.service`:
```ini
[Unit]
Description=Promtail Log Collector
After=network.target loki.service
Wants=loki.service

[Service]
Type=simple
User=promtail
Group=promtail
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/promtail-config.yml
Restart=always
RestartSec=5

# systemd journal 읽기 권한
SupplementaryGroups=systemd-journal

[Install]
WantedBy=multi-user.target
```

서비스 시작:
```bash
# 설정 파일 이동
sudo mv promtail-config.yml /etc/promtail/

# Systemd 리로드
sudo systemctl daemon-reload

# Promtail 시작
sudo systemctl start promtail
sudo systemctl enable promtail

# 상태 확인
sudo systemctl status promtail

# 로그 확인
sudo journalctl -u promtail -f

# Promtail metrics 확인
curl http://localhost:9080/metrics
```

#### vLLM 로그 형식 확인 및 Regex 조정

vLLM의 실제 로그 출력을 확인:
```bash
tail -f /var/log/vllm/vllm.log
```

로그 예시가 다음과 같다면:
```
INFO 2024-02-24 10:30:45,123 metrics.py:45 Avg prompt throughput: 150.5 tokens/s
INFO 2024-02-24 10:30:46,456 engine.py:234 Finished request abc123, prompt_tokens=50, completion_tokens=100
```

Promtail config의 regex를 실제 로그 형식에 맞춰 수정:
```yaml
- regex:
    expression: '.*Finished request (?P<request_id>\w+), prompt_tokens=(?P<prompt_tokens>\d+), completion_tokens=(?P<completion_tokens>\d+)'
```

---

### 4. 방화벽 설정 (Server A)

외부(Server B)에서 접근해야 하는 포트 오픈:

```bash
# Loki (Grafana에서 pull)
sudo firewall-cmd --permanent --add-port=3100/tcp

# Prometheus metrics (Prometheus에서 pull)
sudo firewall-cmd --permanent --add-port=8000/tcp

# Promtail metrics (Prometheus에서 pull, 선택사항)
sudo firewall-cmd --permanent --add-port=9080/tcp

# 방화벽 리로드
sudo firewall-cmd --reload

# 또는 ufw 사용 시
sudo ufw allow 3100/tcp
sudo ufw allow 8000/tcp
sudo ufw allow 9080/tcp
```

---

### 5. 로그 로테이션 설정

`/etc/logrotate.d/vllm`:
```
/var/log/vllm/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0644 vllm vllm
    sharedscripts
    postrotate
        systemctl reload vllm > /dev/null 2>&1 || true
    endscript
}
```

적용:
```bash
# 로테이션 테스트
sudo logrotate -d /etc/logrotate.d/vllm

# 강제 실행
sudo logrotate -f /etc/logrotate.d/vllm
```

---

## Server B: 모니터링 서버 설정

### 1. Prometheus 설치

```bash
# Prometheus 다운로드
cd /tmp
wget https://github.com/prometheus/prometheus/releases/download/v2.48.0/prometheus-2.48.0.linux-amd64.tar.gz
tar xvfz prometheus-2.48.0.linux-amd64.tar.gz

# 설치
sudo mv prometheus-2.48.0.linux-amd64 /opt/prometheus
sudo ln -s /opt/prometheus/prometheus /usr/local/bin/

# 사용자 생성
sudo useradd -r -s /bin/false prometheus

# 디렉토리 생성
sudo mkdir -p /etc/prometheus
sudo mkdir -p /var/lib/prometheus

# 권한 설정
sudo chown -R prometheus:prometheus /opt/prometheus
sudo chown -R prometheus:prometheus /var/lib/prometheus
sudo chown -R prometheus:prometheus /etc/prometheus
```

### 2. Prometheus 설정

`/etc/prometheus/prometheus.yml`:
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: 'vllm-production'

# Alertmanager 설정 (선택사항)
# alerting:
#   alertmanagers:
#     - static_configs:
#         - targets: ['localhost:9093']

scrape_configs:
  # vLLM metrics (Server A에서 pull)
  - job_name: 'vllm'
    static_configs:
      - targets: ['SERVER_A_IP:8000']
        labels:
          instance: 'vllm-server-1'
          env: 'production'
    metrics_path: '/metrics'
    scrape_interval: 10s
    scrape_timeout: 10s

  # Promtail metrics (Server A에서 pull, 선택사항)
  - job_name: 'promtail'
    static_configs:
      - targets: ['SERVER_A_IP:9080']
        labels:
          instance: 'vllm-server-1'

  # Loki metrics (Server A에서 pull)
  - job_name: 'loki'
    static_configs:
      - targets: ['SERVER_A_IP:3100']
        labels:
          instance: 'vllm-server-1'

  # Prometheus 자체 metrics
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
```

**`SERVER_A_IP`를 실제 vLLM 서버 IP로 변경하세요.**

### 3. Prometheus Systemd 서비스

`/etc/systemd/system/prometheus.service`:
```ini
[Unit]
Description=Prometheus Monitoring System
After=network.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=30d \
  --web.console.templates=/opt/prometheus/consoles \
  --web.console.libraries=/opt/prometheus/console_libraries \
  --web.listen-address=0.0.0.0:9090

Restart=always
RestartSec=5

LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

서비스 시작:
```bash
# 설정 확인
/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --web.enable-lifecycle --dry-run

# Systemd 시작
sudo systemctl daemon-reload
sudo systemctl start prometheus
sudo systemctl enable prometheus

# 상태 확인
sudo systemctl status prometheus

# Prometheus UI 접속
# http://SERVER_B_IP:9090
```

### 4. Grafana 설치

```bash
# Grafana 리포지토리 추가
sudo apt-get install -y software-properties-common
sudo add-apt-repository "deb https://packages.grafana.com/oss/deb stable main"
wget -q -O - https://packages.grafana.com/gpg.key | sudo apt-key add -

# 설치
sudo apt-get update
sudo apt-get install grafana

# 또는 RPM 기반 시스템
sudo yum install -y https://dl.grafana.com/oss/release/grafana-10.2.3-1.x86_64.rpm
```

또는 바이너리로 설치:
```bash
cd /tmp
wget https://dl.grafana.com/oss/release/grafana-10.2.3.linux-amd64.tar.gz
tar -zxvf grafana-10.2.3.linux-amd64.tar.gz
sudo mv grafana-10.2.3 /opt/grafana
```

### 5. Grafana 설정

`/etc/grafana/grafana.ini` (주요 설정만):
```ini
[server]
protocol = http
http_addr = 0.0.0.0
http_port = 3000
domain = localhost
root_url = http://localhost:3000

[database]
type = sqlite3
path = grafana.db

[security]
admin_user = admin
admin_password = admin_change_this

[users]
allow_sign_up = false

[auth.anonymous]
enabled = false

[log]
mode = console file
level = info

[paths]
data = /var/lib/grafana
logs = /var/log/grafana
plugins = /var/lib/grafana/plugins
provisioning = /etc/grafana/provisioning
```

### 6. Grafana Data Source Provisioning

`/etc/grafana/provisioning/datasources/datasources.yml`:
```yaml
apiVersion: 1

datasources:
  # Prometheus (로컬)
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: true
    jsonData:
      timeInterval: "15s"

  # Loki (Server A에서 pull)
  - name: Loki
    type: loki
    access: proxy
    url: http://SERVER_A_IP:3100
    editable: true
    jsonData:
      maxLines: 1000
      derivedFields:
        - datasourceUid: prometheus-uid
          matcherRegex: "request_id=(\\S+)"
          name: request_id
          url: "$${__value.raw}"
```

**`SERVER_A_IP`를 실제 vLLM 서버 IP로 변경하세요.**

### 7. Grafana 서비스 시작

```bash
# Systemd 시작
sudo systemctl daemon-reload
sudo systemctl start grafana-server
sudo systemctl enable grafana-server

# 상태 확인
sudo systemctl status grafana-server

# 로그 확인
sudo journalctl -u grafana-server -f

# Grafana 접속
# http://SERVER_B_IP:3000
# 기본 계정: admin / admin_change_this
```

### 8. 방화벽 설정 (Server B)

```bash
# Grafana
sudo firewall-cmd --permanent --add-port=3000/tcp

# Prometheus (외부 접근 허용 시)
sudo firewall-cmd --permanent --add-port=9090/tcp

# 방화벽 리로드
sudo firewall-cmd --reload
```

---

## 통합 테스트 및 검증

### 1. Server A 검증

```bash
# vLLM 서비스 확인
sudo systemctl status vllm
curl http://localhost:8000/v1/models

# vLLM metrics 확인
curl http://localhost:8000/metrics | grep vllm

# Loki 확인
sudo systemctl status loki
curl http://localhost:3100/ready
curl http://localhost:3100/metrics

# Promtail 확인
sudo systemctl status promtail
curl http://localhost:9080/metrics

# Loki에 로그가 들어오는지 확인
curl -G -s "http://localhost:3100/loki/api/v1/query" --data-urlencode 'query={job="vllm"}' | jq
```

### 2. Server B 검증

```bash
# Prometheus 타겟 확인
curl http://localhost:9090/api/v1/targets | jq

# vLLM metrics가 수집되는지 확인
curl -G http://localhost:9090/api/v1/query --data-urlencode 'query=vllm:num_requests_running' | jq

# Grafana 확인
curl http://localhost:3000/api/health
```

### 3. Grafana에서 데이터 소스 테스트

Grafana UI에서:
1. Configuration → Data Sources
2. Prometheus 선택 → "Save & Test" → "Data source is working" 확인
3. Loki 선택 → "Save & Test" → "Data source is working" 확인

### 4. 테스트 쿼리

#### Prometheus 쿼리 (Grafana Explore):
```promql
# vLLM이 실행 중인지 확인
up{job="vllm"}

# TTFT 메트릭
rate(vllm:time_to_first_token_seconds_sum[5m]) / rate(vllm:time_to_first_token_seconds_count[5m])

# 요청 수
rate(vllm:request_success_total[5m])
```

#### Loki 쿼리 (Grafana Explore):
```logql
# vLLM 로그 확인
{job="vllm"}

# 완료된 요청만 필터링
{job="vllm"} |~ "Finished request"

# 특정 request_id 검색
{job="vllm"} | json | request_id="abc123"
```

---

## 문제 해결

### vLLM 로그가 Promtail에 수집되지 않는 경우

```bash
# Promtail 로그 확인
sudo journalctl -u promtail -f

# 파일 권한 확인
ls -la /var/log/vllm/
sudo -u promtail cat /var/log/vllm/vllm.log

# Promtail position 파일 확인
sudo cat /var/lib/promtail/positions.yaml
```

### Loki에 데이터가 없는 경우

```bash
# Loki 로그 확인
sudo journalctl -u loki -f

# Loki API로 직접 확인
curl -G -s "http://localhost:3100/loki/api/v1/label" | jq
curl -G -s "http://localhost:3100/loki/api/v1/label/job/values" | jq
```

### Prometheus가 vLLM metrics를 수집하지 못하는 경우

```bash
# Server B에서 Server A로 연결 테스트
curl http://SERVER_A_IP:8000/metrics

# Prometheus 타겟 상태 확인
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health, lastError: .lastError}'

# 방화벽 확인
sudo firewall-cmd --list-all
```

### vLLM 로그 형식이 예상과 다른 경우

1. 실제 로그 확인:
```bash
tail -100 /var/log/vllm/vllm.log
```

2. 로그 샘플을 제공하고 regex 패턴 조정
3. Promtail config 수정 후 재시작:
```bash
sudo systemctl restart promtail
```

---

## 성능 최적화

### Loki 데이터 압축 및 보관 정책

`/etc/loki/loki-config.yml`에서 조정:
```yaml
limits_config:
  retention_period: 720h  # 30일 보관

compactor:
  retention_enabled: true
  retention_delete_delay: 2h
```

### Prometheus 데이터 보관 정책

`/etc/systemd/system/prometheus.service`에서 조정:
```ini
ExecStart=/usr/local/bin/prometheus \
  ...
  --storage.tsdb.retention.time=30d \
  --storage.tsdb.retention.size=50GB
```

### Promtail 배치 설정

`/etc/promtail/promtail-config.yml`에서 조정:
```yaml
clients:
  - url: http://localhost:3100/loki/api/v1/push
    batchwait: 1s      # 배치 대기 시간
    batchsize: 1048576 # 1MB (조정 가능)
    timeout: 10s
```

---

## 모니터링 스택 관리 스크립트

### 전체 재시작 스크립트

`/opt/scripts/restart-monitoring.sh`:
```bash
#!/bin/bash

echo "=== Server A: vLLM Monitoring Stack Restart ==="

# Promtail 재시작
echo "Restarting Promtail..."
sudo systemctl restart promtail
sleep 2
sudo systemctl status promtail --no-pager

# Loki 재시작
echo "Restarting Loki..."
sudo systemctl restart loki
sleep 2
sudo systemctl status loki --no-pager

# vLLM은 운영 중이므로 스킵 (필요시 주석 해제)
# echo "Restarting vLLM..."
# sudo systemctl restart vllm

echo "=== All services restarted ==="
```

### 상태 확인 스크립트

`/opt/scripts/check-monitoring.sh`:
```bash
#!/bin/bash

echo "=== vLLM Monitoring Stack Status ==="

echo -e "\n[vLLM Service]"
sudo systemctl status vllm --no-pager | grep "Active:"

echo -e "\n[Loki Service]"
sudo systemctl status loki --no-pager | grep "Active:"

echo -e "\n[Promtail Service]"
sudo systemctl status promtail --no-pager | grep "Active:"

echo -e "\n[vLLM API]"
curl -s http://localhost:8000/health || echo "FAILED"

echo -e "\n[Loki API]"
curl -s http://localhost:3100/ready || echo "FAILED"

echo -e "\n[Promtail Metrics]"
curl -s http://localhost:9080/metrics | grep "promtail_build_info" || echo "FAILED"

echo -e "\n=== Disk Usage ==="
df -h /var/lib/loki /var/log/vllm
```

실행 권한:
```bash
chmod +x /opt/scripts/*.sh
```

---

## 정리

### Server A (vLLM 서버) 실행 순서

```bash
# 1. vLLM 시작
sudo systemctl start vllm

# 2. Loki 시작
sudo systemctl start loki

# 3. Promtail 시작 (Loki가 먼저 실행되어야 함)
sudo systemctl start promtail

# 4. 전체 상태 확인
/opt/scripts/check-monitoring.sh
```

### Server B (모니터링 서버) 실행 순서

```bash
# 1. Prometheus 시작
sudo systemctl start prometheus

# 2. Grafana 시작
sudo systemctl start grafana-server

# 3. 브라우저에서 접속
# http://SERVER_B_IP:3000
```

### 주요 엔드포인트

**Server A:**
- vLLM API: `http://SERVER_A_IP:8000`
- vLLM Metrics: `http://SERVER_A_IP:8000/metrics`
- Loki: `http://SERVER_A_IP:3100`
- Promtail Metrics: `http://SERVER_A_IP:9080/metrics`

**Server B:**
- Prometheus: `http://SERVER_B_IP:9090`
- Grafana: `http://SERVER_B_IP:3000`

---

이제 vLLM, Promtail, Loki가 Server A에서 네이티브로 실행되며, Server B의 Prometheus와 Grafana가 pull 방식으로 데이터를 수집하는 환경이 구축되었습니다!
