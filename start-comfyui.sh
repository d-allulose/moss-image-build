#!/usr/bin/env bash
# ComfyUI 启动入口（平台暴露 8188 端口）
set -euo pipefail
PORT="${COMFYUI_PORT:-8188}"

echo "[start] ComfyUI port=${PORT} models=/models"

# 可选：只下载权重进卷（一次性任务用），下载完直接退出
if [ -n "${PREPARE_MODELS:-}" ]; then
  echo "[start] PREPARE_MODELS=${PREPARE_MODELS} → 只下载模型，不启动 ComfyUI"
  python /opt/prepare_models.py --config /config/models.json --dest /models
  echo "[start] 模型就绪，退出"
  exit 0
fi
if [ -d /models ]; then
  find /models -maxdepth 2 -type d | sed 's/^/[start]   /' | head -20
  find /models -name '*.safetensors' -size +100M -printf '[start] model: %10s  %p\n' 2>/dev/null | head -20
else
  echo "[start] WARN /models 未挂载：服务能起，但模型加载会失败"
fi

# ── 方案 B：代码覆盖（不重建镜像就能更新节点/脚本）───────────────────────────
# OSS 里 models/_code/ 的内容会在启动时覆盖镜像内同名文件：
#   models/_code/custom_nodes/<name>/... → /comfyui/custom_nodes/<name>/
#   models/_code/config/...              → /config/
# 不存在或为空 → 用镜像内置版本（兜底，绝不会起不来）
CODE_DIR="${COMFY_CODE_DIR:-/models/_code}"
if [ -d "$CODE_DIR/custom_nodes" ] && [ -n "$(ls -A "$CODE_DIR/custom_nodes" 2>/dev/null || true)" ]; then
  echo "[start] 代码覆盖: 发现 $CODE_DIR/custom_nodes"
  for d in "$CODE_DIR"/custom_nodes/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    echo "[start] 代码覆盖: custom_nodes/$name"
    mkdir -p "/comfyui/custom_nodes/$name"
    cp -a "$d." "/comfyui/custom_nodes/$name/" || echo "[start] WARN 覆盖 custom_nodes/$name 失败，沿用内置版本"
  done
  echo "[start] 代码覆盖: 完成"
else
  echo "[start] 代码覆盖: 无（使用镜像内置版本）"
fi
if [ -d "$CODE_DIR/config" ] && [ -n "$(ls -A "$CODE_DIR/config" 2>/dev/null || true)" ]; then
  echo "[start] 代码覆盖: 发现 $CODE_DIR/config"
  cp -a "$CODE_DIR/config/." /config/ || echo "[start] WARN 覆盖 /config 失败"
fi

# shellcheck disable=SC2086
exec python /comfyui/main.py \
  --listen 0.0.0.0 \
  --port "${PORT}" \
  --disable-auto-launch \
  --disable-metadata \
  ${COMFYUI_EXTRA_ARGS:-}
