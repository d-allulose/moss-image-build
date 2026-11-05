# syntax=docker/dockerfile:1
#
# MOSS-Image · 薄镜像（不含模型权重）· 两阶段构建版
#
# 为什么是两阶段：
#   旧版直接继承 runpod/worker-comfyui:5.10.0-base（自带 torch cu12.8 + 一份 torch 2.11），
#   再在同一个镜像里 pip 装 torch 2.13 —— Docker 分层只增不减，结果 16.5 GB 镜像里
#   有 14 GB 是三份 PyTorch。共绩节点每次拉镜像都要把这三份都拖下来（37 分钟起步）。
#   现在：builder 阶段随便装/重装，最终镜像只 COPY 一份干净的 venv（约 4–5 GB 压缩）。
#
# 用法：GPU 云平台作为「自定义镜像」部署，模型权重放挂载卷 /models；镜像只含运行环境。
#
# 关键版本（勿随意改，都是踩过坑钉住的）：
#   COMFYUI_REF=5cc4b87…  ComfyUI v0.41.0 tag 不含 CLIPType.MOSS_IMAGE，必须用该 master 提交；
#                         构建期 grep 断言，避免「构建成功、一跑就 400」的假绿。
#   torch 2.13.0+cu130    comfy/quant_ops.py 在 torch.version.cuda < 13 时会关掉 comfy_kitchen 的
#                         优化 CUDA backend，int8 convrot 退化成 eager Python（每步慢约 3 倍）。
#   TORCH_DISABLE_NATIVE_JIT=1  torch 2.13 的 torch._native 对少数算子走 Triton，首次调用要现场编译；
#                         镜像里没 gcc 会 RuntimeError，关掉后走 ATen 兜底。
#
# 模型不烘焙：/models 由平台挂载（见 extra_model_paths.yaml）。
#   /models/diffusion_models  /models/text_encoders  /models/vae  /models/loras

# ---------------------------------------------------------------- builder
FROM python:3.12-slim-bookworm AS builder
# 2026-11-05：国内构建时 pip 走阿里云镜像（ECS 内网极快）；境外构建可 --build-arg 覆盖。
ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
ENV PIP_INDEX_URL=${PIP_INDEX_URL} PIP_DISABLE_PIP_VERSION_CHECK=1

ARG COMFYUI_REF=5cc4b870094c89090db54bd8d12649dcaf89f2ba
ARG TRANSFORMERS_VER=5.14.1
ARG TORCH_VER=2.13.0
ARG TORCHVISION_VER=0.28.0
ARG TORCH_CUDA_INDEX=https://download.pytorch.org/whl/cu130

ENV DEBIAN_FRONTEND=noninteractive \
    HF_HUB_DISABLE_TELEMETRY=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends git curl ca-certificates; \
    rm -rf /var/lib/apt/lists/*

# 独立 venv：最终只把 /opt/venv 复制进 runtime，builder 里的中间层一律不进镜像
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
RUN pip install -U pip wheel

# 1) 先装 torch（cu130）—— 关键版本
RUN set -eux; \
    pip install --no-cache-dir --index-url "${TORCH_CUDA_INDEX}" \
      "torch==${TORCH_VER}+cu130" "torchvision==${TORCHVISION_VER}+cu130"; \
    python -c "import torch; c=torch.version.cuda; print('[build] torch', torch.__version__, 'cuda', c); assert c and tuple(map(int,c.split('.'))) >= (13,), 'cu130+ required'"

# 2) ComfyUI 源码：钉到含 MOSS-Image 的那次提交
RUN set -eux; \
    git clone --filter=blob:none https://github.com/comfyanonymous/ComfyUI.git /comfyui; \
    cd /comfyui; \
    git -c advice.detachedHead=false checkout -q "${COMFYUI_REF}"; \
    rm -rf .git; \
    grep -q "MOSS_IMAGE" comfy/sd.py \
        && echo "[build] 源码含 CLIPType.MOSS_IMAGE: ok" \
        || { echo "[build] FATAL 源码不含 CLIPType.MOSS_IMAGE"; exit 1; }

# 3) ComfyUI 依赖（torch 已满足，不会重装）
RUN cd /comfyui && pip install --no-cache-dir -r requirements.txt

# 4) transformers 版本对齐（与本地实跑通过的 5.14.1 一致）
RUN pip install --no-cache-dir "transformers==${TRANSFORMERS_VER}"

# 5) 通用 pip 依赖大礼包
# 目的：让「纯 Python 节点包 + 常见 pip 依赖」无需重建镜像就能生效（启动时走覆盖层安装）。
# constraints.txt 钉住 torch / numpy / transformers，避免被这些包顺手升级。
# 下面每个包也钉死到「与 numpy 1.26 兼容、且提供 cp312 wheel」的版本：
#   不钉的话 pip 会先试 opencv 5 / scipy 1.18（都要求 numpy>=2），一路回溯，构建能卡半小时以上。
COPY constraints.txt /tmp/constraints.txt
# 注：这些包不钉小版本 —— 镜像基线自带 numpy 2.x，钉 numpy1 时代的旧版本会装不上/装完 import 崩
#     （曾因此残留老 scipy，构建期自检报 AttributeError: numpy has no attribute long）。
RUN pip install --no-cache-dir -c /tmp/constraints.txt \
      opencv-python-headless onnxruntime-gpu accelerate diffusers \
      scipy scikit-image scikit-learn timm einops kornia spandrel \
      gguf sentencepiece tokenizers protobuf av imageio-ffmpeg \
      matplotlib psutil python-dotenv numexpr ftfy regex pyyaml requests tqdm \
    || echo "[build] WARN 依赖大礼包安装未完成（不阻断构建，缺的依赖可走 L2 覆盖层补）"

# 5b) L2 覆盖层里节点包常用的依赖（原先靠启动时在线 pip 装，拖慢/卡住启动）
RUN pip install --no-cache-dir -c /tmp/constraints.txt \
      aiohttp-socks jinja2 piexif olefile toml natsort GitPython aiosqlite \
      beautifulsoup4 platformdirs "brotli>=1.2.0" \
    || echo "[build] WARN 覆盖层依赖安装未完成（启动时仍可由 L2 requirements.txt 补）"

# 6) requirements.txt 里若有 torch/torchvision/torchaudio，可能把 cu130 版本换掉；
#    builder 里强制装回，最终只复制 venv，不会产生重复层。
RUN set -eux; \
    pip install --no-cache-dir --force-reinstall --no-deps \
      --index-url "${TORCH_CUDA_INDEX}" \
      "torch==${TORCH_VER}+cu130" "torchvision==${TORCHVISION_VER}+cu130"; \
    python -c "import torch; print('[build] final torch', torch.__version__, torch.version.cuda)"

# 7) MOSS-Image 自定义节点（Apache-2.0，纯 Python）
RUN set -eux; \
    clone_moss() { rm -rf /tmp/MOSS-Image; git -c http.version=HTTP/1.1 -c http.postBuffer=524288000 clone --depth 1 https://github.com/OpenMOSS/MOSS-Image.git /tmp/MOSS-Image; }; \
    clone_moss || { sleep 5; clone_moss; } || { sleep 15; clone_moss; } || { \
      echo "[build] git clone 三次失败，改用 codeload tarball"; \
      curl -fsSL --retry 6 --retry-delay 5 -o /tmp/mi.tgz https://codeload.github.com/OpenMOSS/MOSS-Image/tar.gz/refs/heads/main; \
      rm -rf /tmp/MOSS-Image; mkdir -p /tmp/MOSS-Image; \
      tar xzf /tmp/mi.tgz -C /tmp/MOSS-Image --strip-components=1; \
    }; \
    cp -r /tmp/MOSS-Image/comfyui/moss-image /comfyui/custom_nodes/moss-image; \
    rm -rf /tmp/MOSS-Image /tmp/mi.tgz; \
    test -f /comfyui/custom_nodes/moss-image/__init__.py

# 8) ComfyUI-Manager：运行时在线装节点/装依赖的兜底工具
RUN set -eux; \
    clone_mgr() { rm -rf /comfyui/custom_nodes/ComfyUI-Manager; git -c http.version=HTTP/1.1 -c http.postBuffer=524288000 clone --depth 1 https://github.com/Comfy-Org/ComfyUI-Manager.git /comfyui/custom_nodes/ComfyUI-Manager; }; \
    clone_mgr || { sleep 5; clone_mgr; } || { sleep 15; clone_mgr; } || { \
      echo "[build] Manager clone 三次失败，改用 codeload tarball"; \
      curl -fsSL --retry 6 --retry-delay 5 -o /tmp/mgr.tgz https://codeload.github.com/Comfy-Org/ComfyUI-Manager/tar.gz/refs/heads/main; \
      rm -rf /comfyui/custom_nodes/ComfyUI-Manager; mkdir -p /comfyui/custom_nodes/ComfyUI-Manager; \
      tar xzf /tmp/mgr.tgz -C /comfyui/custom_nodes/ComfyUI-Manager --strip-components=1; \
    }; \
    rm -rf /comfyui/custom_nodes/ComfyUI-Manager/.git /tmp/mgr.tgz; \
    if [ -f /comfyui/custom_nodes/ComfyUI-Manager/requirements.txt ]; then \
      pip install --no-cache-dir -c /tmp/constraints.txt -r /comfyui/custom_nodes/ComfyUI-Manager/requirements.txt || echo "[build] WARN Manager 依赖安装失败（不阻断）"; \
    fi; \
    test -f /comfyui/custom_nodes/ComfyUI-Manager/__init__.py; \
    find /opt/venv -name '__pycache__' -type d -prune -exec rm -rf {} + ; \
    rm -rf /root/.cache /tmp/MOSS-Image /tmp/constraints.txt

# 9) 拆层（2026-11-05 细化为按包切分）：跨境推 Harbor 时单个 2.4GB 的 nvidia 大 blob
#    只能串行上传（实测 <1MB/s，4.4GB 要 2 小时）。切成十几个 100–700MB 的小层后
#    buildkit 可并发推送，节点冷启动也能多路并发拉取。
RUN set -eux;     SP=/opt/venv/lib/python3.12/site-packages;     mkdir -p /opt/split;     for n in cublas cudnn cusparse cufft curand cusolver nccl nvjitlink nvtx cuda_runtime cuda_nvrtc cusparselt cuda_cupti nvjpeg; do       mkdir -p "/opt/split/nv_$n";       if [ -d "$SP/nvidia/$n" ]; then mv "$SP/nvidia/$n"/. "/opt/split/nv_$n"/ 2>/dev/null || true; rmdir "$SP/nvidia/$n" 2>/dev/null || true; fi;     done;     mkdir -p /opt/split/nv_rest;     if [ -d "$SP/nvidia" ]; then mv "$SP/nvidia"/. /opt/split/nv_rest/ 2>/dev/null || true; rmdir "$SP/nvidia" 2>/dev/null || true; fi;     mkdir -p /opt/split/torchlib;     if [ -d "$SP/torch/lib" ]; then mv "$SP/torch/lib" /opt/split/torchlib/lib; fi;     if [ -d "$SP/torch" ]; then mv "$SP/torch" /opt/split/torch; else mkdir -p /opt/split/torch; fi;     du -sh /opt/split/* | sort -h | tail -20

# ---------------------------------------------------------------- runtime
FROM python:3.12-slim-bookworm AS runtime
# 2026-11-05：国内构建时 pip 走阿里云镜像（ECS 内网极快）；境外构建可 --build-arg 覆盖。
ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
ENV PIP_INDEX_URL=${PIP_INDEX_URL} PIP_DISABLE_PIP_VERSION_CHECK=1

ENV DEBIAN_FRONTEND=noninteractive \
    HF_HUB_DISABLE_TELEMETRY=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH \
    TORCH_DISABLE_NATIVE_JIT=1

# 运行期系统库：
#   rsync  —— 启动时同步 /models/_code/custom_nodes 覆盖层
#   ffmpeg / libgl —— 视频类、opencv 类节点依赖
#   build-essential —— 少数节点启动时需要现场编译（Python 头文件随官方 python 镜像自带）
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      git curl wget ca-certificates rsync unzip \
      ffmpeg libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 libgomp1 \
      build-essential; \
    rm -rf /var/lib/apt/lists/*

# 只复制干净产物：venv（nvidia/torch 拆成独立层以便并行拉取）+ ComfyUI 源码
COPY --from=builder /opt/split/nv_cublas /opt/venv/lib/python3.12/site-packages/nvidia/cublas
COPY --from=builder /opt/split/nv_cudnn /opt/venv/lib/python3.12/site-packages/nvidia/cudnn
COPY --from=builder /opt/split/nv_cusparse /opt/venv/lib/python3.12/site-packages/nvidia/cusparse
COPY --from=builder /opt/split/nv_cufft /opt/venv/lib/python3.12/site-packages/nvidia/cufft
COPY --from=builder /opt/split/nv_curand /opt/venv/lib/python3.12/site-packages/nvidia/curand
COPY --from=builder /opt/split/nv_cusolver /opt/venv/lib/python3.12/site-packages/nvidia/cusolver
COPY --from=builder /opt/split/nv_nccl /opt/venv/lib/python3.12/site-packages/nvidia/nccl
COPY --from=builder /opt/split/nv_nvjitlink /opt/venv/lib/python3.12/site-packages/nvidia/nvjitlink
COPY --from=builder /opt/split/nv_nvtx /opt/venv/lib/python3.12/site-packages/nvidia/nvtx
COPY --from=builder /opt/split/nv_cuda_runtime /opt/venv/lib/python3.12/site-packages/nvidia/cuda_runtime
COPY --from=builder /opt/split/nv_cuda_nvrtc /opt/venv/lib/python3.12/site-packages/nvidia/cuda_nvrtc
COPY --from=builder /opt/split/nv_cusparselt /opt/venv/lib/python3.12/site-packages/nvidia/cusparselt
COPY --from=builder /opt/split/nv_cuda_cupti /opt/venv/lib/python3.12/site-packages/nvidia/cuda_cupti
COPY --from=builder /opt/split/nv_nvjpeg /opt/venv/lib/python3.12/site-packages/nvidia/nvjpeg
COPY --from=builder /opt/split/nv_rest /opt/venv/lib/python3.12/site-packages/nvidia
COPY --from=builder /opt/split/torch /opt/venv/lib/python3.12/site-packages/torch
COPY --from=builder /opt/split/torchlib/lib /opt/venv/lib/python3.12/site-packages/torch/lib
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /comfyui /comfyui

# 拆层后的完整性检查：少一个包就等于线上 import 失败
RUN set -eux; \
    SP=/opt/venv/lib/python3.12/site-packages; \
    test -d "$SP/torch" && test -d "$SP/nvidia"; \
    du -sh "$SP/torch" "$SP/nvidia" /opt/venv

# 把模型搜索路径指向挂载卷 /models
COPY extra_model_paths.yaml /comfyui/extra_model_paths.yaml

# 构建期启动自检：这一步失败 = 线上必然 "ComfyUI server not reachable"
RUN cd /comfyui && timeout 900 python main.py --quick-test-for-ci --cpu \
 && echo "[build] ComfyUI 启动自检通过"

# 模型下载脚本 + 清单（可选：PREPARE_MODELS=1 时启动只做下载，不启动 ComfyUI）
COPY scripts/prepare_models.py /opt/prepare_models.py
COPY config/models.json /config/models.json

# 启动入口：ComfyUI HTTP 服务（平台按端口 8188 转发）
COPY start-comfyui.sh /start-comfyui.sh
RUN chmod +x /start-comfyui.sh && du -sh /comfyui /opt/venv

# 方案 B / 三层架构（见 runpod-moss-serverless/docs/runtime-architecture.md）
# L2 覆盖层：/models/_code 下的 custom_nodes / requirements.txt / wheels / ComfyUI / config
# 会在每次启动时被 /start-comfyui.sh 组装进容器 → 换节点、换工作流、换模型都不用重建镜像。
ENV COMFY_CODE_DIR=/models/_code \
    COMFYUI_PORT=8188 \
    COMFY_AUTO_REQUIREMENTS=0
EXPOSE 8188
CMD ["/start-comfyui.sh"]
