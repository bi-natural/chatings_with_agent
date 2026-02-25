#!/bin/bash

# Nginx 헬스체크 (통합 엔드포인트)
NGINX_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/healthz 2>/dev/null || echo "000")

# vLLM API 헬스체크 (Nginx를 통해)
VLLM_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/health 2>/dev/null || echo "000")

# Loki API 헬스체크 (Nginx를 통해)
LOKI_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/loki/ready 2>/dev/null || echo "000")

# 모두 정상이어야 healthy
if [ "$NGINX_HEALTH" = "200" ] && [ "$VLLM_HEALTH" = "200" ] && [ "$LOKI_HEALTH" = "200" ]; then
    echo "OK: Nginx, vLLM and Loki are healthy"
    exit 0
else
    echo "FAIL: Nginx=$NGINX_HEALTH, vLLM=$VLLM_HEALTH, Loki=$LOKI_HEALTH"
    exit 1
fi
