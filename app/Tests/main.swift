//
//  自测：不走 GUI，直接验证 DisplayAPI / DisplayController 对私有接口的调用。
//  用法: selftest [--dry]   --dry 只打印状态，不真的开关屏幕
//

import AppKit

let dryRun = CommandLine.arguments.contains("--dry")
var failures = 0

func check(_ label: String, _ ok: Bool) {
    print("  [\(ok ? "PASS" : "FAIL")] \(label)")
    if !ok { failures += 1 }
}

func dump(_ tag: String) {
    print("--- \(tag)")
    for d in DisplayController().displays {
        print("    id=\(d.id) \(d.localizedName) \(d.width)×\(d.height) "
              + "\(d.stateText) builtin=\(d.isBuiltin) main=\(d.isMain)")
    }
}

/// 显示配置异步生效，轮询等它落定。
func wait(for id: CGDirectDisplayID, active: Bool, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if (CGDisplayIsActive(id) != 0) == active { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return (CGDisplayIsActive(id) != 0) == active
}

print("== 私有接口可用性")
check("dlsym 拿到全部符号", DisplayAPI.shared.isAvailable)

let c = DisplayController()
dump("初始状态")

print("== 枚举")
check("能枚举到显示器", !c.displays.isEmpty)
check("能找到内建屏", c.builtin != nil)
check("空槽位已被滤掉", c.displays.allSatisfy { !$0.isPhantom })

guard let builtin = c.builtin else {
    print("没有内建屏，后面的测试跳过。")
    exit(failures == 0 ? 0 : 1)
}

print("== 保护逻辑")
check("canTurnOff 与外接屏状态一致", c.canTurnOff == !c.externalsLit.isEmpty)

print("== 虚拟屏识别")
check("当前没有屏被误判成虚拟屏", DisplayController().displays.allSatisfy { !$0.isVirtual })
check("真实在亮的屏都不是虚拟屏", DisplayController().displays.filter(\.isLit).allSatisfy { !$0.isVirtual })
check("有真屏亮着时 isStranded 为假", !DisplayController().isStranded)

print("== 记住 display ID")
DisplayController().rememberDisplays()
let remembered = DisplayController()
check("内建屏 ID 已记住且一致",
      remembered.rememberedBuiltinID == remembered.builtin?.id)
// 这条防的是 1.0 的回归：恢复候选集不能靠猜 0..<40，
// CGDirectDisplayID 在很多机器上是大数值。
check("见过的真实 ID 都被记下来了",
      Set(remembered.displays.filter { !$0.isVirtual }.map(\.id))
        .isSubset(of: Set(remembered.rememberedIDs)))
if let maxID = remembered.rememberedIDs.max() {
    print("    记住的 ID: \(remembered.rememberedIDs.map(String.init).joined(separator: ", "))"
          + (maxID >= 40 ? "   ← 超出旧版 0..<40 的猜测范围" : ""))
}

// 这条防两个回归：
//  · 1.2 曾把 detectDisplays + 4 秒等待放在恢复链最前面，而恢复窗口只有一瞬，
//    任何前置阻塞都等于放弃。第一个 enable 必须立刻发出去。
//  · 1.5 在链尾加了睡眠→唤醒（约 6 秒）。内建屏还在枚举里时绝不能走到那一步，
//    所以这个 1.5 秒的上限同时守住了「正常机器不受新逻辑影响」。
// 这条防的是 1.5 的 bug：waitForActive 曾直接判断 CGDisplayIsActive(id) != 0，
// 而该函数对失效 ID 返回 0xFFFFFFFF（错误码），于是被当成「屏幕亮着」，
// 恢复链第一步就误判成功提前退出，真正管用的睡眠→唤醒永远轮不到。
print("== 失效 ID 不能被当成亮着")
let bogus: CGDirectDisplayID = 99999
print("    CGDisplayIsActive(\(bogus)) 原始返回 = \(CGDisplayIsActive(bogus))")
check("对不存在的 ID，waitForActive(want:true) 必须为假",
      !DisplayAPI.waitForActive(bogus, true, timeout: 0.3))
check("不存在的 ID 不会混进枚举",
      !DisplayController().displays.contains { $0.id == bogus })

print("== 紧急恢复的延迟")
let t0 = Date()
DisplayController().emergencyRestoreBuiltin()
let elapsed = Date().timeIntervalSince(t0)
check("紧急恢复没有前置阻塞（实测 \(String(format: "%.2f", elapsed))s，需 < 1.5s）",
      elapsed < 1.5)

if dryRun {
    print("\n--dry：跳过真实开关。")
    exit(failures == 0 ? 0 : 1)
}

guard c.canTurnOff else {
    print("\n没有点亮的外置屏，跳过开关测试（关掉就黑屏了）。")
    exit(failures == 0 ? 0 : 1)
}

// 测试结果不能取决于跑之前屏幕是什么状态。
if !DisplayController().isBuiltinOn {
    print("== 归一化：先把内建屏打开")
    _ = try? DisplayController().setBuiltin(true, permanent: false)
    check("归一化成功", wait(for: builtin.id, active: true))
}

print("== 关闭内建屏")
do {
    let changed = try DisplayController().setBuiltin(false, permanent: false)
    check("setBuiltin(false) 返回已变更", changed)
    check("内建屏确实关掉了", wait(for: builtin.id, active: false))
    dump("关闭后")

    // 这是最关键的一条：关掉之后还能不能重新找到它
    let after = DisplayController()
    check("关闭后仍能通过 CGSGetDisplayList 找到内建屏", after.builtin != nil)
    check("关闭后 isBuiltin 依然为真", after.builtin?.isBuiltin == true)
    check("关闭后状态显示为已关闭", after.builtin?.isActive == false)
} catch {
    check("关闭内建屏未抛错（\(error.localizedDescription)）", false)
}

print("== 打开内建屏")
do {
    let changed = try DisplayController().setBuiltin(true, permanent: false)
    check("setBuiltin(true) 返回已变更", changed)
    check("内建屏确实开回来了", wait(for: builtin.id, active: true))

    let idempotent = try DisplayController().setBuiltin(true, permanent: false)
    check("重复打开是空操作", idempotent == false)
    dump("恢复后")
} catch {
    check("打开内建屏未抛错（\(error.localizedDescription)）", false)
}

print("== 主显示器切换")
let ctl = DisplayController()
if let originalMain = ctl.displays.first(where: \.isMain),
   let other = ctl.displays.first(where: { $0.isLit && $0.id != originalMain.id }) {
    do {
        try ctl.makeMain(other)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        check("主显示器切到了另一块屏",
              DisplayController().displays.first(where: \.isMain)?.id == other.id)

        // 别把用户的配置留在测试改过的状态
        try ctl.makeMain(originalMain)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        check("主显示器已还原",
              DisplayController().displays.first(where: \.isMain)?.id == originalMain.id)
    } catch {
        check("切换主显示器未抛错（\(error.localizedDescription)）", false)
    }
} else {
    print("  (只有一块屏，跳过)")
}

print("\n\(failures == 0 ? "全部通过" : "\(failures) 项失败")")
exit(failures == 0 ? 0 : 1)
