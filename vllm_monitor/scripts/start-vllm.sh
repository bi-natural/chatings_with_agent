#!/bin/bash
set -e

# 환경 변수 확인
if [ -z "$MODEL_NAME" ] && [ -z "$MODEL_PATH" ]; then
    echo "ERROR: Either MODEL_NAME or MODEL_PATH must be set"
    exit 1
fi

# 모델 경로 결정
if [ -n "$MODEL_NAME" ]; then
    MODEL="${MODEL_NAME}"
elif [ -n "$MODEL_PATH" ]; then
    MODEL="${MODEL_PATH}"
fi

# SERVED_MODEL_NAME 기본값 설정
if [ -z "$SERVED_MODEL_NAME" ]; then
    SERVED_MODEL_NAME=$(basename "$MODEL")
fi

# vLLM 명령어 구성
VLLM_CMD="vllm serve ${MODEL}"
VLLM_CMD="${VLLM_CMD} --host 0.0.0.0"
VLLM_CMD="${VLLM_CMD} --port 8001"
VLLM_CMD="${VLLM_CMD} --served-model-name ${SERVED_MODEL_NAME}"

# 선택적 파라미터 추가
if [ -n "$MAX_MODEL_LEN" ]; then
    VLLM_CMD="${VLLM_CMD} --max-model-len ${MAX_MODEL_LEN}"
fi

if [ -n "$TENSOR_PARALLEL_SIZE" ]; then
    VLLM_CMD="${VLLM_CMD} --tensor-parallel-size ${TENSOR_PARALLEL_SIZE}"
fi

if [ -n "$GPU_MEMORY_UTILIZATION" ]; then
    VLLM_CMD="${VLLM_CMD} --gpu-memory-utilization ${GPU_MEMORY_UTILIZATION}"
fi

if [ -n "$MAX_NUM_SEQS" ]; then
    VLLM_CMD="${VLLM_CMD} --max-num-seqs ${MAX_NUM_SEQS}"
fi

if [ -n "$MAX_NUM_BATCHED_TOKENS" ]; then
    VLLM_CMD="${VLLM_CMD} --max-num-batched-tokens ${MAX_NUM_BATCHED_TOKENS}"
fi

if [ "$TRUST_REMOTE_CODE" = "true" ]; then
    VLLM_CMD="${VLLM_CMD} --trust-remote-code"
fi

if [ "$ASYNC_SCHEDULING" = "true" ]; then
    VLLM_CMD="${VLLM_CMD} --async-scheduling"
fi

if [ -n "$MM_ENCODER_TP_MODE" ]; then
    VLLM_CMD="${VLLM_CMD} --mm-encoder-tp-mode ${MM_ENCODER_TP_MODE}"
fi

if [ -n "$LIMIT_MM_PER_PROMPT_IMAGE" ] && [ "$LIMIT_MM_PER_PROMPT_IMAGE" != "0" ]; then
    VLLM_CMD="${VLLM_CMD} --limit-mm-per-prompt image=${LIMIT_MM_PER_PROMPT_IMAGE}"
fi

if [ -n "$LIMIT_MM_PER_PROMPT_VIDEO" ] && [ "$LIMIT_MM_PER_PROMPT_VIDEO" != "0" ]; then
    VLLM_CMD="${VLLM_CMD} --limit-mm-per-prompt video=${LIMIT_MM_PER_PROMPT_VIDEO}"
fi

# 추가 인자 (사용자 정의)
if [ -n "$VLLM_EXTRA_ARGS" ]; then
    VLLM_CMD="${VLLM_CMD} ${VLLM_EXTRA_ARGS}"
fi

# 로그 출력
echo "========================================"
echo "Starting vLLM with the following configuration:"
echo "========================================"
echo "Model: ${MODEL}"
echo "Served Model Name: ${SERVED_MODEL_NAME}"
echo "Max Model Length: ${MAX_MODEL_LEN}"
echo "Tensor Parallel Size: ${TENSOR_PARALLEL_SIZE}"
echo "GPU Memory Utilization: ${GPU_MEMORY_UTILIZATION}"
echo "Max Num Seqs: ${MAX_NUM_SEQS}"
if [ -n "$MAX_NUM_BATCHED_TOKENS" ]; then
    echo "Max Num Batched Tokens: ${MAX_NUM_BATCHED_TOKENS}"
fi
echo "Trust Remote Code: ${TRUST_REMOTE_CODE}"
if [ -n "$ASYNC_SCHEDULING" ]; then
    echo "Async Scheduling: ${ASYNC_SCHEDULING}"
fi
if [ -n "$MM_ENCODER_TP_MODE" ]; then
    echo "MM Encoder TP Mode: ${MM_ENCODER_TP_MODE}"
fi
if [ -n "$LIMIT_MM_PER_PROMPT_IMAGE" ] && [ "$LIMIT_MM_PER_PROMPT_IMAGE" != "0" ]; then
    echo "Limit MM Per Prompt (Image): ${LIMIT_MM_PER_PROMPT_IMAGE}"
fi
if [ -n "$LIMIT_MM_PER_PROMPT_VIDEO" ] && [ "$LIMIT_MM_PER_PROMPT_VIDEO" != "0" ]; then
    echo "Limit MM Per Prompt (Video): ${LIMIT_MM_PER_PROMPT_VIDEO}"
fi
if [ -n "$VLLM_EXTRA_ARGS" ]; then
    echo "Extra Args: ${VLLM_EXTRA_ARGS}"
fi
echo "========================================"
echo "Full command: ${VLLM_CMD}"
echo "========================================"

# vLLM 실행
exec ${VLLM_CMD}
