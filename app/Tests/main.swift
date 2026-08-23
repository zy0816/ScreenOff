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

print("== 虚拟屏识别")
check("当前没有屏被误判成虚拟屏", DisplayController().displays.allSatisfy { !$0.isVirtual })
check("真实在亮的屏都不是虚拟屏", DisplayController().displays.filter(\.isLit).allSatisfy { !$0.isVirtual })
check("有真屏亮着时 isStranded 为假", !DisplayController().isStranded)

print("== 记住内建屏 ID")
DisplayController().rememberBuiltinID()
check("ID 已记住且与当前内建屏一致",
      DisplayController().rememberedBuiltinID == DisplayController().builtin?.id)

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
