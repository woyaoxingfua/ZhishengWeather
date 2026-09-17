# -*- coding: utf-8 -*-
"""把 design/icon-candidates/ 三张 1024x1024 候选图预处理成 iOS App Icon 要求的
不透明 RGB PNG，输出到 Assets.xcassets 的三个 appiconset。

iOS 纪律：App Store / 单尺寸 1024 图标**必须**：
  - 完全不透明（无 alpha 通道，且无任何透明像素）；
  - 正方形 1024x1024，不裁剪、不圆角（系统统一渲染圆角）。

处理步骤：
  1. 若带 alpha（RGBA / LA / P+transparency）：按图像自身的角落底色铺一层
     不透明底板再合成（候选图是整幅不透明设计的合成产物，角落即背景色）；
  2. 转 RGB、锁尺寸 1024x1024（不缩放不裁剪，只断言）；
  3. 以 PNG 无 alpha 重编码（compress_level=9，无损）；
  4. 校验：mode == RGB、size == (1024, 1024)、四角 + 中心像素 alpha 语义上不透明、
     三张图内容互不相同（md5 去重断言）。
"""
import hashlib
import io
import os

from PIL import Image

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(REPO, "design", "icon-candidates")

# 源文件 → (目标 appiconset 目录名, 对应目录)
JOBS = [
    ("iOS_app_icon__flat_minimal_des_2026-09-17T07-38-28.png",
     os.path.join(REPO, "Assets.xcassets", "AppIcon.appiconset")),
    ("iOS_app_icon__flat_minimal_des_2026-09-17T07-38-58.png",
     os.path.join(REPO, "Assets.xcassets", "AppIcon-Jade.appiconset")),
    ("iOS_app_icon__flat_minimal_des_2026-09-17T07-39-27.png",
     os.path.join(REPO, "Assets.xcassets", "AppIcon-Rain.appiconset")),
]


def convert(src_path: str, dst_dir: str) -> tuple:
    """单张图转换 + 全量断言。返回 (md5, mode, size, corners)。"""
    img = Image.open(src_path)
    assert img.size == (1024, 1024), "源图尺寸异常: %s" % (img.size,)

    if img.mode != "RGB":
        # 拿四个角的中位色做底板（候选图为纯色背景设计，四角同色）。
        rgba = img.convert("RGBA")
        corners = [rgba.getpixel(p)[:3] for p in
                   ((0, 0), (1023, 0), (0, 1023), (1023, 1023))]
        bg = tuple(sorted(c)[1] for c in zip(*corners))  # 逐通道中位数
        base = Image.new("RGBA", rgba.size, bg + (255,))
        base.alpha_composite(rgba)
        img = base.convert("RGB")

    assert img.mode == "RGB", "转换后仍非 RGB: %s" % img.mode
    assert img.size == (1024, 1024), "转换后尺寸漂移: %s" % (img.size,)

    os.makedirs(dst_dir, exist_ok=True)
    dst_path = os.path.join(dst_dir, "AppIcon1024.png")
    img.save(dst_path, format="PNG", compress_level=9)

    # 复检：重新读盘验证（不信任内存对象）。
    check = Image.open(dst_path)
    assert check.mode == "RGB", "落盘后 mode=%s" % check.mode
    assert check.size == (1024, 1024), "落盘后 size=%s" % (check.size,)
    corners = [check.getpixel(p) for p in
               ((0, 0), (1023, 0), (0, 1023), (1023, 1023), (512, 512))]
    for c in corners:
        assert isinstance(c, tuple) and len(c) == 3, "落盘后像素非 RGB 三元组: %r" % (c,)

    with open(dst_path, "rb") as fh:
        digest = hashlib.md5(fh.read()).hexdigest()
    return digest, check.mode, check.size, corners[:4]


def main() -> None:
    digests = {}
    for src, dst in JOBS:
        digest, mode, size, corners = convert(os.path.join(SRC_DIR, src), dst)
        digests[digest] = src
        print("OK  %s -> %s  md5=%s mode=%s size=%s corners=%s"
              % (src, os.path.relpath(dst, REPO), digest, mode, size, corners))
    # 三张图内容必须互不相同（md5 去重断言）。
    assert len(digests) == len(JOBS), "存在内容完全相同的图（md5 撞车），请人工核对"


if __name__ == "__main__":
    main()
