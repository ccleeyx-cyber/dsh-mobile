#!/usr/bin/env python3
"""从一张 1024×1024 母版图生成 iOS AppIcon 全套尺寸。

用法：
    python3 scripts/make-ios-app-icons.py
    python3 scripts/make-ios-app-icons.py --source dsh_mobile/assets/branding/app-icon-1024.png

## 为什么要有这个脚本

`make-app-icons.ps1` 只覆盖 Android（5 档 mipmap），iOS 需要另一套完全不同尺寸的
图（20/29/40/60/76/83.5 各 @1x/@2x/@3x + 1024 商店图），而且规则更严：

1. **不能有 alpha 通道**。带透明度的 PNG 提交 App Store 会被直接拒
   （"Invalid Image - The app icon set has an unassigned child" / alpha 通道警告）。
   母版若是 RGBA，这里会先合成到不透明白底上再输出。
2. **不要把圆角烘进图里**。iOS 自己裁 squircle，预烘圆角会在边缘露出一圈锯齿。
   母版按"满幅正方形 + 四周留白"的约定即可。
3. **尺寸必须与 Contents.json 精确对应**。缺任何一个尺寸，Xcode 只在 archive 时
   才报错（"None of the input catalogs contained a matching app icon set"），
   平时 `flutter build` 看不出来 —— 所以这里按 Contents.json 的清单逐项生成，
   生成完就地校验一遍。

为什么不用 `flutter_launcher_icons`：本项目只换图标这一件事，为它引一个构建期
依赖不划算，与 `make-app-icons.ps1` 的取舍一致（见那边的注释）。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = ROOT / "dsh_mobile/assets/branding/app-icon-1024.png"
ICONSET = ROOT / "dsh_mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset"

# Contents.json 里的 idiom -> (pt 尺寸, scale) 与输出像素边长的换算：
# pixel = pt * scale。下面这张表就是 Contents.json 的镜像，改一边必须改另一边
# （脚本末尾会用 Contents.json 反查校验，对不上就报错）。
SPECS = [
    ("iphone", 20, 2, 40),
    ("iphone", 20, 3, 60),
    ("iphone", 29, 1, 29),
    ("iphone", 29, 2, 58),
    ("iphone", 29, 3, 87),
    ("iphone", 40, 2, 80),
    ("iphone", 40, 3, 120),
    ("iphone", 60, 2, 120),
    ("iphone", 60, 3, 180),
    ("ipad", 20, 1, 20),
    ("ipad", 20, 2, 40),
    ("ipad", 29, 1, 29),
    ("ipad", 29, 2, 58),
    ("ipad", 40, 1, 40),
    ("ipad", 40, 2, 80),
    ("ipad", 76, 1, 76),
    ("ipad", 76, 2, 152),
    ("ipad", 83.5, 2, 167),
    ("ios-marketing", 1024, 1, 1024),
]


def filename(pt: float, scale: int) -> str:
    """与 flutter create / Xcode 默认命名一致：Icon-App-<pt>x<pt>@<scale>x.png。

    83.5 这种小数保持原样（Xcode 模板就是这么写的）。
    """
    return f"Icon-App-{pt:g}x{pt:g}@{scale}x.png"


def flatten(img: Image.Image) -> Image.Image:
    """去掉 alpha：合成到白底上，输出 RGB。

    白底而不是黑底：图标母版四周是留白，白底能保住"干净"的观感；
    黑底会在母版的浅色边缘产生一圈脏边。
    """
    if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
        rgba = img.convert("RGBA")
        canvas = Image.new("RGB", rgba.size, (255, 255, 255))
        canvas.paste(rgba, mask=rgba.split()[-1])
        return canvas
    return img.convert("RGB")


def main() -> int:
    ap = argparse.ArgumentParser(description="生成 iOS AppIcon 全套尺寸")
    ap.add_argument("--source", default=str(DEFAULT_SOURCE), help="1024×1024 母版图路径")
    args = ap.parse_args()

    src_path = Path(args.source)
    if not src_path.is_absolute():
        src_path = ROOT / src_path
    if not src_path.exists():
        print(f"找不到母版图：{src_path}", file=sys.stderr)
        return 1

    master = Image.open(src_path)
    if master.width != master.height:
        print(f"母版图必须是正方形，当前 {master.width}x{master.height}", file=sys.stderr)
        return 1
    if master.width < 1024:
        print(f"母版图边长应不小于 1024，当前 {master.width}", file=sys.stderr)
        return 1

    # 统一先转成"去 alpha 的 RGB"，再逐级缩小。
    # 用 LANCZOS：缩小图标时 EDGE 之类会糊，而 NEAREST 会有锯齿。
    flat = flatten(master)

    ICONSET.mkdir(parents=True, exist_ok=True)
    written: list[tuple[str, int]] = []
    for _idiom, pt, scale, px in SPECS:
        out = ICONSET / filename(pt, scale)
        flat.resize((px, px), Image.LANCZOS).save(out, format="PNG", optimize=True)
        written.append((out.name, px))

    # 校验：Contents.json 里引用的每个文件名都得真的存在，且像素边长对得上。
    contents_path = ICONSET / "Contents.json"
    if contents_path.exists():
        contents = json.loads(contents_path.read_text(encoding="utf-8"))
        missing, wrong = [], []
        for entry in contents.get("images", []):
            name = entry.get("filename")
            if not name:
                continue
            f = ICONSET / name
            if not f.exists():
                missing.append(name)
                continue
            pt = float(entry["size"].split("x")[0])
            scale = int(entry["scale"].rstrip("x"))
            expect = round(pt * scale)
            with Image.open(f) as im:
                if im.size != (expect, expect):
                    wrong.append(f"{name}: {im.size[0]}px ≠ {expect}px")
                if im.mode != "RGB":
                    wrong.append(f"{name}: mode={im.mode}（必须是不带 alpha 的 RGB）")
        if missing:
            print(f"Contents.json 引用了但没生成：{missing}", file=sys.stderr)
            return 1
        if wrong:
            print("尺寸/格式不对：" + "; ".join(wrong), file=sys.stderr)
            return 1

    print(f"已生成 {len(written)} 个图标到 {ICONSET.relative_to(ROOT)}：")
    for name, px in written:
        print(f"  {px:>4}px  {name}")
    print("校验通过：Contents.json 引用的尺寸全部存在、无 alpha 通道。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
