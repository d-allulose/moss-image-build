# syntax=docker/dockerfile:1
#
# MOSS-Image · 薄镜像（不含模型权重）
#
# 用法：在 GPU 云平台（共绩算力等）作为「自定义镜像」部署，模型权重放挂载卷 /models。
#       镜像只含运行环境，便于公开分发，也避免模型许可问题。
#
# 关键版本（勿随意改，都是踩过坑钉住的）：
#   COMFYUI_REF=5cc4b87…  ComfyUI v0.41.0 tag 不含 CLIPType.MOSS_IMAGE，必须用该 master 提交；
#                         构建期 grep 断言，避免「构建成功、一跑就 400」的假绿。
#   torch 2.13.0+cu130    ComfyUI 的 comfy/quant_ops.py 在 torch.version.cuda < 13 时会关掉
#                         comfy_kitchen 的优化 CUDA backend，int8 convrot 退化为 eager Python
#                         （实测每步慢约 3 倍）。宿主驱动 13.x 向下兼容 cu13 runtime。
#   TORCH_DISABLE_NATIVE_JIT=1  torch 2.13 的 torch._native 对少数算子挂 Triton 实现，首次调用要
#                         现场编译 C 扩展；镜像里没有 gcc 会直接 RuntimeError。关掉后走 ATen 兜底。
#
# 模型不烘焙：/models 由平台挂载（见 extra_model_paths.yaml）。
#   /models/diffusion_models  /models/text_encoders  /models/vae  /models/loras
# 用 scripts/prepare_models.py 在一次性任务里把权重下载进卷（支持 HF + Civitai 鉴权）。
#
# 基础镜像沿用已验证组合（CUDA 12.8 runtime + Python 3.12 + venv），改动最小。
FROM runpod/worker-comfyui:5.10.0-base

ARG COMFYUI_REF=5cc4b870094c89090db54bd8d12649dcaf89f2ba
ARG TRANSFORMERS_VER=5.14.1
ARG TORCH_VER=2.13.0
ARG TORCHVISION_VER=0.28.0
ARG TORCH_CUDA_INDEX=https://download.pytorch.org/whl/cu130

USER root
ENV DEBIAN_FRONTEND=noninteractive \
    HF_HUB_DISABLE_TELEMETRY=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# 1a) ComfyUI 升到含 MOSS-Image 支持的那次提交
RUN set -eux; \
    cd /comfyui; \
    if [ -d .git ] && git fetch --depth 1 origin "${COMFYUI_REF}"; then \
        echo "[build] 方式=git fetch 指定提交"; \
        git -c advice.detachedHead=false checkout -q "${COMFYUI_REF}"; \
        git rev-parse HEAD; \
    else \
        echo "[build] 方式=clone 深度 300 后 checkout"; \
        rm -rf /tmp/comfyref; \
        git clone --depth 300 https://github.com/comfyanonymous/ComfyUI.git /tmp/comfyref; \
        git -C /tmp/comfyref -c advice.detachedHead=false checkout -q "${COMFYUI_REF}"; \
        rm -rf /comfyui/.git; \
        find /comfyui -mindepth 1 -maxdepth 1 ! -name .venv -exec rm -rf {} +; \
        cp -a /tmp/comfyref/. /comfyui/; \
        rm -rf /tmp/comfyref; \
    fi; \
    cd /comfyui; \
    grep -q "MOSS_IMAGE" comfy/sd.py \
        && echo "[build] 源码含 CLIPType.MOSS_IMAGE: ok" \
        || { echo "[build] FATAL 源码不含 CLIPType.MOSS_IMAGE"; exit 1; }

# 1b) ComfyUI 依赖
RUN cd /comfyui && python -m pip install --no-cache-dir -r requirements.txt

# 1c) transformers 版本对齐（与本地实跑通过的 5.14.1 一致）
RUN cd /comfyui && python -m pip install --no-cache-dir "transformers==${TRANSFORMERS_VER}"

# 1d) torch 升到 cu130 —— 性能关键
RUN set -eux; \
    python -m pip install --no-cache-dir --index-url "${TORCH_CUDA_INDEX}" \
      "torch==${TORCH_VER}+cu130" "torchvision==${TORCHVISION_VER}+cu130"; \
    python -c "import torch; c=torch.version.cuda; print('[build] torch', torch.__version__, 'cuda', c); assert tuple(map(int,c.split('.'))) >= (13,), 'cu130+ required'"
ENV TORCH_DISABLE_NATIVE_JIT=1

# 2) MOSS-Image 自定义节点（Apache-2.0，纯 Python）
RUN git clone --depth 1 https://github.com/OpenMOSS/MOSS-Image.git /tmp/MOSS-Image \
 && cp -r /tmp/MOSS-Image/comfyui/moss-image /comfyui/custom_nodes/moss-image \
 && rm -rf /tmp/MOSS-Image \
 && test -f /comfyui/custom_nodes/moss-image/__init__.py

# 3) 把模型搜索路径指向挂载卷 /models
COPY extra_model_paths.yaml /comfyui/extra_model_paths.yaml

# 4) 构建期启动自检：这一步失败 = 线上必然 "ComfyUI server not reachable"
RUN cd /comfyui && timeout 900 python main.py --quick-test-for-ci --cpu \
 && echo "[build] ComfyUI 启动自检通过"

# 5) 模型下载脚本 + 清单（可选：PREPARE_MODELS=1 时启动只做下载，不启动 ComfyUI）
COPY scripts/prepare_models.py /opt/prepare_models.py
COPY config/models.json /config/models.json

# 6) 启动入口：ComfyUI HTTP 服务（平台按端口 8188 转发）
COPY start-comfyui.sh /start-comfyui.sh
RUN chmod +x /start-comfyui.sh && du -sh /comfyui
# 方案 B（代码覆盖层，见 runpod-moss-serverless/docs/gongji-deploy.md §9）
# 挂载卷中 models/_code/ 的内容会在启动时覆盖 custom_nodes/ 与 /config/，
# 因此改节点代码只需 `oss_upload.py code` + 重启任务，无需重建本镜像。
ENV COMFY_CODE_DIR=/models/_code     COMFYUI_PORT=8188
EXPOSE 8188
CMD ["/start-comfyui.sh"]
