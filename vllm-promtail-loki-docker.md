# vLLM Monitoring Docker Image - 빌드 및 실행 가이드

## 디렉토리 구조

```
.
├── Dockerfile
├── docker-compose.yml
├── .dockerignore
├── config/
│   ├── loki-config.yml
│   ├── promtail-config.yml
│   └── supervisord.conf
└── scripts/
    ├── start-vllm.sh
    └── healthcheck.sh
```

## 이미지 빌드

### 1. 기본 빌드

```bash
docker build -t vllm-monitoring:latest .
```

### 2. 특정 vLLM 버전으로 빌드

Dockerfile에서 vLLM 버전 수정 후:
```bash
docker build -t vllm-monitoring:v0.3.0 .
```

### 3. 빌드 시간 단축 (캐시 사용)

```bash
docker build --build-arg BUILDKIT_INLINE_CACHE=1 -t vllm-monitoring:latest .
```

## 이미지 실행

### 방법 1: Docker Compose 사용 (권장)

#### docker-compose.yml 수정
```yaml
environment:
  - MODEL_PATH=/models/your-model-name  # 실제 모델 경로로 변경
  - SERVED_MODEL_NAME=your-model-name   # 원하는 서빙 이름
```

#### 실행
```bash
# 백그라운드 실행
docker-compose up -d

# 로그 확인
docker-compose logs -f

# 중지
docker-compose down

# 중지 및 볼륨 삭제
docker-compose down -v
```

### 방법 2: Docker Run 직접 사용

#### 기본 실행
```bash
docker run -d \
  --name vllm-server \
  --gpus all \
  -p 8000:8000 \
  -v /home/models:/models:ro \
  -e MODEL_PATH=/models/model-vlm-8b \
  -e SERVED_MODEL_NAME=model-vlm-8b \
  vllm-monitoring:latest
```

#### 전체 옵션 예시
```bash
docker run -d \
  --name vllm-server \
  --gpus all \
  -p 8000:8000 \
  -v /home/models:/models:ro \
  -v vllm-loki-data:/var/lib/loki \
  -v vllm-logs:/var/log/vllm \
  -e MODEL_PATH=/models/model-vlm-8b \
  -e SERVED_MODEL_NAME=model-vlm-8b \
  -e MAX_MODEL_LEN=16384 \
  -e TENSOR_PARALLEL_SIZE=1 \
  -e GPU_MEMORY_UTILIZATION=0.9 \
  -e MAX_NUM_SEQS=3 \
  -e MAX_NUM_BATCHED_TOKENS=6384 \
  -e TRUST_REMOTE_CODE=true \
  -e ASYNC_SCHEDULING=true \
  -e MM_ENCODER_TP_MODE=data \
  -e LIMIT_MM_PER_PROMPT_IMAGE=3 \
  -e LIMIT_MM_PER_PROMPT_VIDEO=0 \
  --restart unless-stopped \
  vllm-monitoring:latest
```

## 환경 변수 설정

### 필수 환경 변수

| 변수 | 설명 | 예시 |
|------|------|------|
| `MODEL_PATH` 또는 `MODEL_NAME` | 모델 경로 또는 HuggingFace 모델 이름 | `/models/llama-2-7b` 또는 `meta-llama/Llama-2-7b-hf` |

### 선택 환경 변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `SERVED_MODEL_NAME` | (모델명) | API에서 사용할 모델 이름 |
| `MAX_MODEL_LEN` | `16384` | 최대 시퀀스 길이 |
| `TENSOR_PARALLEL_SIZE` | `1` | Tensor Parallelism 크기 (GPU 개수) |
| `GPU_MEMORY_UTILIZATION` | `0.9` | GPU 메모리 사용률 (0.0-1.0) |
| `MAX_NUM_SEQS` | `256` | 최대 동시 시퀀스 수 |
| `MAX_NUM_BATCHED_TOKENS` | - | 배치 토큰 최대 개수 |
| `TRUST_REMOTE_CODE` | `true` | 원격 코드 실행 허용 |
| `ASYNC_SCHEDULING` | - | 비동기 스케줄링 활성화 |
| `MM_ENCODER_TP_MODE` | - | 멀티모달 인코더 TP 모드 (`data`, `tensor`) |
| `LIMIT_MM_PER_PROMPT_IMAGE` | `0` | 프롬프트당 최대 이미지 개수 |
| `LIMIT_MM_PER_PROMPT_VIDEO` | `0` | 프롬프트당 최대 비디오 개수 |
| `VLLM_EXTRA_ARGS` | - | 추가 vLLM 인자 (공백으로 구분) |

## 다양한 모델 실행 예시

### 1. 일반 텍스트 모델 (Llama)
```bash
docker run -d \
  --name llama-server \
  --gpus all \
  -p 8000:8000 -p 8001:8001 \
  -v /home/models:/models:ro \
  -e MODEL_PATH=/models/llama-2-7b-chat \
  -e SERVED_MODEL_NAME=llama-2-7b-chat \
  -e MAX_MODEL_LEN=4096 \
  -e TENSOR_PARALLEL_SIZE=1 \
  vllm-monitoring:latest
```

### 2. 멀티모달 모델 (Vision Language Model)
```bash
docker run -d \
  --name vlm-server \
  --gpus all \
  -p 8000:8000 -p 8001:8001 \
  -v /home/models:/models:ro \
  -e MODEL_PATH=/models/model-vlm-8b \
  -e SERVED_MODEL_NAME=vlm-8b \
  -e MAX_MODEL_LEN=16384 \
  -e ASYNC_SCHEDULING=true \
  -e MM_ENCODER_TP_MODE=data \
  -e LIMIT_MM_PER_PROMPT_IMAGE=3 \
  -e LIMIT_MM_PER_PROMPT_VIDEO=0 \
  vllm-monitoring:latest
```

### 3. 대형 모델 (Multi-GPU)
```bash
docker run -d \
  --name large-model-server \
  --gpus '"device=0,1,2,3"' \
  -p 8000:8000 -p 8001:8001 \
  -v /home/models:/models:ro \
  -e MODEL_PATH=/models/llama-70b \
  -e SERVED_MODEL_NAME=llama-70b \
  -e MAX_MODEL_LEN=4096 \
  -e TENSOR_PARALLEL_SIZE=4 \
  -e GPU_MEMORY_UTILIZATION=0.95 \
  vllm-monitoring:latest
```

### 4. HuggingFace Hub 모델 직접 로드
```bash
docker run -d \
  --name hf-model-server \
  --gpus all \
  -p 8000:8000 -p 8001:8001 \
  -e MODEL_NAME=meta-llama/Llama-2-7b-chat-hf \
  -e SERVED_MODEL_NAME=llama-2-7b-chat \
  -e MAX_MODEL_LEN=4096 \
  -e TRUST_REMOTE_CODE=true \
  vllm-monitoring:latest
```

## 엔드포인트 확인

모든 서비스가 **포트 8000**을 통해 통합 제공됩니다.

### vLLM API (포트 8000, 루트 경로)
```bash
# 헬스체크
curl http://localhost:8000/health

# 모델 목록
curl http://localhost:8000/v1/models

# Prometheus metrics
curl http://localhost:8000/metrics

# 테스트 요청
curl http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "model-vlm-8b",
    "prompt": "Hello, how are you?",
    "max_tokens": 50
  }'
```

### Loki API (포트 8000/loki)
```bash
# 헬스체크
curl http://localhost:8000/loki/ready

# Loki metrics
curl http://localhost:8000/loki/metrics

# 로그 쿼리 (최근 로그)
curl -G -s "http://localhost:8000/loki/api/v1/query" \
  --data-urlencode 'query={job="vllm"}' \
  --data-urlencode 'limit=10' | jq

# 로그 라벨 확인
curl http://localhost:8000/loki/api/v1/labels | jq
```

### Promtail Metrics (포트 8000/promtail)
```bash
# Promtail이 생성한 메트릭
curl http://localhost:8000/promtail/metrics
```

### Nginx 헬스체크
```bash
# Nginx 자체 헬스체크
curl http://localhost:8000/healthz
```

## 로그 확인

### 컨테이너 로그
```bash
# 전체 로그
docker logs vllm-server

# 실시간 로그
docker logs -f vllm-server

# 최근 100줄
docker logs --tail 100 vllm-server
```

### 컨테이너 내부 로그 파일
```bash
# 컨테이너 접속
docker exec -it vllm-server bash

# vLLM 로그
cat /var/log/vllm/vllm.log
tail -f /var/log/vllm/vllm.log

# Supervisor 로그
cat /var/log/supervisor/supervisord.log
cat /var/log/supervisor/loki-stdout.log
cat /var/log/supervisor/promtail-stdout.log

# Promtail position 확인
cat /var/lib/promtail/positions.yaml
```

## 문제 해결

### 1. vLLM이 시작하지 않는 경우
```bash
# 로그 확인
docker logs vllm-server | grep -i error

# GPU 확인
docker exec vllm-server nvidia-smi

# 모델 경로 확인
docker exec vllm-server ls -la /models
```

### 2. Loki에 로그가 수집되지 않는 경우
```bash
# Promtail 상태 확인
docker exec vllm-server supervisorctl status promtail

# Promtail 로그 확인
docker exec vllm-server cat /var/log/supervisor/promtail-stderr.log

# vLLM 로그 파일 존재 확인
docker exec vllm-server ls -la /var/log/vllm/

# Promtail position 확인
docker exec vllm-server cat /var/lib/promtail/positions.yaml
```

### 3. GPU 메모리 부족
```yaml
# docker-compose.yml에서 조정
environment:
  - GPU_MEMORY_UTILIZATION=0.8  # 0.9에서 0.8로 낮춤
  - MAX_NUM_SEQS=2              # 동시 시퀀스 수 감소
```

### 4. 컨테이너 재시작
```bash
# 단일 컨테이너
docker restart vllm-server

# Docker Compose
docker-compose restart

# 강제 재시작 (설정 변경 반영)
docker-compose down
docker-compose up -d
```

## Server B에서 연결 설정

### Prometheus 설정 (Server B)
`prometheus.yml`:
```yaml
scrape_configs:
  # vLLM metrics
  - job_name: 'vllm'
    static_configs:
      - targets: ['SERVER_A_IP:8000']
    metrics_path: '/metrics'
    scrape_interval: 10s

  # Promtail metrics (로그에서 추출한 메트릭)
  - job_name: 'promtail'
    static_configs:
      - targets: ['SERVER_A_IP:8000']
    metrics_path: '/promtail/metrics'
```

### Grafana Data Source 설정 (Server B)
`grafana/provisioning/datasources/datasources.yml`:
```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true

  - name: Loki-vLLM
    type: loki
    access: proxy
    url: http://SERVER_A_IP:8000/loki
    editable: true
```

**`SERVER_A_IP`를 실제 Docker 호스트 IP로 변경하세요.**

**참고**: Loki URL에 `/loki` 경로가 포함되어야 합니다!

## 업데이트 및 유지보수

### 이미지 업데이트
```bash
# 새 이미지 빌드
docker build -t vllm-monitoring:latest .

# 실행 중인 컨테이너 중지
docker-compose down

# 새 이미지로 시작
docker-compose up -d
```

### 데이터 백업
```bash
# Loki 데이터 백업
docker run --rm \
  -v vllm-loki-data:/data \
  -v $(pwd):/backup \
  ubuntu tar czf /backup/loki-backup.tar.gz /data

# 복원
docker run --rm \
  -v vllm-loki-data:/data \
  -v $(pwd):/backup \
  ubuntu tar xzf /backup/loki-backup.tar.gz -C /
```

### 리소스 모니터링
```bash
# 컨테이너 리소스 사용량
docker stats vllm-server

# 디스크 사용량
docker system df
docker volume ls
docker volume inspect vllm-loki-data
```

## 프로덕션 배포 권장 사항

1. **리소스 제한 설정**
```yaml
services:
  vllm-monitoring:
    # ...
    deploy:
      resources:
        limits:
          cpus: '8'
          memory: 32G
```

2. **로그 로테이션**
```yaml
logging:
  driver: "json-file"
  options:
    max-size: "100m"
    max-file: "5"
```

3. **헬스체크 활성화**
```yaml
healthcheck:
  test: ["CMD", "/usr/local/bin/healthcheck.sh"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 120s
```

4. **네트워크 보안**
- 방화벽에서 8000 포트만 외부 노출
- Nginx를 통한 경로 기반 접근 제어 가능

5. **모니터링 알람 설정**
- Prometheus Alertmanager 연동
- vLLM 응답 시간, 에러율 모니터링
- Loki 디스크 사용량 모니터링

---

## 요약

이 Docker 이미지는 다음을 포함합니다:
- ✅ vLLM (내부 포트 8001)
- ✅ Loki (내부 포트 3100)
- ✅ Promtail (로그 수집 및 메트릭 생성, 내부 포트 9080)
- ✅ Nginx (Reverse Proxy, 포트 8000)
- ✅ 환경 변수를 통한 유연한 설정
- ✅ Supervisor를 통한 프로세스 관리
- ✅ 헬스체크 기능

**외부에서 접근할 포트:**
- `8000`: 통합 엔드포인트
  - `/` : vLLM API 및 Prometheus metrics
  - `/loki/` : Loki API (Grafana에서 로그 쿼리)
  - `/promtail/` : Promtail metrics (Prometheus에서 scrape)

**아키텍처:**
```
                    포트 8000 (Nginx Reverse Proxy)
                             ↓
        ┌────────────────────┼────────────────────┐
        │                    │                    │
     / (루트)            /loki/              /promtail/
        ↓                    ↓                    ↓
  vLLM:8001            Loki:3100          Promtail:9080
```
