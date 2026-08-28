#!/usr/bin/env python3
"""
测量「拔线之后，内建屏还能被点亮多久」——也就是恢复窗口有多长。

做法：以 5ms 的间隔死盯外接屏，一旦发现它没了，立刻开始高频尝试点亮内建屏，
把每次尝试的耗时和返回码都记下来。这样就能看出窗口从哪一刻开始关上。

这个数字很关键：
  · 窗口有几百毫秒 → App 时间充裕，那么 M3 恢复不了就是它那边窗口≈0，属于硬件差异
  · 窗口只有几十毫秒 → 这是场赛跑，M3 可能只是稍慢一点，优化响应速度仍有希望

用法：
    python3 measure_window.py

按提示关掉内建屏，然后拔线。屏幕可能会黑一下；
脚本会尽力点亮内建屏，实在不行就合盖再打开、或把线插回去。
"""

import ctypes
import time

sl = ctypes.CDLL("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")
u32, CFG = ctypes.c_uint32, ctypes.c_void_p
sl.CGSGetDisplayList.argtypes = [u32, ctypes.POINTER(u32), ctypes.POINTER(u32)]
sl.CGSBeginDisplayConfiguration.argtypes = [ctypes.POINTER(CFG)]
sl.CGSConfigureDisplayEnabled.argtypes = [CFG, u32, ctypes.c_bool]
sl.CGSCompleteDisplayConfiguration.argtypes = [CFG, u32]
for f in ("CGDisplayIsBuiltin", "CGDisplayIsActive", "CGDisplayIsOnline",
          "CGDisplayVendorNumber", "CGDisplayModelNumber"):
    fn = getattr(sl, f); fn.argtypes = [u32]; fn.restype = u32

VIRT = (0x756E6B6E, 0x76697274)


def slots():
    b = (u32 * 32)(); c = u32(0)
    sl.CGSGetDisplayList(32, b, ctypes.byref(c))
    return [b[i] for i in range(c.value)]


def real_external_lit():
    """真外接屏还亮着吗（排除虚拟屏和空槽）。"""
    for d in slots():
        if sl.CGDisplayIsBuiltin(d):
            continue
        if (sl.CGDisplayVendorNumber(d), sl.CGDisplayModelNumber(d)) == VIRT:
            continue
        if sl.CGDisplayIsActive(d) and sl.CGDisplayIsOnline(d):
            return True
    return False


def try_enable(did):
    c = CFG()
    if sl.CGSBeginDisplayConfiguration(ctypes.byref(c)) != 0:
        return -1, -1
    r1 = sl.CGSConfigureDisplayEnabled(c, did, True)
    r2 = sl.CGSCompleteDisplayConfiguration(c, 1)
    return r1, r2


builtin = next((d for d in slots() if sl.CGDisplayIsBuiltin(d)), None)
if builtin is None:
    raise SystemExit("找不到内建屏")

print(f"内建屏 ID = {builtin}")
print()
print("=" * 66)
print("请：1) 关掉内建屏   2) 拔掉外接显示器")
print()
print("脚本会在拔线的瞬间开始抢救，并记录窗口有多长。")
print("万一没救回来：合盖再打开，或把线插回去。")
print("=" * 66)
input("准备好了按回车…")

print("盯着外接屏（5ms 一次）…")
t_wait = time.time()
while real_external_lit():
    if time.time() - t_wait > 120:
        raise SystemExit("2 分钟内没检测到拔线，退出。")
    time.sleep(0.005)

t0 = time.perf_counter()
print("!! 外接屏消失，开始抢救")

log = []
recovered_at = None
for i in range(300):                      # 最多试 ~3 秒
    r1, r2 = try_enable(builtin)
    active = bool(sl.CGDisplayIsActive(builtin))
    log.append((( time.perf_counter() - t0) * 1000, r1, r2, active))
    if active:
        recovered_at = (time.perf_counter() - t0) * 1000
        break
    time.sleep(0.01)

print()
print("=" * 66)
print(f"{'时刻(ms)':>10}  {'configure':>9}  {'complete':>8}  内建屏")
shown = 0
for ms, r1, r2, act in log:
    # 只打印开头、结尾和返回码变化的地方，免得刷屏
    if shown < 12 or act or ms > log[-1][0] - 100:
        print(f"{ms:10.1f}  {r1:9d}  {r2:8d}  {'亮' if act else '灭'}")
        shown += 1

print("=" * 66)
if recovered_at is not None:
    print(f"✅ 恢复成功，用时 {recovered_at:.0f} ms（共 {len(log)} 次尝试）")
    first_fail = next((ms for ms, _, r2, _ in log if r2 != 0), None)
    if first_fail is not None:
        print(f"   提交码从 {first_fail:.0f} ms 起开始报错（但仍恢复了，说明返回码不可信）")
else:
    print(f"❌ {log[-1][0]:.0f} ms 内没能恢复，共尝试 {len(log)} 次")
    codes = sorted({r2 for _, _, r2, _ in log})
    print(f"   提交码取值：{codes}   1001 = kCGErrorIllegalArgument")
    print("   请合盖再打开，或把外接屏插回去。")
