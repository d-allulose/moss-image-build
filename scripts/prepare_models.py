#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""镜像构建时把模型拉到 ComfyUI 的 models/ 目录。

为什么在构建期拉：Runpod 的构建机直连 HF/Civitai（出入境流量免费、速度远超家里 33.6Mbps），
而且权重会被烘进镜像，worker 冷启动时不用再等下载。

用法（Dockerfile 里调用）：
  CIVITAI_API_KEY=xxx python /tmp/stage_models.py --config /tmp/deck.json --dest /comfyui/models

条目支持两种来源：
  1) HuggingFace：{ "repo": "Comfy-Org/MOSS-Image", "file": "text_encoders/x.safetensors" }
  2) 直链：      { "url": "https://civitai.com/api/download/models/3422319?fileId=3316568",
                  "auth_env": "CIVITAI_API_KEY" }   # 有该环境变量就拼 ?token= 查询参数

路径约定：deck.json 里 downloads[].dest 是「相对 ComfyUI 根目录」的路径
（形如 models/diffusion_models/xxx.safetensors），脚本内部会自动消掉开头的 models/，
落到 --dest 指定的 models 目录下。历史上这两层拼接过一次导致镜像里出现
/comfyui/models/models/...，构建期断言随即失败，这里已修正并做越界检查。

校验（对每个文件，下载完成后）：
  - 大小下限（size_gb 的 90%，防下到 HTML 错误页）
  - safetensors 头部结构（前 8 字节 LE 头长度 + JSON 头），防下到登录页/JSON 错误
  - 可选 sha256（deck.json 里写了 sha256 就强校验）

可选环境变量：
  HF_ENDPOINT=https://hf-mirror.com   国内镜像（构建机在境外时不要设）
  HF_TOKEN=...                        需要鉴权的 HF 仓库才用得到
  CIVITAI_API_KEY=...                 Civitai 直链下载（deck.json 条目里 auth_env 指定变量名）
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import struct
import sys
import urllib.parse
import urllib.request
from pathlib import Path

UA = "moss-serverless-stager/1.1"


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}TB"


def hf_url(repo: str, file: str) -> str:
    endpoint = os.environ.get("HF_ENDPOINT", "https://huggingface.co").rstrip("/")
    return f"{endpoint}/{repo}/resolve/main/{file}"


def resolve_dest(dest_root: Path, rel: str) -> Path:
    """把 deck.json 里「相对 ComfyUI 根」的 dest 解析成真实路径。

    rel 形如 models/diffusion_models/x.safetensors；dest_root 是 .../models。
    """
    rel = rel.replace("\\\\", "/").lstrip("/")
    if rel.startswith("models/"):
        rel = rel[len("models/") :]
    return dest_root / rel


def auth_token(item: dict) -> str:
    """从 deck 条目声明的环境变量里取 token（不回显 token）。"""
    env_name = item.get("auth_env")
    if not env_name:
        return ""
    token = os.environ.get(env_name, "").strip()
    if not token:
        raise RuntimeError(f"缺少鉴权：环境变量 {env_name} 为空（deck.json 里声明了 auth_env）")
    return token


def with_auth_query(url: str, item: dict) -> str:
    """把 Civitai token 拼成 ?token= 查询参数。

    实测（2026-10-26）：token 放 Authorization 头时，urllib 会把这个头一起带到
    307 跳转后的 R2 预签名地址，S3 收到「额外鉴权机制」直接 400 Bad Request；
    放查询参数则由 Civitai 在跳转前消费掉，R2 只看到预签名参数，正常 200。
    """
    token = auth_token(item)
    if not token:
        return url
    sep = "&" if "?" in url else "?"
    return f"{url}{sep}token={urllib.parse.quote(token, safe='')}"


def download_stream(url: str, dest: Path, expected_gb: float | None = None, headers: dict | None = None) -> int:
    """流式下载到 dest.part（支持断点续传），完成后原子改名。返回字节数。"""
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    have = part.stat().st_size if part.exists() else 0
    hdrs = {"User-Agent": UA}
    hdrs.update(headers or {})
    req = urllib.request.Request(url, headers=hdrs)
    if have:
        req.add_header("Range", f"bytes={have}-")
    print(f"  GET {url}" + (f"  （续传 {human(have)}）" if have else ""), flush=True)
    with urllib.request.urlopen(req, timeout=180) as r, part.open("ab") as f:
        total = r.headers.get("Content-Length")
        total = int(total) + have if total else None
        done = have
        while True:
            chunk = r.read(1024 * 1024 * 8)
            if not chunk:
                break
            f.write(chunk)
            done += len(chunk)
            if total:
                print(f"\r    {human(done)} / {human(total)} ({done / total:5.1%})", end="", flush=True)
    print(flush=True)
    size = part.stat().st_size
    if total and size < total:
        raise IOError(f"下载不完整：{human(size)} / {human(total)}（保留 .part 便于续传）")
    if expected_gb and size < expected_gb * 1024 ** 3 * 0.9:
        raise IOError(f"文件偏小：{human(size)}，期望约 {expected_gb:.1f}GB —— 多半下到了错误页")
    part.replace(dest)
    return size


def check_safetensors(path: Path) -> None:
    """校验 safetensors 头：8 字节小端头长 + JSON（以 '{' 开头）。失败抛异常。"""
    with path.open("rb") as f:
        raw = f.read(8)
        if len(raw) != 8:
            raise IOError("文件小于 8 字节，不是 safetensors")
        (n,) = struct.unpack("<Q", raw)
        if not (2 <= n <= 200_000_000):
            raise IOError(f"safetensors 头长度异常：{n}（可能下到了 HTML/JSON 错误页）")
        head = f.read(n)
    if not head.lstrip().startswith(b"{"):
        raise IOError(f"safetensors 头不是 JSON：{head[:60]!r}")


def verify_sha256(path: Path, expected: str) -> None:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(16 * 1024 * 1024), b""):
            h.update(chunk)
    got = h.hexdigest()
    if got.lower() != expected.lower():
        raise IOError(f"sha256 不匹配：期望 {expected}，实际 {got}")


def download_hf(repo: str, file: str, dest: Path) -> None:
    """退路：用 huggingface_hub（会先落 cache 再拷贝，占双倍磁盘，只在流式失败时用）。"""
    from huggingface_hub import hf_hub_download

    dest.parent.mkdir(parents=True, exist_ok=True)
    cached = hf_hub_download(
        repo_id=repo,
        filename=file,
        token=os.environ.get("HF_TOKEN") or None,
        cache_dir="/tmp/hf-cache",
    )
    tmp = dest.with_suffix(dest.suffix + ".part")
    shutil.copyfile(cached, tmp)
    tmp.replace(dest)


def main() -> int:
    ap = argparse.ArgumentParser(description="把模型下载到 ComfyUI models/ 目录")
    ap.add_argument("--config", required=True, help="deck.json（含 downloads 列表）")
    ap.add_argument("--dest", required=True, help="ComfyUI 的 models 目录")
    ap.add_argument("--check", action="store_true", help="只打印清单，不下载")
    args = ap.parse_args()

    cfg = json.loads(Path(args.config).read_text(encoding="utf-8"))
    downloads = cfg.get("downloads") or []
    if not downloads:
        print("[stage] deck.json 里没有 downloads，跳过")
        return 0

    dest_root = Path(args.dest)
    total_gb = sum(float(d.get("size_gb") or 0) for d in downloads)
    print(f"[stage] 共 {len(downloads)} 个文件，约 {total_gb:.1f}GB，目标 {dest_root}")
    try:
        free = shutil.disk_usage(dest_root if dest_root.exists() else dest_root.parent).free
        print(f"[stage] 构建机剩余磁盘：{human(free)}")
    except Exception as e:  # 只做提示
        print(f"[stage] 无法读取磁盘信息：{e}")

    failed = []
    for d in downloads:
        repo, file, rel = d.get("repo"), d.get("file"), d["dest"]
        label = f"{repo}/{file}" if repo else d.get("url", "?")
        dest = resolve_dest(dest_root, rel)
        try:
            dest.resolve().relative_to(dest_root.resolve())
        except ValueError:
            print(f"[stage] 跳过非法目标（越界）：{rel}")
            failed.append(rel)
            continue
        if dest.exists() and dest.stat().st_size > 1024 * 1024:
            print(f"[stage] 已存在，跳过：{rel}（{human(dest.stat().st_size)}）")
            continue
        if args.check:
            print(f"[stage] 待下载 {label} → {rel}")
            continue
        print(f"[stage] {label} → {rel}")
        try:
            url = d.get("url") or hf_url(repo, file)
            url = with_auth_query(url, d)
            download_stream(url, dest, d.get("size_gb"))
            check_safetensors(dest)
            if d.get("sha256"):
                verify_sha256(dest, d["sha256"])
                print("[stage] sha256 ✓")
            print(f"[stage] 完成 {rel}（{human(dest.stat().st_size)}）")
        except Exception as e:
            print(f"[stage] 下载失败 {label}: {e}")
            if repo:
                print("[stage] 换 huggingface_hub 兜底")
                try:
                    download_hf(repo, file, dest)
                    check_safetensors(dest)
                    if d.get("sha256"):
                        verify_sha256(dest, d["sha256"])
                    print(f"[stage] 完成（hf 兜底）{rel}（{human(dest.stat().st_size)}）")
                except Exception as e2:
                    print(f"[stage] 失败 {label}: {e2}")
                    failed.append(label)
            else:
                failed.append(label)

    if failed:
        print("[stage] 以下文件下载失败：")
        for f in failed:
            print("   -", f)
        return 1
    print("[stage] 全部就绪")
    return 0


if __name__ == "__main__":
    sys.exit(main())
