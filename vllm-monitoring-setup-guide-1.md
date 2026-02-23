# vLLM 모니터링 시스템 구축 가이드

## 목차
1. [Grafana Proxy 설정 문제 해결](#grafana-proxy-설정-문제-해결)
2. [vLLM 메트릭 시각화](#vllm-메트릭-시각화)
3. [Grafana Dashboard Variable 설정](#grafana-dashboard-variable-설정)
4. [개별 API 호출 추적](#개별-api-호출-추적)
5. [OpenTelemetry vs Prometheus](#opentelemetry-vs-prometheus)
6. [최종 솔루션: Prometheus + Loki](#최종-솔루션-prometheus--loki)

---

## Grafana Proxy 설정 문제 해결

### 문제 상황
Grafana에서 Prometheus Data Source 설정 시 다음 에러 발생:
```
Post http://ip:port/api/v1/query proxyconnect tcp dial tcp:lookup http: no such host
```

### 원인
- Grafana가 사내 프록시 서버를 통해 연결 시도
- 내부 네트워크 주소에도 프록시를 사용하려고 해서 실패

### 해결 방법 (Docker Compose 환경)

`docker-compose.yml`에 환경 변수 추가:

```yaml
version: '3'
services:
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      # 프록시 우회 설정
      - NO_PROXY=localhost,127.0.0.1,prometheus,your-prometheus-ip
      - no_proxy=localhost,127.0.0.1,prometheus,your-prometheus-ip
    
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
```

**주요 포인트:**
- 같은 Docker 네트워크 내: URL을 `http://prometheus:9090`로 설정
- NO_PROXY에 내부 네트워크 대역 추가: `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16`

**적용:**
```bash
docker-compose down
docker-compose up -d
```

---

## vLLM 메트릭 시각화

### Prometheus 설정

`prometheus.yml`:
```yaml
scrape_configs:
  - job_name: 'vllm'
    scrape_interval: 15s
    static_configs:
      - targets: ['your-vllm-endpoint:port']
```

### 주요 메트릭 쿼리

#### Time to First Token (TTFT) - P95
```promql
histogram_quantile(0.95, rate(vllm:time_to_first_token_seconds_bucket[5m]))
```

#### TTFT - 평균
```promql
rate(vllm:time_to_first_token_seconds_sum[5m]) / rate(vllm:time_to_first_token_seconds_count[5m])
```

#### Prefill Tokens/s
```promql
rate(vllm:prompt_tokens_total[5m])
```

#### Generation Tokens/s
```promql
rate(vllm:generation_tokens_total[5m])
```

#### Throughput (요청/초)
```promql
rate(vllm:request_success_total[5m])
```

#### GPU Cache Usage
```promql
vllm:gpu_cache_usage_perc
```

#### Running Requests
```promql
vllm:num_requests_running
```

### Grafana 패널 설정 예시

**TTFT 패널:**
- Visualization: Time series
- Unit: seconds (s)
- Query: `histogram_quantile(0.95, rate(vllm:time_to_first_token_seconds_bucket[5m]))`

**Tokens/s 패널 (여러 메트릭):**
- Query A: `rate(vllm:prompt_tokens_total[5m])`
- Query B: `rate(vllm:generation_tokens_total[5m])`
- Visualization: Time series
- Unit: tokens/sec

---

## Grafana Dashboard Variable 설정

### 문제
한 패널에 너무 많은 모델들이 겹쳐 보임

### 해결: Variable 생성

#### Step 1: Variable 추가
Dashboard 설정 (⚙️) → Variables → Add variable

#### Step 2: Variable 설정
```
Name: model_name
Type: Query
Label: Model Name
Data source: Prometheus

Query:
label_values(vllm:time_to_first_token_seconds_count, model_name)

Multi-value: ✓
Include All option: ✓
```

#### Step 3: 패널 쿼리 수정

**TTFT (P95) - 모델 필터링:**
```promql
histogram_quantile(0.95, 
  rate(vllm:time_to_first_token_seconds_bucket{model_name=~"$model_name"}[5m])
)
```

**Prefill Tokens/s:**
```promql
rate(vllm:prompt_tokens_total{model_name=~"$model_name"}[5m])
```

**Generation Tokens/s:**
```promql
rate(vllm:generation_tokens_total{model_name=~"$model_name"}[5m])
```

#### Legend 설정
```
Legend: {{model_name}} - {{instance}}
```

#### 모델별 구분 쿼리
```promql
# TTFT P95 - 모델별로 구분
histogram_quantile(0.95, 
  sum by (model_name, le) (
    rate(vllm:time_to_first_token_seconds_bucket{model_name=~"$model_name"}[5m])
  )
)
```

---

## 개별 API 호출 추적

### vLLM Metrics의 한계

vLLM의 Prometheus 메트릭은:
- **Histogram 형태**: 시간대별 분포만 제공 (P50, P95 등)
- **Counter 형태**: 누적 합계만 제공
- **개별 요청 추적 불가**: 각 API 호출의 상세 타임라인 없음

### 해결 방법

#### 방법 1: vLLM 로그 파싱 (가장 정확)

vLLM은 각 요청의 상세 로그 출력:

```bash
vllm serve your-model --log-level INFO
```

로그 예시:
```
INFO: Finished request req_123, 
Time to first token: 0.15s, 
Prefill time: 0.12s, 
Decode time: 2.3s, 
Total time: 2.45s
```

→ Loki + Promtail로 수집하여 Grafana에서 시각화

#### 방법 2: Reverse Proxy 추가

```python
from fastapi import FastAPI, Request
from prometheus_client import Histogram, make_asgi_app
import httpx
import time

app = FastAPI()

request_latency = Histogram(
    'vllm_request_latency_detailed',
    'Detailed request latency',
    ['model', 'endpoint']
)

@app.post("/v1/completions")
async def completions_proxy(request: Request):
    body = await request.json()
    start = time.time()
    
    async with httpx.AsyncClient() as client:
        response = await client.post(
            "http://vllm:8000/v1/completions",
            json=body,
            timeout=300.0
        )
    
    latency = time.time() - start
    request_latency.labels(
        model=body.get('model', 'unknown'),
        endpoint='/v1/completions'
    ).observe(latency)
    
    return response.json()

app.mount("/metrics", make_asgi_app())
```

#### 방법 3: OpenTelemetry 사용

```bash
# vLLM 0.3.0 이상
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4317"
vllm serve your-model
```

---

## OpenTelemetry vs Prometheus

### 데이터 유형 비교

| 항목 | Prometheus | OpenTelemetry |
|------|-----------|---------------|
| **Metrics** | ✅ 핵심 기능 | ✅ 지원 |
| **Logs** | ❌ (Loki 필요) | ✅ 지원 |
| **Traces** | ❌ | ✅ 핵심 기능 |
| **집계/쿼리** | ✅ PromQL (강력) | ⚠️ 백엔드 의존 |

### OpenTelemetry의 장점

**1. 통합된 관찰성**
- Metrics + Logs + Traces를 하나의 시스템으로

**2. 상세한 요청 추적**
```
Request ID: abc123
├─ HTTP Request [200ms]
│  ├─ Prefill [50ms]
│  │  ├─ Token encoding [10ms]
│  │  └─ Model forward [40ms]
│  └─ Generation [150ms]
│     ├─ Token 1 [15ms]
│     ├─ Token 2 [14ms]
│     └─ Token 3 [15ms]
```

**3. 분산 시스템 추적**
```
Client → API Gateway → vLLM → Database
  └─────────── 하나의 Trace ─────────┘
```

### Prometheus의 장점

**1. 메트릭에 최적화**
- 시계열 데이터에 강력
- PromQL이 매우 강력하고 유연
- 집계와 알람에 탁월

**2. 간단한 설정**
- 가볍고 빠름
- 설정이 간단

**3. 리소스 효율**
- 장기 보관에 유리

### 실무 권장: 함께 사용

```
vLLM → OpenTelemetry Collector → Tempo (traces)
                                → Prometheus (metrics)
                                → Loki (logs)
                                     ↓
                                  Grafana
```

### Outbound 차단 환경의 제약

vLLM이 Outbound 연결 불가한 경우:
- OpenTelemetry는 push 방식이므로 사용 불가
- Prometheus는 pull 방식이므로 사용 가능
- 로그는 파일 기반이므로 수집 가능

**→ Prometheus + Loki 조합이 최적**

---

## 최종 솔루션: Prometheus + Loki

### 전체 구조

```
vLLM (logs + /metrics)
  ↓ 파일        ↓ HTTP pull
Promtail ←→ Prometheus
  ↓               ↓
Loki          (메트릭)
  ↓               ↓
    Grafana
```

### Docker Compose 설정

```yaml
version: '3.8'

services:
  vllm:
    image: vllm/vllm-openai:latest
    container_name: vllm
    command: >
      --model /models/model-vlm-8b
      --max-model-len 16384
      --async-scheduling
      --mm-encoder-tp-mode data
      --served-model-name model-vlm-8b
      --host 0.0.0.0
      --port 8000
      --tensor-parallel-size 1
      --trust-remote-code
      --limit-mm-per-prompt image=3
      --limit-mm-per-prompt video=0
      --max-num-batched-tokens 6384
      --max-num-seqs 3
    ports:
      - "8000:8000"
    volumes:
      - /home/models:/models:ro
      - vllm-logs:/tmp/vllm-logs
    environment:
      - VLLM_LOGGING_LEVEL=INFO
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"
        labels: "service=vllm"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
    depends_on:
      - vllm
    restart: unless-stopped

  promtail:
    image: grafana/promtail:latest
    container_name: promtail
    volumes:
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - ./promtail-config.yml:/etc/promtail/config.yml
      - vllm-logs:/var/log/vllm:ro
    command: -config.file=/etc/promtail/config.yml
    depends_on:
      - loki
    restart: unless-stopped

  loki:
    image: grafana/loki:latest
    container_name: loki
    ports:
      - "3100:3100"
    volumes:
      - loki-data:/loki
      - ./loki-config.yml:/etc/loki/config.yml
    command: -config.file=/etc/loki/config.yml
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
    environment:
      - GF_AUTH_ANONYMOUS_ENABLED=true
      - GF_AUTH_ANONYMOUS_ORG_ROLE=Admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
    depends_on:
      - prometheus
      - loki
    restart: unless-stopped

volumes:
  vllm-logs:
  prometheus-data:
  loki-data:
  grafana-data:
```

### Prometheus 설정

`prometheus.yml`:
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  # vLLM metrics scraping
  - job_name: 'vllm'
    static_configs:
      - targets: ['vllm:8000']
    metrics_path: '/metrics'
    scrape_interval: 10s

  # Promtail metrics (로그에서 추출한 메트릭)
  - job_name: 'promtail'
    static_configs:
      - targets: ['promtail:9080']
```

### Loki 설정

`loki-config.yml`:
```yaml
auth_enabled: false

server:
  http_listen_port: 3100

ingester:
  lifecycler:
    address: 127.0.0.1
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
  chunk_idle_period: 5m
  chunk_retain_period: 30s

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
    active_index_directory: /loki/index
    cache_location: /loki/cache
    shared_store: filesystem
  filesystem:
    directory: /loki/chunks

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  ingestion_rate_mb: 10
  ingestion_burst_size_mb: 20

chunk_store_config:
  max_look_back_period: 0s

table_manager:
  retention_deletes_enabled: false
  retention_period: 0s
```

### Promtail 설정

`promtail-config.yml`:
```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  # Docker 컨테이너 로그에서 수집
  - job_name: vllm-docker-logs
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
    relabel_configs:
      - source_labels: ['__meta_docker_container_name']
        regex: '/vllm'
        action: keep
      - source_labels: ['__meta_docker_container_name']
        target_label: container
        regex: '/(.*)'
        replacement: '$1'
    pipeline_stages:
      # vLLM 로그 파싱
      - regex:
          expression: '.*Finished request (?P<request_id>\S+).*'
      
      # 시간 정보 추출
      - regex:
          expression: '.*time_to_first_token:\s*(?P<ttft>[0-9.]+).*generation_time:\s*(?P<gen_time>[0-9.]+).*total_time:\s*(?P<total_time>[0-9.]+)'
      
      # 토큰 정보 추출
      - regex:
          expression: '.*prompt_tokens:\s*(?P<prompt_tokens>[0-9]+).*completion_tokens:\s*(?P<completion_tokens>[0-9]+)'
      
      # 라벨 추가
      - labels:
          request_id:
      
      # 메트릭 생성
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
```

### Grafana 데이터 소스 설정

`grafana/provisioning/datasources/datasources.yml`:
```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true

  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: true
    jsonData:
      derivedFields:
        - datasourceUid: Prometheus
          matcherRegex: "request_id=(\\S+)"
          name: request_id
          url: "$${__value.raw}"
```

### 실행 방법

```bash
# 1. 디렉토리 구조 생성
mkdir -p grafana/provisioning/datasources

# 2. 설정 파일 생성
touch prometheus.yml promtail-config.yml loki-config.yml
touch grafana/provisioning/datasources/datasources.yml

# 3. Docker Compose 실행
docker-compose up -d

# 4. 로그 확인
docker-compose logs -f vllm
docker-compose logs -f promtail

# 5. vLLM 정상 작동 확인
curl http://localhost:8000/v1/models
curl http://localhost:8000/metrics

# 6. 서비스 접속
# Prometheus: http://localhost:9090
# Loki: http://localhost:3100
# Grafana: http://localhost:3000 (admin/admin)
```

### Grafana 대시보드 쿼리

#### Prometheus 쿼리 (집계 메트릭):

**TTFT P95:**
```promql
histogram_quantile(0.95, 
  rate(vllm:time_to_first_token_seconds_bucket{model_name=~"$model_name"}[5m])
)
```

**Prefill Tokens/s:**
```promql
rate(vllm:prompt_tokens_total{model_name=~"$model_name"}[5m])
```

**Generation Tokens/s:**
```promql
rate(vllm:generation_tokens_total{model_name=~"$model_name"}[5m])
```

#### Loki 쿼리 (개별 요청 로그):

**최근 요청 목록:**
```logql
{container="vllm"} |~ "Finished request"
```

**특정 request_id 검색:**
```logql
{container="vllm"} | json | request_id="1a2b3c4d"
```

**느린 요청 (TTFT > 1초):**
```logql
{container="vllm"} |~ "Finished request" | logfmt | ttft > 1.0
```

#### Promtail이 생성한 메트릭:

**로그에서 추출한 TTFT:**
```promql
vllm_ttft_seconds
```

**로그에서 추출한 Generation Time:**
```promql
vllm_generation_time_seconds
```

### Grafana 대시보드 구성

#### Row 1: 전체 시스템 메트릭 (Prometheus)
- **요청/초**: `rate(vllm:request_success_total[5m])`
- **평균 TTFT**: `rate(vllm:time_to_first_token_seconds_sum[5m]) / rate(vllm:time_to_first_token_seconds_count[5m])`
- **P95 TTFT**: `histogram_quantile(0.95, rate(vllm:time_to_first_token_seconds_bucket[5m]))`

#### Row 2: 처리량 (Prometheus)
- **Prefill Tokens/s**: `rate(vllm:prompt_tokens_total[5m])`
- **Generation Tokens/s**: `rate(vllm:generation_tokens_total[5m])`

#### Row 3: 개별 요청 추적 (Loki)
- **최근 요청 로그 (Table)**: `{container="vllm"} |~ "Finished request" | logfmt`
  - Columns: time, request_id, ttft, gen_time, total_time, prompt_tokens, completion_tokens
- **느린 요청 알림**: `{container="vllm"} |~ "Finished request" | logfmt | total_time > 5.0`

---

## 문제 해결

### vLLM 로그 형식 확인

```bash
# vLLM 컨테이너 로그 확인
docker logs vllm -f
```

실제 로그 형식에 맞춰 `promtail-config.yml`의 regex를 수정해야 합니다.

### GPU 설정 문제

```bash
# GPU 확인
docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi

# 컨테이너 내부에서 GPU 확인
docker exec -it vllm nvidia-smi
```

### 모델 경로 문제

```bash
# 호스트에서 모델 경로 확인
ls -la /home/models/model-vlm-8b

# 컨테이너 내부에서 확인
docker exec -it vllm ls -la /models/model-vlm-8b
```

### 메모리 부족 시

```yaml
  vllm:
    # ...
    shm_size: '16gb'  # 공유 메모리 증가
```

---

## 정리

### 최종 아키텍처

```
┌─────────────────────────────────────────┐
│           Client Requests                │
└──────────────┬──────────────────────────┘
               ↓
┌──────────────────────────────────────────┐
│  vLLM Server (Inbound only)              │
│  - /v1/completions                       │
│  - /metrics (Prometheus pulls)           │
│  - logs → file/stdout                    │
└────┬─────────────────────┬────────────────┘
     ↓                     ↓
┌─────────────┐    ┌──────────────────┐
│ Prometheus  │    │ Promtail         │
│ (pull)      │    │ (read logs)      │
└─────┬───────┘    └────────┬─────────┘
      ↓                     ↓
┌─────────────┐    ┌──────────────────┐
│ Metrics DB  │    │ Loki             │
└─────┬───────┘    └────────┬─────────┘
      └──────────┬───────────┘
                 ↓
         ┌───────────────┐
         │   Grafana     │
         │ - Dashboards  │
         │ - Alerts      │
         └───────────────┘
```

### 주요 기능

**Prometheus:**
- 시스템 전체 메트릭 (TPS, P95, throughput)
- 집계된 성능 지표
- 알람 설정

**Loki:**
- 개별 요청 로그
- 요청별 상세 시간 정보
- 느린 요청 추적

**Grafana:**
- 통합 대시보드
- 시계열 차트
- 로그 검색 및 필터링

### 장점

1. **Outbound 차단 환경 호환**: Pull 방식으로 동작
2. **개별 요청 추적**: 로그에서 각 요청의 상세 정보 추출
3. **집계 메트릭**: Prometheus로 전체 시스템 성능 모니터링
4. **확장 가능**: 추가 메트릭 수집이 용이
5. **운영 효율**: 설정이 간단하고 유지보수 용이
