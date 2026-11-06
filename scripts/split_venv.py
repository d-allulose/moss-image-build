"""把 venv 的 site-packages 按体积切成 N 个桶（默认 8，每桶目标 ≤ ~450MB）。

上一版按「顶层条目」贪心均分，遇到单个巨型包（v01 2.7GB）就失效了——一个桶里塞着
一个 2.7GB 的目录，跨境推送照样只能串行。这一版会**递归拆开超大条目**：只要某个
条目超过 target*1.2，就下潜到它的子目录，直到每块都接近 target。

每个条目的相对路径会保留，runtime 阶段用 N 条
`COPY --from=builder /opt/split/vNN/ /opt/venv/lib/python3.12/site-packages/`
合并回原树，最终目录结构与拆分前逐字节一致。
"""

from __future__ import annotations

import os
import shutil
import sys

SP = "/opt/venv/lib/python3.12/site-packages"
DST = "/opt/split"
N = int(os.environ.get("SPLIT_BUCKETS", "8"))
TARGET = int(os.environ.get("SPLIT_TARGET_MB", "450")) * 1024 * 1024


def dir_size(path: str) -> int:
    if os.path.isfile(path) or os.path.islink(path):
        try:
            return os.path.getsize(path)
        except OSError:
            return 0
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return total


def collect(rel: str, size: int, out: list[tuple[str, int]], depth: int = 0) -> None:
    """把条目 rel 拆到 <= TARGET*1.2 的粒度，写进 out[(相对路径, 大小)]。"""
    abs_path = os.path.join(SP, rel)
    limit = TARGET * 1.2
    if size <= limit or not os.path.isdir(abs_path) or depth > 6:
        out.append((rel, size))
        return

    children = []
    for name in sorted(os.listdir(abs_path)):
        child_rel = os.path.join(rel, name)
        children.append((child_rel, dir_size(os.path.join(SP, child_rel))))
    if not children:
        out.append((rel, size))
        return

    for child_rel, child_size in children:
        collect(child_rel, child_size, out, depth + 1)


def split_torchlib(parts: int = 4) -> None:
    """torch/lib 单独一刀：946MB 的 .so 集合拆成 4 块 ~240MB。"""
    lib_dir = "/opt/split/torchlib/lib"
    if not os.path.isdir(lib_dir):
        print("[split] 无 torchlib，跳过")
        return
    files = []
    for name in sorted(os.listdir(lib_dir)):
        path = os.path.join(lib_dir, name)
        if os.path.isdir(path):
            files.append((name, dir_size(path)))
        else:
            try:
                files.append((name, os.path.getsize(path)))
            except OSError:
                files.append((name, 0))
    files.sort(key=lambda x: x[1], reverse=True)
    buckets: list[list[str]] = [[] for _ in range(parts)]
    sizes = [0] * parts
    for name, size in files:
        k = sizes.index(min(sizes))
        buckets[k].append(name)
        sizes[k] += size
    for i, names in enumerate(buckets, 1):
        target = f"/opt/split/tl{i:02d}"
        os.makedirs(target, exist_ok=True)
        for name in names:
            shutil.move(os.path.join(lib_dir, name), os.path.join(target, name))
        print(f"[split] tl{i:02d} {sizes[i - 1] / 1e6:.0f} MB files={len(names)}")


def main() -> int:
    if not os.path.isdir(SP):
        print(f"[split] site-packages 不存在: {SP}", file=sys.stderr)
        return 1

    items: list[tuple[str, int]] = []
    for name in sorted(os.listdir(SP)):
        rel = name
        collect(rel, dir_size(os.path.join(SP, rel)), items)

    items.sort(key=lambda x: x[1], reverse=True)
    total = sum(size for _rel, size in items)
    print(f"[split] 待分 {len(items)} 块 / {total / 1e9:.2f} GB / target {TARGET / 1e6:.0f} MB")

    buckets: list[list[tuple[str, int]]] = [[] for _ in range(N)]
    sizes = [0] * N
    for rel, size in items:
        k = sizes.index(min(sizes))
        buckets[k].append((rel, size))
        sizes[k] += size

    os.makedirs(DST, exist_ok=True)
    for i, entries in enumerate(buckets, 1):
        target_dir = os.path.join(DST, f"v{i:02d}")
        os.makedirs(target_dir, exist_ok=True)
        for rel, _size in entries:
            src = os.path.join(SP, rel)
            dst = os.path.join(target_dir, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.move(src, dst)
        print(f"[split] v{i:02d} {sizes[i - 1] / 1e6:.0f} MB items={len(entries)}")

    split_torchlib(4)

    # 搬走子目录后父目录会留下空壳（triton/、nvidia/ 这种），递归清掉空目录；
    # 只要还剩真实文件才算漏包。
    for root, dirs, files in os.walk(SP, topdown=False):
        if os.path.abspath(root) == os.path.abspath(SP):
            continue
        if not dirs and not files:
            try:
                os.rmdir(root)
            except OSError:
                pass

    left = os.listdir(SP)
    if left:
        leftover_bytes = sum(dir_size(os.path.join(SP, n)) for n in left)
        print(f"[split] site-packages 残留 {len(left)} 项 / {leftover_bytes / 1e6:.1f} MB: {left[:8]}")
        if leftover_bytes > 0:
            print("[split] 仍有非空残留，构建会漏包", file=sys.stderr)
            return 2
    else:
        print("[split] site-packages 已清空，全部进桶")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
