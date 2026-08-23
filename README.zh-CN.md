<div align="center">
  <img src="docs/icon.png" width="128" alt="DisplayToggle">
  <h1>DisplayToggle</h1>
  <p>接了外置显示器时，关掉 Mac 的内建屏幕。</p>
  <p><a href="README.md">English</a></p>
</div>

包含两个东西，共用同一套原理：

- **DisplayToggle.app** — 菜单栏 App（Swift / AppKit），日常用这个
- **displaytoggle.py** — 命令行版（Python + ctypes，零依赖），方便脚本调用

都不需要 root，不需要辅助功能权限，不改系统设置里的镜像和排列。

macOS 没有公开 API 能做这件事。这个工具建立在几个私有的 CoreGraphics / SkyLight 调用上，
而真正有意思的是围绕它们的一堆坑，都记在[原理](#原理)一节里。

## 安装

从 [Releases](../../releases) 下载 `.dmg`，把 App 拖进「应用程序」。

App 是 **ad-hoc 签名、没有公证的**（没有付费的 Apple 开发者账号），首次打开会被 Gatekeeper 拦下。
要么右键点 App 选「打开」，要么去掉隔离属性：

```bash
xattr -dr com.apple.quarantine /Applications/DisplayToggle.app
```

或者干脆自己编译，只要几秒钟，也只需要 Command Line Tools。

## 菜单栏 App

```
内建屏：开启
──────────────────────────────
关闭内建屏
关闭后主显示器移至「S2700」
把「S2700」设为主显示器
──────────────────────────────
显示器
✓ Built-in Retina Display · 3024×1964（主）
✓ S2700 · 3840×2160
──────────────────────────────
✓ 拔掉外置屏时自动恢复
  重启后保留屏幕状态
✓ 开机启动
──────────────────────────────
关于 DisplayToggle
退出                          ⌘Q
```

- **左键点击图标**：打开菜单
- **右键点击图标**：直接切换（快速通道）
- 图标本身就是状态：内建屏在用显示笔记本，只剩外接屏时显示显示器
- 显示器列表里，打勾的是正在显示画面的

三个开关：

| 选项 | 作用 |
| --- | --- |
| 拔掉外置屏时自动恢复 | 内建屏关着时外置屏断开，自动把内建屏开回来，避免全黑（默认开） |
| 重启后保留屏幕状态 | 用 `kCGConfigurePermanently` 提交，否则只对本次登录会话生效 |
| 开机启动 | 通过 `SMAppService` 注册登录项 |

### 构建

只需要 Xcode Command Line Tools，不用装 Xcode：

```bash
cd app
./build.sh        # 编译 App 和自测程序、生成图标、ad-hoc 签名
./makedmg.sh      # 可选：打一个可拖拽安装的 DMG
cp -R build/DisplayToggle.app /Applications/
```

### 自测

```bash
./app/build/selftest        # 会真的开关一次内建屏（需要接着外置屏）
./app/build/selftest --dry  # 只检查枚举和保护逻辑，不动屏幕
```

## 命令行版

```bash
displaytoggle.py              # 切换（默认）
displaytoggle.py --status     # 只列出显示器状态
displaytoggle.py --on
displaytoggle.py --off
displaytoggle.py --permanent  # 重启后保留
displaytoggle.py --force      # 没有其它点亮的屏时也允许关（会黑屏，慎用）
```

退出码：`0` 成功 / 已是目标状态，`1` 没有内建屏，`2` 被黑屏保护拦下，`3` 配置提交了但没在超时内生效。

## 原理

四个函数，来自 CoreGraphics / SkyLight：

| 函数 | 作用 |
| --- | --- |
| `CGSGetDisplayList` | 列出全部显示器槽位，**包括被禁用的** |
| `CGSBeginDisplayConfiguration` | 开一个配置事务（等价于公开的 `CGBeginDisplayConfiguration`） |
| `CGSConfigureDisplayEnabled` | 开/关某块屏 —— 公开 API 里没有对应物 |
| `CGSCompleteDisplayConfiguration` | 提交事务 |

符号在 `CoreGraphics.framework` 和 `SkyLight.framework` 里都能 `dlsym` 到（前者转发给后者）；
两个实现都优先加载 SkyLight，找不到再退回 CoreGraphics，全部缺失就直接报错退出而不是乱跑。

提交时的 `CGConfigureOption`：`1 = kCGConfigureForSession`（默认，重启复原），
`2 = kCGConfigurePermanently`。

### 关键的坑：关掉之后怎么再开回来

内建屏一被禁用，就从公开 API 的世界里彻底消失了：

| | `CGSGetDisplayList` | `CGGetOnlineDisplayList` | `CGDisplayIsOnline` | `CGDisplayIsBuiltin` | UUID |
| --- | --- | --- | --- | --- | --- |
| 启用时 | 含 id=1 | 含 id=1 | 1 | 1 | ok |
| **禁用时** | **仍含 id=1** | 不含 | 0 | **1** | NULL |

只用公开的 `CGGetOnlineDisplayList` 枚举的话，关掉之后就再也找不到那块屏，开不回来了。
私有的 `CGSGetDisplayList` 会保留槽位，而 `CGDisplayIsBuiltin` 对已禁用的槽位依然有效 ——
所以不需要把 display ID 缓存到磁盘，随时能重新定位内建屏。

`CGSGetDisplayList` 还会带出没接东西的空槽位（离线、非内建、尺寸 1×1、UUID 为 NULL），
必须过滤掉，否则会被误认成一块外置屏，黑屏保护就失效了。

### 更大的坑：失去全部物理屏时，系统会伪造一块虚拟屏

内建屏关着的时候再把外置屏拔掉，macOS 会同时做两件事：

- **内建屏和外置屏的槽位一起从 `CGSGetDisplayList` 消失**
- **塞一块虚拟屏进来顶替**，`active=1`、`online=1`、1920×1080，
  vendor / model 是 ASCII 魔数 `0x756e6b6e` = `"unkn"`、`0x76697274` = `"virt"`

这会让天真的黑屏保护完全失效：内建屏枚举不到（拿不到 ID 去恢复），而那块虚拟屏
`builtin=0 && active=1`，看起来就像「还有一块外置屏亮着」，于是判定为不需要恢复 ——
结果就是用户对着全黑的屏幕。

所以判据不能是「内建屏关着且没有外置屏」，必须是 **`isStranded`：没有任何真屏在亮**，
其中「真屏」要排除掉虚拟屏。

更麻烦的是，掉进这个状态之后私有接口本身也变得不可靠：**对记住的内建屏 ID 单独调
`CGSConfigureDisplayEnabled` 实测毫无效果**，只有在一个事务里把一批 ID 全部 enable
才能把内建屏拉回来。所以恢复要分三级降级：

1. 内建屏还在枚举里 —— 正常路径
2. 用记住的 ID 单独点亮（所以关屏前必须先把 ID 持久化下来）
3. 一个事务里批量 enable 所有 ID（唯一在无物理屏状态下验证有效的办法）

### 黑屏保护

1. 关屏前检查至少还有一块**真屏**亮着，否则拒绝（命令行版可用 `--force` 跳过）
2. 三重触发：`CGDisplayRegisterReconfigurationCallback`（CoreGraphics 级，比 AppKit 通知靠得住）
   \+ `didChangeScreenParametersNotification` + **1 秒轮询兜底**。极端状态下前两者都可能失灵，
   轮询是最后一道保险，代价只是每秒几个 CG 调用
3. 一旦 `isStranded`，走上面的三级降级恢复
4. App 退出时如果处于黑屏状态，先恢复再退出

判断「点亮」用的是 `isActive && !isAsleep && !isVirtual` —— 合盖时内建屏是 asleep 而不是
disabled，虚拟屏则是 active 但没有物理输出，三者要分开处理。

### 主显示器

内建屏如果正是主显示器，关掉它之后主显示器会自动转移到外置屏，菜单栏和 Dock 跟着搬家。
API 层面这是成功的（不会报错），但对用户是个意外，所以菜单里会提前说明，并给一个
一键把外置屏设为主显示器的入口。

macOS 没有「设为主屏」的直接接口，做法是把目标屏的原点挪到 `(0,0)`、其余屏按相同位移平移
（`CGConfigureDisplayOrigin`，公开 API），相对排列不变，只是换了谁在原点。

## 已知副作用

关屏时，原本在内建屏上的窗口会被挪到外置屏；重新打开后**不会自动挪回去**。
这是 macOS 显示配置本身的行为，不是这个工具能控制的。

## 兼容性

在 macOS 27.0（M4 Pro，Apple Silicon）上实测通过。App 的部署目标是 macOS 13。
私有符号随时可能变，两个实现启动时都会检查，缺了会明确报错。

## License

MIT
