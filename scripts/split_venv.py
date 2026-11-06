"""把 venv 的 site-packages 顶层条目按体积均分成 N 个桶（默认 8）。

用途：Docker 镜像里 /opt/venv 整体 COPY 会生成一个 3.4GB 的大层，跨境推送和节点回源
都只能串行。按桶拆开后，每层 300-600MB，push/pull 都能并发。

在 builder 阶段执行（/opt/venv 已装好、nvidia/torch 已被前面的步骤搬走），
把剩余的顶层条目 move 到 /opt/split/v01 ... /opt/split/vNN，
runtime 阶段再用 N 条 COPY 合并回 /opt/venv/lib/python3.12/site-packages。
"""

from __future__ import annotations

import os
import shutil
import sys

SP = "/opt/venv/lib/python3.12/site-packages"
DST = "/opt/split"
N = int(os.environ.get("SPLIT_BUCKETS", "8"))


def entry_size(path: str) -> int:
    if os.path.isfile(path):
        return os.path.getsize(path)
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return total


def main() -> int:
    if not os.path.isdir(SP):
        print(f"[split] site-packages 不存在: {SP}", file=sys.stderr)
        return 1

    entries = []
    for name in sorted(os.listdir(SP)):
        path = os.path.join(SP, name)
        entries.append((entry_size(path), name))
    entries.sort(reverse=True)

    buckets: list[list[str]] = [[] for _ in range(N)]
    sizes = [0] * N
    for size, name in entries:
        k = sizes.index(min(sizes))
        sizes[k] += size
        buckets[k].append(name)

    os.makedirs(DST, exist_ok=True)
    for i, names in enumerate(buckets, 1):
        target = os.path.join(DST, f"v{i:02d}")
        os.makedirs(target, exist_ok=True)
        for name in names:
            shutil.move(os.path.join(SP, name), os.path.join(target, name))
        print(f"[split] v{i:02d} {sizes[i - 1] / 1e6:.0f} MB entries={len(names)}")

    left = os.listdir(SP)
    print(f"[split] site-packages 残留 {len(left)} 项: {left[:8]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
