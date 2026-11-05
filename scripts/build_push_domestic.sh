#!/usr/bin/env bash
# 在国内机器上构建并推送 moss-image-build 到共绩 Harbor。
# 用法：
#   export REG_USER=yiliankexi
#   export REG_PASSWORD='<Harbor 密码>'
#   bash scripts/build_push_domestic.sh
# 可选：REG / NS / NAME / TAG / PUSH_LATEST
set -euo pipefail

REG=${REG:-harborpush.suanleme.cn}
NS=${NS:-yiliankexi}
NAME=${NAME:-moss-image-build}
TAG=${TAG:-$(git rev-parse --short HEAD)}
PUSH_LATEST=${PUSH_LATEST:-1}

: "${REG_USER:?需要 REG_USER}"
: "${REG_PASSWORD:?需要 REG_PASSWORD}"

IMAGE="$REG/$NS/$NAME"

echo "[1/4] 环境检查"
docker version >/dev/null || { echo "docker 不可用"; exit 1; }
df -h . | tail -1
FREE_GB=$(df -BG --output=avail . | tail -1 | tr -dc '0-9')
[ "$FREE_GB" -ge 20 ] || { echo "磁盘不足 20GB（当前 ${FREE_GB}GB）"; exit 1; }

echo "[2/4] 登录 $REG"
echo "$REG_PASSWORD" | docker login "$REG" -u "$REG_USER" --password-stdin

echo "[3/4] 构建 $IMAGE:$TAG（约 15–25 分钟，torch/cuda 下载）"
DOCKER_BUILDKIT=1 docker build --progress=plain -t "$IMAGE:$TAG" .

echo "[4/4] 推送（国内上行，4–8 分钟）"
docker push "$IMAGE:$TAG"
if [ "$PUSH_LATEST" = "1" ]; then
  docker tag "$IMAGE:$TAG" "$IMAGE:latest"
  docker push "$IMAGE:latest"
fi

echo "完成：$IMAGE:$TAG"
echo "下一步：共绩控制台 → 镜像仓库命中 latest → 任务里恢复，首次拉取约 5–8 分钟"
