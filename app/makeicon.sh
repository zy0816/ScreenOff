#!/bin/bash
# 生成 AppIcon.icns：圆角矩形底 + SF Symbol 的笔记本图形。
# 用系统自带的 python3（带 PyObjC）渲染，不需要额外依赖。
set -euo pipefail

OUT="${1:?用法: makeicon.sh <输出.icns>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

/usr/bin/python3 - "$ICONSET" <<'PY'
import sys
from AppKit import (
    NSBitmapImageRep, NSGraphicsContext, NSColor, NSBezierPath, NSImage,
    NSImageSymbolConfiguration, NSCalibratedRGBColorSpace, NSGradient,
    NSCompositingOperationSourceOver, NSCompositingOperationSourceIn,
    NSMakeRect, NSMakePoint, NSFontWeightRegular,
)

iconset = sys.argv[1]

# macOS 图标：圆角矩形（squircle 近似），四周留白，图形占 ~80%
CORNER_RATIO = 0.2237
INSET_RATIO = 0.098
GLYPH_RATIO = 0.46          # 符号相对整幅画布的高度

TOP = NSColor.colorWithSRGBRed_green_blue_alpha_(0.298, 0.353, 0.427, 1.0)
BOTTOM = NSColor.colorWithSRGBRed_green_blue_alpha_(0.129, 0.161, 0.204, 1.0)


def symbol_image(point_size):
    img = NSImage.imageWithSystemSymbolName_accessibilityDescription_("laptopcomputer", None)
    if img is None:
        return None
    cfg = NSImageSymbolConfiguration.configurationWithPointSize_weight_scale_(
        point_size, NSFontWeightRegular, 1
    )
    # 直接让符号以白色渲染，省得再做一层 SourceIn 染色
    white = NSImageSymbolConfiguration.configurationWithHierarchicalColor_(NSColor.whiteColor())
    return img.imageWithSymbolConfiguration_(cfg.configurationByApplyingConfiguration_(white))


def render(size):
    rep = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, size, size, 8, 4, True, False, NSCalibratedRGBColorSpace, 0, 0
    )
    ctx = NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.setCurrentContext_(ctx)

    inset = size * INSET_RATIO
    box = NSMakeRect(inset, inset, size - inset * 2, size - inset * 2)
    radius = box.size.width * CORNER_RATIO
    shape = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(box, radius, radius)

    NSGradient.alloc().initWithStartingColor_endingColor_(TOP, BOTTOM).drawInBezierPath_angle_(shape, -90.0)

    glyph = symbol_image(size * GLYPH_RATIO)
    if glyph is not None:
        gw, gh = glyph.size().width, glyph.size().height
        # 视觉重心略高于几何中心，看起来才是居中的
        rect = NSMakeRect((size - gw) / 2.0, (size - gh) / 2.0 + size * 0.012, gw, gh)
        glyph.drawInRect_fromRect_operation_fraction_(
            rect, ((0, 0), (0, 0)), NSCompositingOperationSourceOver, 1.0
        )

    NSGraphicsContext.restoreGraphicsState()
    return rep


def write(rep, name):
    data = rep.representationUsingType_properties_(4, {})  # 4 = PNG
    data.writeToFile_atomically_(f"{iconset}/{name}", True)


for base in (16, 32, 128, 256, 512):
    write(render(base), f"icon_{base}x{base}.png")
    write(render(base * 2), f"icon_{base}x{base}@2x.png")
print("iconset ok")
PY

iconutil -c icns "$ICONSET" -o "$OUT"
