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
只要还有别的屏亮着，就总能重新定位到内建屏。

（这个结论只在「还有别的屏亮着」时成立。物理屏全部消失时槽位也会一起消失，
那时就必须靠持久化的 ID 了，见下一节。）

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

恢复分三级降级：

1. 内建屏还在枚举里 —— 正常路径
2. 用记住的 ID 单独点亮（所以关屏前必须先把 ID 持久化下来）
3. 一个事务里批量 enable

**但真正决定成败的是快，不是用哪一级。** 恢复只在一个很窄的窗口里有效：拔线之后
display ID 很快就会失效，赶上了 enable 就管用，赶不上做什么都没用。所以第一步必须
零延迟把 enable 发出去，任何前置的慢动作（重新探测硬件、等状态落定）都等于放弃。
1.2 版就是在这里加了 4 秒等待，把本来一直正常的机器也弄成了恢复不了。

窗口一旦错过，针对 ID 的操作在部分机型上就全都无效了 —— 那时要靠[最后一招：睡眠 → 唤醒](#最后一招睡眠--唤醒)。

第 3 步还有两个容易踩错的地方：

**那批 ID 必须来自真实记录，绝不能靠猜范围。** `CGDirectDisplayID` 是不透明的 uint32，
有的 Mac 上是 `1`、`2`、`3`，有的机器上是 `69733248` 这种大数。按 `0..<40` 遍历在前者
碰巧有效，在后者则永远碰不到内建屏，恢复静默失败。所以趁枚举正常时要把见过的每个 ID
都持久化下来，恢复时用这份集合。

**`CGSCompleteDisplayConfiguration` 会撒谎。** 它经常返回 `kCGErrorIllegalArgument`
(1001)，而屏幕其实已经亮了。把这个返回码当成失败，结果就是弹出一个假的错误框，还中断了
一次本来已经成功的恢复 —— 所以要改成轮询真实状态，只有状态确实没变才算失败。

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

## 最后一招：睡眠 → 唤醒

有些机型（报告集中在 M3）掉进上面那个状态之后，**针对 display ID 的操作全都救不回来**。
实测无效的包括：

- 单独 enable 内建屏 ID（会话级 / 永久级），提交一律返回 `kCGErrorIllegalArgument`
- 批量 enable 见过的所有 ID，或 `0..40`
- `CGSDetectDisplays` 强制重新探测
- 关掉那块虚拟屏（事务成功，但系统立刻又建一块顶上）
- `CGRestorePermanentDisplayConfiguration`

诊断日志显示，App 在收到拔线回调后 **3 毫秒**就开始恢复了，而那一刻内建屏的槽位
已经从枚举里消失。所以这不是「反应慢」或「时机不对」——**系统里已经没有任何句柄
指向那块屏幕了**，用什么 API、什么时机都无关。

但那些机器上，**合盖再打开可以恢复**。这说明有效的是硬件级的重新初始化，
而不是任何针对 ID 的指令。于是就有了这一招——用软件跑一遍同样的电源状态切换：

```
pmset displaysleepnow      # 让显示器睡下去
（等 3 秒）
caffeinate -u -t 2         # 声明用户活动，把它唤醒
```

**在一台此前怎么都恢复不了的 M3 上验证通过**，约 6 秒后内建屏自己亮了回来。
全程不碰 display ID，走的是电源状态，跟合盖开盖是同一个机制。

App 把它放在恢复链的最后一级，并且只在**内建屏已经从枚举里消失**时才用——
合盖的时候内建屏还在（只是 `asleep`），那种情况下把机器唤醒是帮倒忙。
另外加了 30 秒冷却，免得每秒一次的看护把机器反复弄睡再唤醒。

### 一个隐蔽的坑：`CGDisplayIsActive` 会对失效的 ID 撒谎

这一招刚接进 App 时并不生效——脚本里跑得好好的，App 里却从来不执行。原因是判断成功
与否用的是：

```swift
CGDisplayIsActive(id) != 0
```

而这些 `boolean_t` 函数在 **ID 无效时返回 `0xFFFFFFFF`（错误码），不是 0 或 1**：

```
CGDisplayIsActive(99999) = 4294967295
```

`!= 0` 于是把错误当成了「屏幕亮着」，恢复链第一步就误判成功、直接返回，
后面真正管用的睡眠→唤醒永远轮不到。日志里整条恢复只花 0～300 毫秒
（光睡眠唤醒就要 6 秒）就是这么来的。

所以两处都得改：判断屏幕状态**以枚举结果为准**，别直接问这些函数；
真要用它们的返回值，只认 `== 1`，绝不写 `!= 0`。

万一睡眠唤醒也失败了：**合上笔记本盖子再打开**，或者把外接屏插回去。

## 已知副作用

关屏时，原本在内建屏上的窗口会被挪到外置屏；重新打开后**不会自动挪回去**。
这是 macOS 显示配置本身的行为，不是这个工具能控制的。

## 兼容性

在 macOS 27.0（M4 Pro，Apple Silicon）上实测通过。App 的部署目标是 macOS 13。
私有符号随时可能变，两个实现启动时都会检查，缺了会明确报错。

## License

MIT
