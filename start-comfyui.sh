#!/usr/bin/env bash
# ComfyUI 启动入口（平台暴露 8188 端口）
#
# 三层架构里的「L2 组装器」：
#   L1 镜像 = 固定骨架（CUDA / torch / ComfyUI 本体 / apt 工具 / 通用 pip 依赖 / Manager）
#   L2 对象存储加速 /models/_code = 运行时可替换内容（节点包 / 依赖清单 / wheel / ComfyUI 源码 / config）
#   本脚本在每次启动时把 L2 组装进容器，因此换节点、换工作流、换模型都不需要重建镜像。
#
# 覆盖顺序（按依赖关系）：
#   1) custom_nodes 代码      → 复制到 /comfyui/custom_nodes
#   2) requirements.txt 依赖  → 优先离线 wheels，失败回退在线 pip
#   3) （可选）ComfyUI 源码    → 覆盖 /comfyui（升级 ComfyUI 不必重建镜像）
#   4) config                 → 覆盖 /config
set -euo pipefail
PORT="${COMFYUI_PORT:-8188}"
CODE_DIR="${COMFY_CODE_DIR:-/models/_code}"
T0=$(date +%s)
log() { echo "[start +$(( $(date +%s) - T0 ))s] $*"; }

log "ComfyUI port=${PORT} models=/models code=${CODE_DIR}"

# 可选：只下载权重进卷（一次性任务用），下载完直接退出
if [ -n "${PREPARE_MODELS:-}" ]; then
  log "PREPARE_MODELS=${PREPARE_MODELS} → 只下载模型，不启动 ComfyUI"
  python /opt/prepare_models.py --config /config/models.json --dest /models
  log "模型就绪，退出"
  exit 0
fi

if [ -d /models ]; then
  find /models -name '*.safetensors' -size +100M -printf '[start] model: %10s  %p\n' 2>/dev/null | head -15
else
  log "WARN /models 未挂载：服务能起，但模型加载会失败"
fi

if [ ! -d "$CODE_DIR" ]; then
  log "覆盖层: 未发现 ${CODE_DIR}，全部使用镜像内置版本"
fi

# ── 1) custom_nodes 代码覆盖 ────────────────────────────────────────────────
if [ -d "$CODE_DIR/custom_nodes" ] && [ -n "$(ls -A "$CODE_DIR/custom_nodes" 2>/dev/null || true)" ]; then
  log "覆盖层: 发现 $CODE_DIR/custom_nodes"
  for d in "$CODE_DIR"/custom_nodes/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    mkdir -p "/comfyui/custom_nodes/$name"
    if cp -a "$d." "/comfyui/custom_nodes/$name/"; then
      log "覆盖层: custom_nodes/$name ok"
    else
      log "WARN 覆盖 custom_nodes/$name 失败，沿用内置版本"
    fi
  done
else
  log "覆盖层: 无 custom_nodes（使用镜像内置版本）"
fi

# ── 2) 依赖安装（离线 wheels 优先，失败回退在线）─────────────────────────────
if [ -f "$CODE_DIR/requirements.txt" ]; then
  log "依赖: 发现 $CODE_DIR/requirements.txt"
  if [ -d "$CODE_DIR/wheels" ] && [ -n "$(ls -A "$CODE_DIR/wheels" 2>/dev/null || true)" ]; then
    log "依赖: 先试离线 wheels（$(find "$CODE_DIR/wheels" -name '*.whl' | wc -l) 个）"
    timeout 900 python -m pip install -q --no-cache-dir --no-input \
      --no-index --find-links "$CODE_DIR/wheels" -r "$CODE_DIR/requirements.txt" \
      || log "WARN 离线 wheels 安装未完成，回退在线 pip"
  fi
  if ! timeout 1200 python -m pip install -q --no-cache-dir --no-input -r "$CODE_DIR/requirements.txt"; then
    log "WARN 依赖安装失败（继续启动；缺依赖的节点会报错）"
  fi
  log "依赖: 完成"
else
  log "依赖: 无 requirements.txt（使用镜像内置依赖）"
fi

# 可选：逐个节点包安装 requirements（默认关；COMFY_AUTO_REQUIREMENTS=1 开启，启动会变慢）
if [ "${COMFY_AUTO_REQUIREMENTS:-0}" = "1" ] && [ -d "$CODE_DIR/custom_nodes" ]; then
  while IFS= read -r req; do
    log "自动依赖: $req"
    timeout 900 python -m pip install -q --no-cache-dir --no-input -r "$req" \
      || log "WARN 自动依赖失败: $req"
  done < <(find "$CODE_DIR/custom_nodes" -maxdepth 2 -name requirements.txt 2>/dev/null)
fi

# ── 3) （可选）ComfyUI 源码覆盖：升级 ComfyUI 本体不用重建镜像 ────────────────
if [ -d "$CODE_DIR/ComfyUI" ] && [ -n "$(ls -A "$CODE_DIR/ComfyUI" 2>/dev/null || true)" ]; then
  log "ComfyUI 源码: 发现 $CODE_DIR/ComfyUI，覆盖 /comfyui"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a \
      --exclude '.venv' --exclude 'extra_model_paths.yaml' \
      --exclude 'custom_nodes' --exclude 'models' \
      --exclude 'input' --exclude 'output' --exclude 'user' --exclude '.git' \
      "$CODE_DIR/ComfyUI/" /comfyui/ \
      || log "WARN ComfyUI 源码覆盖失败，继续用镜像内置版本"
  else
    cp -a "$CODE_DIR/ComfyUI/." /comfyui/ || log "WARN ComfyUI 源码覆盖失败"
  fi
  log "ComfyUI 源码: 完成"
fi

# ── 4) config 覆盖（extra_model_paths.yaml / models.json 等）──────────────────
if [ -d "$CODE_DIR/config" ] && [ -n "$(ls -A "$CODE_DIR/config" 2>/dev/null || true)" ]; then
  log "配置: 覆盖 $CODE_DIR/config"
  cp -a "$CODE_DIR/config/." /config/ || log "WARN 覆盖 /config 失败"
fi

log "组装完成，启动 ComfyUI"
# shellcheck disable=SC2086
exec python /comfyui/main.py \
  --listen 0.0.0.0 \
  --port "${PORT}" \
  --disable-auto-launch \
  ${COMFYUI_EXTRA_ARGS:-}
