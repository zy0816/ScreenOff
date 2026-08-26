//
//  DisplayToggle — 菜单栏 UI
//

import AppKit
import ServiceManagement

let appVersion = "1.2"

// MARK: - 偏好设置

enum Prefs {
    private static let d = UserDefaults.standard

    static var autoRestore: Bool {
        get { d.object(forKey: "autoRestore") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoRestore") }
    }
    static var permanent: Bool {
        get { d.bool(forKey: "permanent") }
        set { d.set(newValue, forKey: "permanent") }
    }
}

// MARK: - App

/// 显示器拓扑变化的 C 回调。比 NSApplication 的通知更靠得住：
/// 掉进无物理屏状态时 AppKit 那条通知不一定还能指望。
private let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
    guard let userInfo else { return }
    // 只关心屏幕被拿走的方向，加进来不会把人变成黑屏
    let interesting: CGDisplayChangeSummaryFlags = [.removeFlag, .disabledFlag, .setModeFlag]
    guard !flags.intersection(interesting).isEmpty else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    delegate.displayTopologyChanged()
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = DisplayController()
    private let menu = NSMenu()
    /// 看护跑在自己的队列上，不依赖主 runloop —— 屏幕全没之后主线程未必还在转。
    private let watchQueue = DispatchQueue(label: "displaytoggle.watchdog", qos: .userInitiated)
    private var watchTimer: DispatchSourceTimer?
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard DisplayAPI.shared.isAvailable else {
            let alert = NSAlert()
            alert.messageText = "无法启动"
            alert.informativeText = DisplayAPIError.symbolsMissing.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        CGDisplayRegisterReconfigurationCallback(
            reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque()
        )

        // 挡住 App Nap：屏幕全部消失后，系统很可能把这个后台 App 节流甚至挂起，
        // 那样 Timer 不再触发、main queue 也不再排空，恢复逻辑根本没机会跑。
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "监视显示器丢失，以便把内建屏恢复回来"
        )

        // 兜底看护：通知和回调都可能在极端状态下失灵，轮询是最后一道保险。
        // 一次几个 CG 调用，开销可以忽略。用 DispatchSourceTimer 而不是 Timer，
        // 后者挂在主 runloop 上，主线程一被节流就跟着停。
        let timer = DispatchSource.makeTimerSource(queue: watchQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.restoreIfStranded()
        }
        timer.resume()
        watchTimer = timer

        controller.rememberDisplays()
        updateStatusIcon()
        restoreIfStranded()

        // 调试用：启动后自动展开菜单，方便截图确认样式。
        // 定时收起并退出——展开的菜单挂在屏幕上会挡住操作，也可能被误点。
        if CommandLine.arguments.contains("--preview-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.menu.cancelTracking()
                    NSApp.terminate(nil)
                }
                self.statusItem.menu = self.menu
                self.statusItem.button?.performClick(nil)
                self.statusItem.menu = nil
            }
        }
    }

    // MARK: 状态图标

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let on = controller.isBuiltinOn
        // 图标即状态：笔记本屏在用 / 只有外接屏在用。
        let name = on ? "laptopcomputer" : "display"
        let desc = on ? "内建屏已开启" : "内建屏已关闭"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: desc)
            ?? NSImage(systemSymbolName: "rectangle", accessibilityDescription: desc)
        image?.isTemplate = true
        button.image = image
        button.toolTip = "内建屏：\(on ? "开启" : "关闭")"
    }

    // MARK: 点击

    @objc private func statusItemClicked() {
        // 只认真实的右键抬起事件。合成事件（脚本、辅助功能）拿不到可靠的
        // currentEvent，一律走菜单——展开菜单是无害的，误切换屏幕不是。
        if NSApp.currentEvent?.type == .rightMouseUp {
            toggleBuiltin()
            return
        }
        // 左键：展开菜单，跟系统的菜单栏项一致
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: 菜单

    /// 说明性的一行小字，不可点。
    private func hintItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    /// macOS 14 起有原生的分组标题样式，旧系统降级成禁用项。
    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let on = controller.isBuiltinOn
        let stranded = controller.isStranded
        menu.addItem(sectionHeader(stranded ? "没有屏幕在显示画面"
                                            : "内建屏：\(on ? "开启" : "关闭")"))

        let toggle = NSMenuItem(
            title: stranded ? "恢复内建屏" : (on ? "关闭内建屏" : "打开内建屏"),
            action: #selector(toggleBuiltin), keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        if stranded {
            menu.addItem(hintItem("系统当前只剩一块虚拟屏"))
        } else if on && !controller.canTurnOff {
            toggle.isEnabled = false
            menu.addItem(hintItem("没有其它屏幕，关掉会黑屏"))
        } else if on, controller.builtin?.isMain == true,
                  let ext = controller.externalsLit.first {
            // 内建屏正是主显示器：关掉之后菜单栏和 Dock 会搬到外置屏上去，
            // 先讲清楚，并给一个一键换主屏的入口。
            menu.addItem(hintItem("关闭后主显示器移至「\(ext.localizedName)」"))
            let makeMain = NSMenuItem(
                title: "把「\(ext.localizedName)」设为主显示器",
                action: #selector(makeExternalMain), keyEquivalent: ""
            )
            makeMain.target = self
            menu.addItem(makeMain)
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader("显示器"))

        // 内建屏排前面，顺序稳定；状态靠勾选和图标表达，别用文字把菜单撑宽
        for d in controller.displays.sorted(by: { a, b in
            a.isBuiltin != b.isBuiltin ? a.isBuiltin : a.id < b.id
        }) {
            var title = "\(d.localizedName) · \(d.width)×\(d.height)"
            if d.isMain { title += "（主）" }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            // 勾选表示正在显示画面。别再设 image——勾选标记和图标抢同一个位置，
            // 图标根本不会画出来。
            item.state = d.isLit ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let auto = NSMenuItem(title: "拔掉外置屏时自动恢复", action: #selector(toggleAutoRestore), keyEquivalent: "")
        auto.target = self
        auto.state = Prefs.autoRestore ? .on : .off
        menu.addItem(auto)

        let perm = NSMenuItem(title: "重启后保留屏幕状态", action: #selector(togglePermanent), keyEquivalent: "")
        perm.target = self
        perm.state = Prefs.permanent ? .on : .off
        menu.addItem(perm)

        let login = NSMenuItem(title: "开机启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "关于 DisplayToggle", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: 动作

    @objc private func toggleBuiltin() {
        // 掉进无物理屏状态时内建屏已经不在枚举里了，setBuiltin 会直接空转，
        // 用户点了没反应。这种情况直接走应急恢复。
        if controller.isStranded {
            controller.emergencyRestoreBuiltin()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.updateStatusIcon()
            }
            return
        }

        let on = controller.isBuiltinOn
        if on && !controller.canTurnOff {
            notify("没有其它屏幕", "关掉内建屏会直接黑屏。先接上外置显示器。")
            return
        }
        // 关屏前务必记住 ID：一旦外置屏随后也没了，这是唯一还能定位内建屏的线索。
        controller.rememberDisplays()
        do {
            try controller.setBuiltin(!on, permanent: Prefs.permanent)
        } catch {
            notify("操作失败", error.localizedDescription)
        }
        // 显示配置是异步生效的，等它落定再刷新图标。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.updateStatusIcon()
        }
    }

    @objc private func makeExternalMain() {
        guard let ext = controller.externalsLit.first else { return }
        do {
            try controller.makeMain(ext)
        } catch {
            notify("设置主显示器失败", error.localizedDescription)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.updateStatusIcon()
        }
    }

    @objc private func toggleAutoRestore() {
        Prefs.autoRestore.toggle()
    }

    @objc private func togglePermanent() {
        Prefs.permanent.toggle()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notify("设置开机启动失败", error.localizedDescription)
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "DisplayToggle \(appVersion)"
        alert.informativeText = """
            在接了外置显示器时开关 Mac 内建屏。

            左键点击图标：打开菜单
            右键点击图标：直接切换

            用的是 SkyLight 的私有显示配置接口，不需要 root，\
            也不改系统设置里的镜像和排列。
            """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quit() {
        // 别把用户留在黑屏状态下退出。
        if controller.isStranded {
            controller.emergencyRestoreBuiltin()
        } else if !controller.isBuiltinOn && !controller.hasExternal {
            _ = try? controller.setBuiltin(true, permanent: Prefs.permanent)
        }
        watchTimer?.cancel()
        if let activityToken { ProcessInfo.processInfo.endActivity(activityToken) }
        CGDisplayRemoveReconfigurationCallback(
            reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque()
        )
        NSApp.terminate(nil)
    }

    // MARK: 自动恢复

    @objc private func screensChanged() {
        displayTopologyChanged()
    }

    func displayTopologyChanged() {
        DispatchQueue.main.async { [weak self] in self?.updateStatusIcon() }
        // 恢复走后台队列，主线程此刻可能正被系统节流。
        watchQueue.async { [weak self] in
            self?.restoreIfStranded()
            // 拔线瞬间状态还在抖，稍后再确认一次。
            Thread.sleep(forTimeInterval: 0.8)
            self?.restoreIfStranded()
            DispatchQueue.main.async { [weak self] in self?.updateStatusIcon() }
        }
    }

    /// 一块真屏都不亮了 —— 此时用户面对的就是黑屏，必须把内建屏拉回来。
    ///
    /// 不能只看「内建屏关着且没有外置屏」：失去全部物理屏之后，内建屏的槽位
    /// 会从枚举里消失，系统还会塞一块虚拟屏进来冒充在用。所以判据是
    /// isStranded（没有任何真屏在亮），恢复走 emergencyRestoreBuiltin 的三级降级。
    /// 可以在任意队列调用——只有刷新图标会回到主线程。
    private func restoreIfStranded() {
        guard Prefs.autoRestore else { return }
        guard controller.isStranded else {
            // 一切正常时顺手刷新记住的 ID，好在出事时还有得用
            controller.rememberDisplays()
            return
        }
        controller.emergencyRestoreBuiltin()
        DispatchQueue.main.async { [weak self] in self?.updateStatusIcon() }
    }

    // MARK: 提示

    private func notify(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 菜单栏 app，不进 Dock
app.run()
