# vLLM Monitoring All-in-One Docker Image
FROM nvidia/cuda:12.1.0-runtime-ubuntu22.04

# 환경 변수 설정
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:$PATH \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH

# 기본 패키지 설치
RUN apt-get update && apt-get install -y \
    python3.10 \
    python3-pip \
    wget \
    curl \
    unzip \
    supervisor \
    nginx \
    && rm -rf /var/lib/apt/lists/*

# Python 패키지 설치
RUN pip3 install --no-cache-dir \
    vllm==0.3.0 \
    fastapi \
    uvicorn

# Loki 설치
RUN cd /tmp && \
    wget -q https://github.com/grafana/loki/releases/download/v2.9.3/loki-linux-amd64.zip && \
    unzip loki-linux-amd64.zip && \
    mv loki-linux-amd64 /usr/local/bin/loki && \
    chmod +x /usr/local/bin/loki && \
    rm loki-linux-amd64.zip

# Promtail 설치
RUN cd /tmp && \
    wget -q https://github.com/grafana/loki/releases/download/v2.9.3/promtail-linux-amd64.zip && \
    unzip promtail-linux-amd64.zip && \
    mv promtail-linux-amd64 /usr/local/bin/promtail && \
    chmod +x /usr/local/bin/promtail && \
    rm promtail-linux-amd64.zip

# 디렉토리 생성
RUN mkdir -p /var/log/vllm \
    /var/lib/loki/chunks \
    /var/lib/loki/index \
    /var/lib/promtail \
    /etc/loki \
    /etc/promtail \
    /etc/supervisor/conf.d

# Loki 설정 파일 복사
COPY config/loki-config.yml /etc/loki/loki-config.yml

# Promtail 설정 파일 복사
COPY config/promtail-config.yml /etc/promtail/promtail-config.yml

# Nginx 설정 파일 복사
COPY config/nginx.conf /etc/nginx/nginx.conf

# Supervisor 설정 파일 복사
COPY config/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# vLLM 시작 스크립트 복사
COPY scripts/start-vllm.sh /usr/local/bin/start-vllm.sh
RUN chmod +x /usr/local/bin/start-vllm.sh

# 헬스체크 스크립트 복사
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/healthcheck.sh

# 포트 노출
# 8000: 통합 엔드포인트 (vLLM + Loki + Promtail)
#   - /            : vLLM API
#   - /loki        : Loki API (Grafana에서 scrape)
#   - /promtail    : Promtail metrics (선택사항)
EXPOSE 8000

# vLLM 설정을 위한 기본 환경 변수 (override 가능)
ENV MODEL_NAME="" \
    MODEL_PATH="/models" \
    SERVED_MODEL_NAME="" \
    MAX_MODEL_LEN="16384" \
    TENSOR_PARALLEL_SIZE="1" \
    GPU_MEMORY_UTILIZATION="0.9" \
    MAX_NUM_SEQS="256" \
    MAX_NUM_BATCHED_TOKENS="" \
    TRUST_REMOTE_CODE="true" \
    VLLM_EXTRA_ARGS="" \
    LIMIT_MM_PER_PROMPT_IMAGE="0" \
    LIMIT_MM_PER_PROMPT_VIDEO="0"

# 헬스체크
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

# Supervisor로 모든 프로세스 시작
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
