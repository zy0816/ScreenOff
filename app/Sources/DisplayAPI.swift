//
//  DisplayToggle — 显示器控制核心
//
//  用 SkyLight 的私有显示配置接口。关键点见 README：
//  内建屏被禁用后会从公开的 CGGetOnlineDisplayList 里消失，只有私有的
//  CGSGetDisplayList 保留槽位，而 CGDisplayIsBuiltin 对已禁用的槽位依然有效。
//

import AppKit

// MARK: - 私有 API

private typealias GetDisplayListFn = @convention(c) (
    UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?
) -> CGError
private typealias BeginConfigFn = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?) -> CGError
private typealias ConfigureEnabledFn = @convention(c) (OpaquePointer?, CGDirectDisplayID, Bool) -> CGError
private typealias CompleteConfigFn = @convention(c) (OpaquePointer?, UInt32) -> CGError
private typealias CancelConfigFn = @convention(c) (OpaquePointer?) -> CGError
private typealias DetectDisplaysFn = @convention(c) () -> CGError

/// CGConfigureOption
private let kConfigureForSession: UInt32 = 1
private let kConfigurePermanently: UInt32 = 2

enum DisplayAPIError: LocalizedError {
    case symbolsMissing
    case callFailed(String, CGError)

    var errorDescription: String? {
        switch self {
        case .symbolsMissing:
            return "这个 macOS 版本上找不到需要的私有显示配置接口。"
        case let .callFailed(name, code):
            return "\(name) 失败（CGError \(code.rawValue)）。"
        }
    }
}

/// SkyLight 私有接口的封装。
final class DisplayAPI {
    static let shared = DisplayAPI()

    private let getDisplayList: GetDisplayListFn?
    private let beginConfig: BeginConfigFn?
    private let configureEnabled: ConfigureEnabledFn?
    private let completeConfig: CompleteConfigFn?
    private let cancelConfig: CancelConfigFn?
    private let detect: DetectDisplaysFn?

    var isAvailable: Bool {
        getDisplayList != nil && beginConfig != nil
            && configureEnabled != nil && completeConfig != nil
    }

    private init() {
        // CoreGraphics 把这些符号转发给 SkyLight；优先直接开 SkyLight，失败再退回。
        var handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        if handle == nil {
            handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
        }
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        getDisplayList = sym("CGSGetDisplayList", as: GetDisplayListFn.self)
        beginConfig = sym("CGSBeginDisplayConfiguration", as: BeginConfigFn.self)
        configureEnabled = sym("CGSConfigureDisplayEnabled", as: ConfigureEnabledFn.self)
        completeConfig = sym("CGSCompleteDisplayConfiguration", as: CompleteConfigFn.self)
        cancelConfig = sym("CGCancelDisplayConfiguration", as: CancelConfigFn.self)
        detect = sym("CGSDetectDisplays", as: DetectDisplaysFn.self)
    }

    /// 全部显示器槽位，含被禁用的；已滤掉没接东西的空槽。
    func displays() -> [DisplayInfo] {
        guard let getDisplayList else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        let rc = ids.withUnsafeMutableBufferPointer { buf in
            getDisplayList(32, buf.baseAddress, &count)
        }
        guard rc == .success else { return [] }
        return ids.prefix(Int(count)).map(DisplayInfo.init).filter { !$0.isPhantom }
    }

    func setEnabled(_ enabled: Bool, for id: CGDirectDisplayID, permanent: Bool) throws {
        guard let beginConfig, let configureEnabled, let completeConfig else {
            throw DisplayAPIError.symbolsMissing
        }
        var config: OpaquePointer?
        var rc = beginConfig(&config)
        guard rc == .success else { throw DisplayAPIError.callFailed("CGSBeginDisplayConfiguration", rc) }

        rc = configureEnabled(config, id, enabled)
        guard rc == .success else {
            _ = cancelConfig?(config)
            throw DisplayAPIError.callFailed("CGSConfigureDisplayEnabled", rc)
        }

        rc = completeConfig(config, permanent ? kConfigurePermanently : kConfigureForSession)
        // 提交的返回码不可信：显示器拓扑异常时它经常返回 kCGErrorIllegalArgument(1001)，
        // 而屏幕其实已经亮了。所以以真实状态为准，只有状态确实没变才当失败。
        if rc != .success, !Self.waitForActive(id, enabled) {
            throw DisplayAPIError.callFailed("CGSCompleteDisplayConfiguration", rc)
        }
    }

    /// 轮询等某块屏的开关状态落定。显示配置是异步生效的。
    static func waitForActive(_ id: CGDirectDisplayID, _ want: Bool,
                              timeout: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (CGDisplayIsActive(id) != 0) == want { return true }
            usleep(150_000)
        }
        return (CGDisplayIsActive(id) != 0) == want
    }

    /// 让 WindowServer 重新探测显示器硬件，相当于旧版系统设置里的「检测显示器」。
    ///
    /// 这是掉进无物理屏状态后唯一还讲得通的路子：那时候所有 display ID 都已失效，
    /// 连只针对内建屏 ID 的事务都会被 kCGErrorIllegalArgument 拒掉，
    /// 光靠 enable 谁都没用，得先让系统重新发现硬件。
    @discardableResult
    func detectDisplays() -> Bool {
        guard let detect else { return false }
        return detect() == .success
    }

    /// 应急：一个事务里把给定的一批 ID 全部点亮。
    ///
    /// 掉进「无物理屏」状态后，内建屏的槽位从 CGSGetDisplayList 里消失。
    ///
    /// 注意：这一步不一定有用。在开发机上它曾把内建屏拉回来过，但另一台机器实测
    /// 表明，那时候连只针对内建屏 ID 的事务都会被 kCGErrorIllegalArgument 拒掉——
    /// display ID 本身已经失效，enable 谁都没用（开发机那次很可能是先前调用的
    /// CGRestorePermanentDisplayConfiguration 延迟生效，被误记在了这一步头上）。
    /// 所以真正的指望在 detectDisplays()，这里只作为最后的尝试保留。
    ///
    /// 注意 ID 必须由调用方给出真实值，不能靠猜范围：CGDirectDisplayID 是不透明的
    /// uint32，某些机器上是 1、2、3 这样的小数字，另一些机器上是 69733248 这类大数，
    /// 按 0..<40 遍历在后者上永远碰不到真正的内建屏。
    ///
    /// 返回码不可靠（常见 kCGErrorIllegalArgument 但屏幕实际亮了），
    /// 所以这里不看返回值，由调用方轮询真实状态判断成败。
    func forceEnable(_ ids: [CGDirectDisplayID]) {
        guard let beginConfig, let configureEnabled, let completeConfig else { return }
        guard !ids.isEmpty else { return }
        var config: OpaquePointer?
        guard beginConfig(&config) == .success else { return }
        for id in ids {
            _ = configureEnabled(config, id, true)
        }
        _ = completeConfig(config, kConfigureForSession)
    }
}

// MARK: - 显示器信息

struct DisplayInfo {
    /// 失去全部物理屏时，系统会造一块虚拟屏顶上，vendor/model 是 ASCII 魔数
    /// "unkn" / "virt"。它 active=1、online=1、1920×1080，但没有任何物理输出——
    /// 把它当成一块真屏，黑屏保护就会以为"还有屏亮着"而不去恢复内建屏。
    static let virtualVendor: UInt32 = 0x756e_6b6e  // "unkn"
    static let virtualModel: UInt32 = 0x7669_7274   // "virt"

    let id: CGDirectDisplayID
    let isBuiltin: Bool
    let isActive: Bool
    let isOnline: Bool
    let isAsleep: Bool
    let isMain: Bool
    let width: Int
    let height: Int
    let vendor: UInt32
    let model: UInt32

    init(_ id: CGDirectDisplayID) {
        self.id = id
        isBuiltin = CGDisplayIsBuiltin(id) != 0
        isActive = CGDisplayIsActive(id) != 0
        isOnline = CGDisplayIsOnline(id) != 0
        isAsleep = CGDisplayIsAsleep(id) != 0
        isMain = CGDisplayIsMain(id) != 0
        vendor = CGDisplayVendorNumber(id)
        model = CGDisplayModelNumber(id)
        if let mode = CGDisplayCopyDisplayMode(id) {
            width = mode.pixelWidth
            height = mode.pixelHeight
        } else {
            width = CGDisplayPixelsWide(id)
            height = CGDisplayPixelsHigh(id)
        }
    }

    /// 系统伪造的虚拟屏，不是真实的物理输出。
    var isVirtual: Bool {
        !isBuiltin && vendor == Self.virtualVendor && model == Self.virtualModel
    }

    /// CGSGetDisplayList 会带出没接东西的空槽位：离线、非内建、尺寸 1×1。
    var isPhantom: Bool { !isBuiltin && !isOnline && width <= 1 }

    /// 真正在显示画面（合盖时内建屏是 asleep，不算；虚拟屏没有物理输出，也不算）。
    var isLit: Bool { isActive && !isAsleep && !isVirtual }

    var localizedName: String {
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) {
            return screen.localizedName
        }
        return isBuiltin ? "内建显示器" : "显示器 \(id)"
    }

    var stateText: String {
        if isAsleep { return "休眠" }
        if isActive { return "使用中" }
        return isOnline ? "未启用" : "已关闭"
    }
}

// MARK: - 控制器

final class DisplayController {
    private let api = DisplayAPI.shared
    private static let rememberedIDKey = "lastKnownBuiltinDisplayID"
    private static let knownIDsKey = "knownDisplayIDs"

    var displays: [DisplayInfo] { api.displays() }
    var builtin: DisplayInfo? { displays.first(where: \.isBuiltin) }
    var externalsLit: [DisplayInfo] { displays.filter { !$0.isBuiltin && $0.isLit } }

    var isBuiltinOn: Bool { builtin?.isActive ?? false }
    var hasExternal: Bool { !externalsLit.isEmpty }

    /// 关掉内建屏是否安全 —— 至少还得有一块真屏亮着，否则就是黑屏。
    var canTurnOff: Bool { hasExternal }

    /// 一块真实亮着的屏都没有：要么已经黑屏，要么只剩系统伪造的虚拟屏。
    var isStranded: Bool { !displays.contains(where: \.isLit) }

    /// 内建屏的 ID。掉进无物理屏状态后它会从枚举里消失，只能靠记住的值。
    private(set) var rememberedBuiltinID: CGDirectDisplayID? {
        get {
            let v = UserDefaults.standard.integer(forKey: Self.rememberedIDKey)
            return v > 0 ? CGDirectDisplayID(v) : nil
        }
        set { UserDefaults.standard.set(Int(newValue ?? 0), forKey: Self.rememberedIDKey) }
    }

    /// 见过的所有 display ID。掉进无物理屏状态后枚举会变空，这份记录是唯一的线索。
    private(set) var rememberedIDs: [CGDirectDisplayID] {
        get {
            (UserDefaults.standard.array(forKey: Self.knownIDsKey) as? [Int] ?? [])
                .filter { $0 > 0 }.map(CGDirectDisplayID.init)
        }
        set {
            UserDefaults.standard.set(newValue.map(Int.init), forKey: Self.knownIDsKey)
        }
    }

    /// 趁枚举还正常，把内建屏 ID 和见过的所有 ID 都记下来。
    func rememberDisplays() {
        if let builtin { rememberedBuiltinID = builtin.id }
        let seen = displays.filter { !$0.isVirtual }.map(\.id)
        guard !seen.isEmpty else { return }
        rememberedIDs = Array(Set(rememberedIDs).union(seen)).sorted()
    }

    @discardableResult
    func setBuiltin(_ on: Bool, permanent: Bool) throws -> Bool {
        guard let builtin else { return false }
        guard builtin.isActive != on else { return false }
        try api.setEnabled(on, for: builtin.id, permanent: permanent)
        return true
    }

    /// 把某块屏设为主显示器（菜单栏和 Dock 所在的那块）。
    ///
    /// macOS 没有「设为主屏」的直接接口，做法是把目标屏的原点挪到 (0,0)，
    /// 其余屏按相同位移平移，这样相对排列不变，只是换了谁在原点。
    /// 这里用的都是公开 API。
    func makeMain(_ target: DisplayInfo) throws {
        var config: CGDisplayConfigRef?
        var rc = CGBeginDisplayConfiguration(&config)
        guard rc == .success else { throw DisplayAPIError.callFailed("CGBeginDisplayConfiguration", rc) }

        let offset = CGDisplayBounds(target.id).origin
        for d in displays where d.isOnline {
            let origin = CGDisplayBounds(d.id).origin
            rc = CGConfigureDisplayOrigin(
                config, d.id,
                Int32(origin.x - offset.x), Int32(origin.y - offset.y)
            )
            guard rc == .success else {
                CGCancelDisplayConfiguration(config)
                throw DisplayAPIError.callFailed("CGConfigureDisplayOrigin", rc)
            }
        }

        rc = CGCompleteDisplayConfiguration(config, .permanently)
        guard rc == .success else { throw DisplayAPIError.callFailed("CGCompleteDisplayConfiguration", rc) }
    }

    /// 已经没有任何真屏亮着了，尽一切办法把内建屏拉回来。
    ///
    /// 分三级，因为在这个状态下私有接口的行为很不可靠：
    ///   1. 内建屏还在枚举里 —— 正常路径
    ///   2. 用记住的 ID 单独点亮
    ///   3. 批量点亮所有 ID（实测唯一在无物理屏状态下有效的办法）
    func emergencyRestoreBuiltin() {
        // 恢复是个极窄的窗口：拔线之后 display ID 很快就会失效，赶上了 enable 就管用，
        // 赶不上做什么都没用。所以第一步必须零延迟——先把 enable 发出去，
        // 别在它前面放任何慢动作（探测硬件、等状态落定都算慢动作）。
        //
        // forceEnable 不看返回值也不等待，正合适：提交码本来就不可信，
        // 成没成看后面轮询真实状态就行。
        var quick = Set<CGDirectDisplayID>()
        if let builtin, !builtin.isActive { quick.insert(builtin.id) }
        if let id = rememberedBuiltinID { quick.insert(id) }
        if !quick.isEmpty {
            api.forceEnable(Array(quick))
            if let id = rememberedBuiltinID ?? quick.first,
               DisplayAPI.waitForActive(id, true, timeout: 1.0) { return }
        }

        // 到这儿说明窗口已经错过了，才轮到这些慢办法碰运气。
        api.detectDisplays()
        if let id = rememberedBuiltinID,
           DisplayAPI.waitForActive(id, true, timeout: 3.0) { return }

        api.forceEnable(recoveryCandidates())
    }

    /// 批量恢复要用的 ID 集合。
    ///
    /// 真实记录优先：见过的 ID + 记住的内建屏 ID + 当前还枚举得到的 ID。
    /// 末尾补一段小范围仅仅是兜底（万一偏好被清空过），不能指望它——
    /// CGDirectDisplayID 是不透明的 uint32，很多机器上根本不是小整数。
    private func recoveryCandidates() -> [CGDirectDisplayID] {
        var ids = Set(rememberedIDs)
        if let id = rememberedBuiltinID { ids.insert(id) }
        ids.formUnion(displays.map(\.id))
        ids.formUnion((0..<40).map(CGDirectDisplayID.init))
        return Array(ids).sorted()
    }
}
