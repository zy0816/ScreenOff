#!/usr/bin/env python3
"""
displaytoggle — 在接了外置显示器时，开关 Mac 内建屏幕。

用 CoreGraphics / SkyLight 的私有显示配置接口：

    CGSGetDisplayList              列出全部显示器槽位（含被禁用的）
    CGSBeginDisplayConfiguration   (== CGBeginDisplayConfiguration)
    CGSConfigureDisplayEnabled     公开 API 没有对应物
    CGSCompleteDisplayConfiguration

不需要 root，不需要辅助功能权限，不动系统设置里的镜像/排列。

要点：内建屏一旦被禁用，就从公开的 CGGetOnlineDisplayList 里消失了
（CGDisplayIsOnline 变 0，连 CGDisplayCreateUUIDFromDisplayID 都返回 NULL），
只有私有的 CGSGetDisplayList 还留着它的槽位，而 CGDisplayIsBuiltin 对
已禁用的槽位依然有效 —— 这是能把屏幕开回来的关键。

注意这个结论只在「还有别的屏亮着」时成立：物理屏全部消失时，内建屏的槽位
也会一起消失，系统还会插入一块虚拟屏（vendor/model = "unkn"/"virt"）冒充。
菜单栏 App 为此持久化了 display ID 并做了三级恢复；命令行版是一次性命令，
只保证不把虚拟屏误当成真屏。

用法:
    displaytoggle.py                # 切换内建屏
    displaytoggle.py --status       # 只列出显示器状态
    displaytoggle.py --off / --on
    displaytoggle.py --permanent    # 重启后保留（默认只对本次登录会话生效）
    displaytoggle.py --force        # 没有其它可用屏时也允许关（会黑屏，慎用）
"""

from __future__ import annotations

import argparse
import ctypes
import sys
import time

# ---------------------------------------------------------------- 绑定

_CG_PATH = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
_SL_PATH = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

_REQUIRED = ("CGSGetDisplayList", "CGSBeginDisplayConfiguration",
             "CGSConfigureDisplayEnabled", "CGSCompleteDisplayConfiguration")


def _load() -> ctypes.CDLL:
    missing: list[str] = []
    for path in (_SL_PATH, _CG_PATH):
        try:
            lib = ctypes.CDLL(path)
        except OSError:
            continue
        missing = [s for s in _REQUIRED if not hasattr(lib, s)]
        if not missing:
            return lib
    raise SystemExit(
        "找不到需要的私有符号 (%s) —— 这个系统版本可能挪走或删掉了它们。"
        % ", ".join(missing or _REQUIRED)
    )


_lib = _load()

CGDirectDisplayID = ctypes.c_uint32
CGDisplayConfigRef = ctypes.c_void_p
CGError = ctypes.c_int32

_lib.CGSGetDisplayList.argtypes = [
    ctypes.c_uint32,
    ctypes.POINTER(CGDirectDisplayID),
    ctypes.POINTER(ctypes.c_uint32),
]
_lib.CGSGetDisplayList.restype = CGError

# 必须显式声明签名：display ID 是不透明的 uint32，某些机器上大于 2^31，
# 靠 ctypes 的默认 int 转换会被当成有符号数传错。
for _name in ("CGDisplayIsBuiltin", "CGDisplayIsActive", "CGDisplayIsAsleep",
              "CGDisplayIsOnline", "CGDisplayIsMain", "CGDisplayPixelsWide",
              "CGDisplayPixelsHigh", "CGDisplayUnitNumber",
              "CGDisplayVendorNumber", "CGDisplayModelNumber"):
    _fn = getattr(_lib, _name)
    _fn.argtypes = [CGDirectDisplayID]
    _fn.restype = ctypes.c_uint32  # boolean_t 也是 4 字节

_lib.CGCancelDisplayConfiguration.argtypes = [CGDisplayConfigRef]
_lib.CGCancelDisplayConfiguration.restype = CGError

_lib.CGSBeginDisplayConfiguration.argtypes = [ctypes.POINTER(CGDisplayConfigRef)]
_lib.CGSBeginDisplayConfiguration.restype = CGError

_lib.CGSConfigureDisplayEnabled.argtypes = [
    CGDisplayConfigRef, CGDirectDisplayID, ctypes.c_bool,
]
_lib.CGSConfigureDisplayEnabled.restype = CGError

_lib.CGSCompleteDisplayConfiguration.argtypes = [CGDisplayConfigRef, ctypes.c_uint32]
_lib.CGSCompleteDisplayConfiguration.restype = CGError

# CGConfigureOption
CONFIGURE_FOR_APP_ONLY = 0
CONFIGURE_FOR_SESSION = 1
CONFIGURE_PERMANENTLY = 2

_CG_ERRORS = {
    0: "success",
    1000: "kCGErrorFailure",
    1001: "kCGErrorIllegalArgument",
    1002: "kCGErrorInvalidConnection",
    1003: "kCGErrorInvalidContext",
    1004: "kCGErrorCannotComplete",
    1007: "kCGErrorNotImplemented",
    1008: "kCGErrorRangeCheck",
    1009: "kCGErrorTypeCheck",
    1010: "kCGErrorNoneAvailable",
    1011: "kCGErrorInvalidOperation",
}


def _err(code: int) -> str:
    return _CG_ERRORS.get(code, f"CGError {code}")


# ---------------------------------------------------------------- 显示器信息


class Display:
    # 失去全部物理屏时，系统会造一块虚拟屏顶上，vendor/model 是 ASCII 魔数
    # "unkn" / "virt"。它 active=1 但没有任何物理输出，当成真屏会让黑屏保护失效。
    VIRTUAL_VENDOR = 0x756E6B6E  # "unkn"
    VIRTUAL_MODEL = 0x76697274   # "virt"

    def __init__(self, did: int):
        self.id = did
        self.builtin = bool(_lib.CGDisplayIsBuiltin(did))
        self.active = bool(_lib.CGDisplayIsActive(did))
        self.online = bool(_lib.CGDisplayIsOnline(did))
        self.asleep = bool(_lib.CGDisplayIsAsleep(did))
        self.main = bool(_lib.CGDisplayIsMain(did))
        self.width = _lib.CGDisplayPixelsWide(did)
        self.height = _lib.CGDisplayPixelsHigh(did)
        self.unit = _lib.CGDisplayUnitNumber(did)
        self.vendor = _lib.CGDisplayVendorNumber(did)
        self.model = _lib.CGDisplayModelNumber(did)

    @property
    def is_virtual(self) -> bool:
        """系统伪造的虚拟屏，不是真实物理输出。"""
        return (not self.builtin
                and self.vendor == self.VIRTUAL_VENDOR
                and self.model == self.VIRTUAL_MODEL)

    @property
    def phantom(self) -> bool:
        """CGSGetDisplayList 会带出没接东西的空槽位：离线、非内建、尺寸 1x1。"""
        return not self.builtin and not self.online and self.width <= 1

    @property
    def lit(self) -> bool:
        """真正在显示画面（虚拟屏没有物理输出，不算）。"""
        return self.active and not self.asleep and not self.is_virtual

    @property
    def state(self) -> str:
        if self.is_virtual:
            return "virtual"
        if self.asleep:
            return "asleep"
        if self.active:
            return "active"
        return "disabled" if not self.online else "inactive"

    def name(self, names: dict[int, str]) -> str:
        if self.id in names:
            return names[self.id]
        return "Built-in Display" if self.builtin else f"Display {self.id}"

    def line(self, names: dict[int, str]) -> str:
        tags = []
        if self.builtin:
            tags.append("builtin")
        if self.main:
            tags.append("main")
        tag = f" [{', '.join(tags)}]" if tags else ""
        size = f"{self.width}x{self.height}"
        return f"  {self.id:<6} {self.name(names):<26} {size:<12} {self.state:<9}{tag}"


def _screen_names() -> dict[int, str]:
    """用 NSScreen 取本地化名字。只覆盖点亮的屏幕，拿不到就算了。"""
    try:
        from AppKit import NSScreen  # type: ignore
    except Exception:
        return {}
    out: dict[int, str] = {}
    try:
        for scr in NSScreen.screens():
            num = scr.deviceDescription().get("NSScreenNumber")
            if num is not None:
                out[int(num)] = str(scr.localizedName())
    except Exception:
        pass
    return out


def all_displays() -> list[Display]:
    """全部显示器槽位，含被禁用的；已滤掉空槽。"""
    buf = (CGDirectDisplayID * 32)()
    count = ctypes.c_uint32(0)
    rc = _lib.CGSGetDisplayList(32, buf, ctypes.byref(count))
    if rc != 0:
        raise SystemExit(f"CGSGetDisplayList 失败: {_err(rc)}")
    displays = [Display(buf[i]) for i in range(count.value)]
    return [d for d in displays if not d.phantom]


# ---------------------------------------------------------------- 核心动作


def set_enabled(display_id: int, enabled: bool,
                option: int = CONFIGURE_FOR_SESSION) -> None:
    config = CGDisplayConfigRef()
    rc = _lib.CGSBeginDisplayConfiguration(ctypes.byref(config))
    if rc != 0:
        raise SystemExit(f"CGSBeginDisplayConfiguration 失败: {_err(rc)}")

    rc = _lib.CGSConfigureDisplayEnabled(config, display_id, enabled)
    if rc != 0:
        _lib.CGCancelDisplayConfiguration(config)
        raise SystemExit(f"CGSConfigureDisplayEnabled 失败: {_err(rc)}")

    rc = _lib.CGSCompleteDisplayConfiguration(config, option)
    # 提交的返回码不可信：拓扑异常时它经常返回 kCGErrorIllegalArgument(1001)，
    # 而屏幕其实已经亮了。以真实状态为准，只有状态确实没变才当失败。
    if rc != 0 and not _wait_for(display_id, enabled, timeout=2.0):
        raise SystemExit(f"CGSCompleteDisplayConfiguration 失败: {_err(rc)}")


def _wait_for(display_id: int, want_active: bool, timeout: float = 5.0) -> bool:
    """显示配置是异步生效的，轮询等它落定。"""
    deadline = time.monotonic() + timeout
    while True:
        if bool(_lib.CGDisplayIsActive(display_id)) == want_active:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.1)


# ---------------------------------------------------------------- CLI


def cmd_status(displays: list[Display], names: dict[int, str]) -> int:
    print(f"显示器 {len(displays)} 台:")
    for d in displays:
        print(d.line(names))
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="displaytoggle",
        description="接了外置显示器时开关内建屏（CGSConfigureDisplayEnabled）",
    )
    g = p.add_mutually_exclusive_group()
    g.add_argument("--on", action="store_true", help="打开内建屏")
    g.add_argument("--off", action="store_true", help="关闭内建屏")
    g.add_argument("--toggle", action="store_true", help="切换（默认）")
    g.add_argument("--status", action="store_true", help="只打印显示器状态")
    p.add_argument("--permanent", action="store_true",
                   help="用 kCGConfigurePermanently，重启后保留")
    p.add_argument("--force", action="store_true",
                   help="没有其它点亮的屏幕时也允许关掉内建屏（会黑屏）")
    p.add_argument("-q", "--quiet", action="store_true", help="少输出")
    args = p.parse_args(argv)

    displays = all_displays()
    names = _screen_names()

    if args.status:
        return cmd_status(displays, names)

    builtin = next((d for d in displays if d.builtin), None)
    if builtin is None:
        print("找不到内建显示器。", file=sys.stderr)
        return 1

    others_lit = [d for d in displays if not d.builtin and d.lit]

    if args.on:
        want_enabled = True
    elif args.off:
        want_enabled = False
    else:
        want_enabled = not builtin.active

    if builtin.active == want_enabled:
        if not args.quiet:
            print(f"内建屏已经是{'开' if want_enabled else '关'}，不动。")
        return 0

    if not want_enabled and not others_lit and not args.force:
        print("没有其它点亮的显示器，关掉内建屏会直接黑屏。接上外置屏，或者加 --force。",
              file=sys.stderr)
        return 2

    option = CONFIGURE_PERMANENTLY if args.permanent else CONFIGURE_FOR_SESSION
    set_enabled(builtin.id, want_enabled, option)
    ok = _wait_for(builtin.id, want_enabled)

    if not args.quiet:
        verb = "打开" if want_enabled else "关闭"
        if ok:
            print(f"已{verb}内建屏 ({builtin.name(names)}, id={builtin.id})。")
            if others_lit:
                print("外置屏: " + ", ".join(d.name(names) for d in others_lit))
        else:
            print(f"配置已提交，但内建屏没在预期时间内{verb}。", file=sys.stderr)
    return 0 if ok else 3


if __name__ == "__main__":
    sys.exit(main())
