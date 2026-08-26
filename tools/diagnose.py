#!/usr/bin/env python3
"""
诊断「拔掉外接屏后内建屏恢复不了」（第 2 轮）。

它会全程采样显示器状态，并在检测到没有任何真屏亮着时，依次尝试几种恢复手段，
把每一种是否奏效都记下来 —— 目的是在你的机器上直接测出哪种有效，而不是靠猜。

用法：
    python3 diagnose.py

然后按提示操作。全程日志写在 display-diagnose.log，跑完把它发出来即可。

安全说明：过程中屏幕会黑一小段时间。如果所有恢复手段都失败，
把外接屏的线插回去就能恢复 —— 这是可靠的退路。
"""

import ctypes
import json
import sys
import time
from datetime import datetime

SL = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
CG = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"

sl = ctypes.CDLL(SL)
cg = ctypes.CDLL(CG)

u32 = ctypes.c_uint32
CFG = ctypes.c_void_p

sl.CGSGetDisplayList.argtypes = [u32, ctypes.POINTER(u32), ctypes.POINTER(u32)]
sl.CGSGetDisplayList.restype = ctypes.c_int32
sl.CGSBeginDisplayConfiguration.argtypes = [ctypes.POINTER(CFG)]
sl.CGSBeginDisplayConfiguration.restype = ctypes.c_int32
sl.CGSConfigureDisplayEnabled.argtypes = [CFG, u32, ctypes.c_bool]
sl.CGSConfigureDisplayEnabled.restype = ctypes.c_int32
sl.CGSCompleteDisplayConfiguration.argtypes = [CFG, u32]
sl.CGSCompleteDisplayConfiguration.restype = ctypes.c_int32
cg.CGRestorePermanentDisplayConfiguration.restype = ctypes.c_int32
# 强制让 WindowServer 重新探测显示器硬件——相当于旧版系统设置里的「检测显示器」。
# stranded 状态下所有 display ID 都失效了，重新探测是少数还讲得通的路子。
sl.CGSDetectDisplays.argtypes = []
sl.CGSDetectDisplays.restype = ctypes.c_int32

for f in ("CGDisplayIsBuiltin", "CGDisplayIsActive", "CGDisplayIsOnline",
          "CGDisplayIsAsleep", "CGDisplayIsMain", "CGDisplayPixelsWide",
          "CGDisplayPixelsHigh", "CGDisplayUnitNumber",
          "CGDisplayVendorNumber", "CGDisplayModelNumber"):
    fn = getattr(sl, f)
    fn.argtypes = [u32]
    fn.restype = u32

sl.CGDisplayCreateUUIDFromDisplayID.argtypes = [u32]
sl.CGDisplayCreateUUIDFromDisplayID.restype = ctypes.c_void_p

VIRTUAL_VENDOR, VIRTUAL_MODEL = 0x756E6B6E, 0x76697274

LOG = open("display-diagnose.log", "w", buffering=1)


def log(msg):
    line = f"[{datetime.now():%H:%M:%S.%f}] {msg}"
    print(line)
    LOG.write(line + "\n")


def slots():
    b = (u32 * 32)()
    c = u32(0)
    sl.CGSGetDisplayList(32, b, ctypes.byref(c))
    return [b[i] for i in range(c.value)]


def info(d):
    return {
        "id": d,
        "builtin": bool(sl.CGDisplayIsBuiltin(d)),
        "active": bool(sl.CGDisplayIsActive(d)),
        "online": bool(sl.CGDisplayIsOnline(d)),
        "asleep": bool(sl.CGDisplayIsAsleep(d)),
        "main": bool(sl.CGDisplayIsMain(d)),
        "size": f"{sl.CGDisplayPixelsWide(d)}x{sl.CGDisplayPixelsHigh(d)}",
        "unit": sl.CGDisplayUnitNumber(d),
        "vendor": hex(sl.CGDisplayVendorNumber(d)),
        "model": hex(sl.CGDisplayModelNumber(d)),
        "uuid": bool(sl.CGDisplayCreateUUIDFromDisplayID(d)),
        "virtual": (not sl.CGDisplayIsBuiltin(d)
                    and sl.CGDisplayVendorNumber(d) == VIRTUAL_VENDOR
                    and sl.CGDisplayModelNumber(d) == VIRTUAL_MODEL),
    }


def snapshot():
    return [info(d) for d in slots()]


def lit(snap):
    """真正在显示画面的屏：active、没休眠、不是系统伪造的虚拟屏。"""
    return [s for s in snap if s["active"] and not s["asleep"] and not s["virtual"]]


def brief(snap):
    if not snap:
        return "(空)"
    return " | ".join(
        f"{s['id']}{'内建' if s['builtin'] else ('虚拟' if s['virtual'] else '外接')}"
        f"={'亮' if s['active'] else '灭'}"
        for s in snap
    )


def enable_flag(ids, flag, option=1):
    """一个事务里把一批 ID 设成 flag。返回 (每个的 rc, 提交的 rc)。"""
    c = CFG()
    if sl.CGSBeginDisplayConfiguration(ctypes.byref(c)) != 0:
        return None, None
    rcs = {i: sl.CGSConfigureDisplayEnabled(c, i, flag) for i in ids}
    return rcs, sl.CGSCompleteDisplayConfiguration(c, option)


def enable(ids, option=1):
    return enable_flag(ids, True, option)


def builtin_lit():
    return any(s["builtin"] and s["active"] for s in snapshot())


def try_method(name, fn, settle=3.0):
    log(f"  尝试：{name}")
    try:
        detail = fn()
        if detail:
            log(f"    调用返回：{detail}")
    except Exception as e:
        log(f"    异常：{e}")
    time.sleep(settle)
    ok = builtin_lit()
    log(f"    结果：{'✅ 内建屏亮了' if ok else '❌ 仍然没亮'}   {brief(snapshot())}")
    return ok


def main():
    log("=" * 70)
    log("初始状态：" + brief(snapshot()))
    if "--snapshot" in sys.argv:
        log(json.dumps(snapshot(), ensure_ascii=False, indent=1))
        log("（--snapshot：只采集状态，不做任何改动）")
        return
    log(json.dumps(snapshot(), ensure_ascii=False, indent=1))

    builtin_ids = [s["id"] for s in snapshot() if s["builtin"]]
    known_ids = [s["id"] for s in snapshot()]
    if not builtin_ids:
        log("找不到内建屏，无法继续。")
        return
    log(f"内建屏 ID = {builtin_ids}，见过的全部 ID = {known_ids}")

    print()
    print("=" * 70)
    print("接下来请：")
    print("  1. 用菜单栏 App（或别的方式）关掉内建屏")
    print("  2. 拔掉外接显示器的线")
    print("  3. 屏幕会黑掉，等着别动，脚本会自动尝试恢复")
    print()
    print("  如果 30 秒后仍然全黑，把线插回去即可恢复。")
    print("=" * 70)
    input("准备好了按回车开始监控…")

    log("开始监控，等待进入无真屏状态…")
    deadline = time.time() + 180
    while time.time() < deadline:
        snap = snapshot()
        if not lit(snap):
            log("!! 检测到没有任何真屏亮着")
            log("完整快照：" + json.dumps(snap, ensure_ascii=False))
            break
        time.sleep(0.4)
    else:
        log("3 分钟内没有进入无真屏状态，结束。")
        return

    log("-" * 70)
    log("开始依次尝试恢复手段：")

    def detect():
        return f"CGSDetectDisplays() -> {sl.CGSDetectDisplays()}"

    def disable_virtual():
        virt = [s["id"] for s in snapshot() if s["virtual"]]
        if not virt:
            return "没有虚拟屏可关"
        return f"disable {virt} -> {enable_flag(virt, False)}"

    def disable_virtual_then_detect():
        r1 = disable_virtual()
        time.sleep(1.5)
        return f"{r1}；然后 {detect()}"

    def detect_then_enable():
        r1 = detect()
        time.sleep(2.0)
        ids = sorted(set(builtin_ids) | set(slots()))
        return f"{r1}；然后 enable {ids} -> {enable(ids, 1)}"

    # 上一轮已经证明：单纯 enable 任何 ID 都会被 1001 拒绝，因为 stranded 状态下
    # display ID 已经失效。所以这一轮把重点放在「让系统重新发现硬件」上。
    methods = [
        ("A. CGSDetectDisplays（强制重新探测硬件）", detect, 6.0),
        ("B. 关掉那块虚拟屏", disable_virtual, 6.0),
        ("C. 关掉虚拟屏 + 重新探测", disable_virtual_then_detect, 6.0),
        ("D. 重新探测 + 再 enable 内建屏", detect_then_enable, 6.0),
        ("E. CGRestorePermanentDisplayConfiguration（等久一点）",
         lambda: f"-> {cg.CGRestorePermanentDisplayConfiguration()}", 10.0),
        ("F. 批量 enable（上一轮已知无效，留作对照）",
         lambda: enable(sorted(set(known_ids) | set(range(41))), 1), 4.0),
    ]

    winner = None
    for name, fn, settle in methods:
        if try_method(name, fn, settle):
            winner = name
            break

    log("-" * 70)
    if winner:
        log(f"结论：有效的手段是 —— {winner}")
    else:
        log("结论：以上手段全部无效。请把外接屏插回去恢复。")
        log("这说明恢复必须依赖别的机制，日志里的快照是关键线索。")

    time.sleep(2)
    log("最终状态：" + brief(snapshot()))
    log("日志已保存到 display-diagnose.log，请把这个文件发出来。")


if __name__ == "__main__":
    try:
        main()
    finally:
        LOG.close()
