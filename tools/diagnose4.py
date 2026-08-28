#!/usr/bin/env python3
"""
第 4 轮：既然合盖再打开能救回来，那就用软件跑一遍「睡眠→唤醒」周期试试。

前三轮已经排除的：所有针对 display ID 的操作（enable / 批量 / 各种 option）、
CGSDetectDisplays、关虚拟屏、CGRestorePermanentDisplayConfiguration，
以及「反应不够快」——日志证明 App 3 毫秒就响应了，而那时内建屏的 ID 已经失效。

这一轮换个性质完全不同的思路：不去碰 display ID，而是让显示子系统
整体走一遍电源状态切换，看能不能像合盖开盖那样触发重新初始化。

用法：
    python3 diagnose4.py

日志写在 display-wake.log。
万一都不行：合盖再打开，或把外接屏插回去。
"""

import ctypes
import subprocess
import time
from datetime import datetime

sl = ctypes.CDLL("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")
u32 = ctypes.c_uint32
sl.CGSGetDisplayList.argtypes = [u32, ctypes.POINTER(u32), ctypes.POINTER(u32)]
for f in ("CGDisplayIsBuiltin", "CGDisplayIsActive", "CGDisplayIsOnline",
          "CGDisplayVendorNumber", "CGDisplayModelNumber"):
    fn = getattr(sl, f); fn.argtypes = [u32]; fn.restype = u32

VIRT = (0x756E6B6E, 0x76697274)
LOG = open("display-wake.log", "w", buffering=1)


def log(m):
    line = f"[{datetime.now():%H:%M:%S.%f}] {m}"
    print(line); LOG.write(line + "\n")


def slots():
    b = (u32 * 32)(); c = u32(0)
    sl.CGSGetDisplayList(32, b, ctypes.byref(c))
    return [b[i] for i in range(c.value)]


def is_virtual(d):
    return (not sl.CGDisplayIsBuiltin(d)
            and (sl.CGDisplayVendorNumber(d), sl.CGDisplayModelNumber(d)) == VIRT)


def brief():
    out = []
    for d in slots():
        kind = "内建" if sl.CGDisplayIsBuiltin(d) else ("虚拟" if is_virtual(d) else "外接")
        out.append(f"{d}{kind}={'亮' if sl.CGDisplayIsActive(d) else '灭'}")
    return " | ".join(out) or "(空)"


def builtin_lit():
    return any(sl.CGDisplayIsBuiltin(d) and sl.CGDisplayIsActive(d) for d in slots())


def stranded():
    return not any(sl.CGDisplayIsActive(d) and not is_virtual(d) for d in slots())


def say(text):
    """黑屏时看不见任何提示，只能靠说的。"""
    try:
        subprocess.run(["say", "-r", "200", text], timeout=20)
    except Exception:
        pass


def run(*cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=10)
        return f"{' '.join(cmd)} → rc={r.returncode}"
    except Exception as e:
        return f"{' '.join(cmd)} → {e}"


# ---- 手段 ----

def display_sleep_wake():
    """让显示器睡眠，再声明用户活动把它唤醒——软件版的合盖开盖。"""
    r1 = run("pmset", "displaysleepnow")
    time.sleep(3)
    r2 = run("caffeinate", "-u", "-t", "2")
    return f"{r1}；等 3s；{r2}"


def probe_services():
    """让 IOKit 重新探测显示相关的驱动。

    不猜服务名——Apple Silicon 上显示驱动的类名和 Intel 时代完全不同，
    直接从 IORegistry 里把名字带 display / framebuffer / clcd / dcp / backlight
    的类都捞出来逐个探测。
    """
    import re
    iok = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
    iok.IOServiceMatching.argtypes = [ctypes.c_char_p]
    iok.IOServiceMatching.restype = ctypes.c_void_p
    iok.IOServiceGetMatchingService.argtypes = [ctypes.c_uint, ctypes.c_void_p]
    iok.IOServiceGetMatchingService.restype = ctypes.c_uint
    iok.IOServiceRequestProbe.argtypes = [ctypes.c_uint, ctypes.c_uint32]
    iok.IOServiceRequestProbe.restype = ctypes.c_int

    try:
        # 别用 text=True：ioreg 的输出里混着非 UTF-8 字节，会直接抛解码异常
        raw = subprocess.run(["ioreg", "-l", "-w0"],
                             capture_output=True, timeout=20).stdout
        out = raw.decode("utf-8", errors="replace")
    except Exception as e:
        return f"ioreg 失败: {e}"
    classes = set(re.findall(r"<class ([A-Za-z0-9_]+)", out))
    targets = sorted(c for c in classes
                     if re.search(r"display|framebuffer|clcd|dcp|backlight", c, re.I))
    log(f"    找到 {len(targets)} 个候选驱动类: {', '.join(targets[:10])}"
        + (" …" if len(targets) > 10 else ""))

    done = []
    for name in targets:
        m = iok.IOServiceMatching(name.encode())
        if not m:
            continue
        svc = iok.IOServiceGetMatchingService(0, m)
        if svc:
            done.append(f"{name}:rc={iok.IOServiceRequestProbe(svc, 0)}")
    return "；".join(done) or "没有可探测的显示服务"


def attempt(name, fn, settle):
    log(f"  尝试：{name}")
    try:
        log(f"    {fn()}")
    except Exception as e:
        log(f"    异常：{e}")
    time.sleep(settle)
    ok = builtin_lit()
    log(f"    结果：{'✅ 内建屏亮了' if ok else '❌ 仍然没亮'}   {brief()}")
    if ok:
        say("屏幕恢复了。")
    return ok


def main():
    log("=" * 68)
    log(f"初始状态：{brief()}")

    print()
    print("=" * 68)
    print("请：1) 关掉内建屏   2) 拔掉外接显示器")
    print()
    print("屏幕会黑掉，然后脚本自动尝试两种「唤醒」手段，约 15 秒。")
    print("全程不需要你操作，听语音提示即可。")
    print()
    print("  全都失败的话：合盖再打开，或把线插回去。")
    print("=" * 68)
    input("准备好了按回车…")

    log("等待进入无真屏状态…")
    end = time.time() + 180
    while time.time() < end:
        if stranded():
            log(f"!! 已经没有真屏亮着：{brief()}")
            say("屏幕已经黑了，现在开始尝试恢复，请稍等。")
            break
        time.sleep(0.4)
    else:
        log("3 分钟内没进入该状态，结束。")
        return

    log("-" * 68)
    winner = None
    for name, fn, settle in [
        ("A. 显示器睡眠 + 唤醒（软件版合盖开盖）", display_sleep_wake, 6.0),
        ("B. IOKit 重新探测显示驱动", probe_services, 6.0),
    ]:
        if attempt(name, fn, settle):
            winner = name
            break

    log("-" * 68)
    if winner:
        log(f"结论：有效的是 —— {winner}")
    else:
        log("结论：这两种也都无效。请合盖再打开恢复。")
        say("两种办法都没成功，请合上盖子再打开。")
    log("日志已保存到 display-wake.log")


if __name__ == "__main__":
    try:
        main()
    finally:
        LOG.close()
