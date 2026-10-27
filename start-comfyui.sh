#!/usr/bin/env bash
# ComfyUI 启动入口（平台暴露 8188 端口）
set -euo pipefail
PORT="${COMFYUI_PORT:-8188}"

echo "[start] ComfyUI port=${PORT} models=/models"
if [ -d /models ]; then
  find /models -maxdepth 2 -type d | sed 's/^/[start]   /' | head -20
  find /models -name '*.safetensors' -size +100M -printf '[start] model: %10s  %p\n' 2>/dev/null | head -20
else
  echo "[start] WARN /models 未挂载：服务能起，但模型加载会失败"
fi

# shellcheck disable=SC2086
exec python /comfyui/main.py \
  --listen 0.0.0.0 \
  --port "${PORT}" \
  --disable-auto-launch \
  --disable-metadata \
  ${COMFYUI_EXTRA_ARGS:-}
