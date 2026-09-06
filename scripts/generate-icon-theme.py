#!/usr/bin/env python3
"""预生成多尺寸应用图标，装入 configs/icon-theme/hicolor。

桌面图标发虚的根因是 .desktop 用绝对路径引用单张大 PNG，GTK 每次渲染都要
实时降采样。本脚本按 freedesktop 规范预渲染出各尺寸 PNG，配合 .desktop 里
的裸图标名引用，彻底消除运行时缩放。

仅开发期在宿主机运行（依赖 Pillow），产物提交入库，构建期零额外依赖。

    python3 scripts/generate-icon-theme.py
"""

import shutil
import sys
from pathlib import Path

try:
    from PIL import Image, ImageFilter
except ImportError:
    sys.exit("需要 Pillow：pip3 install Pillow")

REPO = Path(__file__).resolve().parent.parent
SOURCE_DIRS = [REPO / "configs/on-demand-icons", REPO / "configs/desktop-icons"]
OUT = REPO / "configs/icon-theme/hicolor"

SIZES = (24, 32, 48, 64, 128, 256)
# places/symbolic 图标由 WebClaw 主题负责，不属于应用图标
SKIP = {"home", "trash", "ai-tools-symbolic", "social-tools-symbolic"}
# 小尺寸降采样后边缘偏软，补一点锐化把色块边界拉实
SHARPEN_MAX_SIZE = 64
SHARPEN = ImageFilter.UnsharpMask(radius=0.6, percent=70, threshold=0)


def collect_sources():
    """按图标名收集源文件。

    同名同时存在 .png 和 .svg 时取 .png —— 现有 .desktop 引用的就是 .png，
    换成 .svg 可能是另一套画法，会改变外观。
    """
    found = {}
    for directory in SOURCE_DIRS:
        for suffix in (".png", ".svg"):
            for path in sorted(directory.glob(f"*{suffix}")):
                if path.stem not in found and path.stem not in SKIP:
                    found[path.stem] = path
    return found


def render_png(src, name):
    image = Image.open(src).convert("RGBA")
    longest = max(image.size)
    written = 0
    for size in SIZES:
        # 绝不放大：源图撑不到的尺寸直接跳过，让主题回退到更小的那一档
        if size > longest:
            continue
        scaled = image.resize((size, size), Image.LANCZOS)
        if size <= SHARPEN_MAX_SIZE:
            scaled = scaled.filter(SHARPEN)
        target = OUT / f"{size}x{size}/apps/{name}.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        scaled.save(target, "PNG", optimize=True)
        written += 1
    return written


def main():
    if OUT.exists():
        shutil.rmtree(OUT)

    total = 0
    for name, src in collect_sources().items():
        if src.suffix.lower() == ".svg":
            target = OUT / f"scalable/apps/{name}.svg"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, target)
            print(f"{name:32s} scalable (svg)")
            total += 1
            continue
        written = render_png(src, name)
        print(f"{name:32s} {written} 个尺寸")
        total += written

    print(f"\n共生成 {total} 个图标文件 → {OUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
