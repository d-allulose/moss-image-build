# moss-image-build

MOSS-Image 的**薄镜像**构建：只含运行环境（ComfyUI 固定提交 + MOSS-Image 节点 + torch cu130），
**不含模型权重**。配合 GPU 云的挂载卷（权重放 `/models`）使用，适合按秒计费的平台（如共绩算力）。

## 为什么需要它

- 权重（约 31GB）不进镜像 → 镜像小、拉取快、无模型许可再分发问题；
- ComfyUI v0.41.0 tag 不支持 MOSS-Image，必须用固定 master 提交（构建期有断言）；
- torch 必须 cu130 以上，否则 ComfyUI 会关掉 comfy_kitchen 的 CUDA 优化后端（每步慢约 3 倍）。

## 镜像内容

| 组件 | 版本 |
|---|---|
| ComfyUI | master 提交 `5cc4b87…`（含 `CLIPType.MOSS_IMAGE`） |
| torch / torchvision | 2.13.0+cu130 / 0.28.0+cu130 |
| transformers | 5.14.1 |
| MOSS-Image 节点 | 上游 `OpenMOSS/MOSS-Image` 的 `comfyui/moss-image` |
| 端口 | 8188（ComfyUI HTTP API） |

## 构建

推送到本仓库 `main` 分支即由 GitHub Actions 构建并推送：

```
ghcr.io/<owner>/<repo>:latest
ghcr.io/<owner>/<repo>:<sha>
```

首次推送后需在 GitHub 仓库/包的设置里把镜像可见性改为 **public**，云平台才能匿名拉取。

## 使用

1. 平台挂载存储卷到 `/models`，目录：

```
/models/
  diffusion_models/   # 底模 safetensors
  text_encoders/      # qwen3.5_9b_bf16.safetensors 等
  vae/                # flux2-vae.safetensors
  loras/              # 加速 LoRA + 风格 LoRA（可放子目录）
```

2. 一次性任务把权重下载进卷（支持 Hugging Face 与 Civitai 鉴权）：

```bash
python scripts/prepare_models.py --config config/models.json --dest /models
# Civitai 直链需要：export CIVITAI_API_KEY=...
```

3. 用本镜像新建部署任务：端口填 `8188`，挂载卷到 `/models`，启动即 ComfyUI HTTP 服务。

## 许可

自有代码 MIT（见 LICENSE）；镜像内含第三方组件，见 NOTICE。不含模型权重。
