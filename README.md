<div align="center">
  <img src="docs/icon.png" width="128" alt="DisplayToggle">
  <h1>DisplayToggle</h1>
  <p>Turn off your Mac's built-in display while an external monitor stays on.</p>
  <p><a href="README.zh-CN.md">中文文档</a></p>
</div>

A tiny menu bar app (plus a zero-dependency CLI) that enables and disables the internal
display of a Mac. No root, no Accessibility permission, and it doesn't touch your mirroring
or arrangement settings.

macOS has no public API for this. It's built on a handful of private CoreGraphics / SkyLight
calls — the interesting part is everything that goes wrong around them, documented in
[How it works](#how-it-works).

## Menu bar app

```
Built-in display: On
──────────────────────────────
Turn off built-in display
Main display will move to “S2700”
Make “S2700” the main display
──────────────────────────────
Displays
✓ Built-in Retina Display · 3024×1964 (main)
✓ S2700 · 3840×2160
──────────────────────────────
✓ Restore when external display is unplugged
  Keep across restarts
✓ Launch at login
──────────────────────────────
About DisplayToggle
Quit                          ⌘Q
```

- **Left click** the icon — open the menu
- **Right click** the icon — toggle straight away
- The icon *is* the state: a laptop when the built-in display is on, a monitor when it's off
- A checkmark in the display list means that display is actually showing a picture

| Option | What it does |
| --- | --- |
| Restore when external display is unplugged | If the external display goes away while the built-in one is off, turn the built-in display back on so you're never left staring at a black screen (**on by default**) |
| Keep across restarts | Commit with `kCGConfigurePermanently` instead of session-only |
| Launch at login | Registers a login item via `SMAppService` |

## Install

Grab the `.dmg` from [Releases](../../releases) and drag the app to Applications.

The app is **ad-hoc signed and not notarized** (no paid Apple Developer account), so Gatekeeper
will refuse to open it on first launch. Either right-click the app and choose **Open**, or strip
the quarantine attribute:

```bash
xattr -dr com.apple.quarantine /Applications/DisplayToggle.app
```

Or just build it yourself — it takes a few seconds and only needs the Command Line Tools.

## Build

No Xcode required, only the Xcode Command Line Tools:

```bash
cd app
./build.sh        # compiles the app + self-test, generates the icon, ad-hoc signs
./makedmg.sh      # optional: package a drag-to-install DMG
cp -R build/DisplayToggle.app /Applications/
```

## Self-test

The tricky part of this project isn't the UI, it's whether the private calls behave. There's a
headless test binary for exactly that:

```bash
./app/build/selftest        # actually toggles the display once (needs an external display attached)
./app/build/selftest --dry  # enumeration and safety checks only, doesn't touch your screens
```

## CLI

`displaytoggle.py` needs nothing but the system Python:

```bash
displaytoggle.py              # toggle (default)
displaytoggle.py --status     # list displays
displaytoggle.py --on
displaytoggle.py --off
displaytoggle.py --permanent  # survive a restart
displaytoggle.py --force      # allow turning it off with no other display lit (goes black — careful)
```

Exit codes: `0` done or already in the requested state, `1` no built-in display,
`2` refused by the black-screen guard, `3` submitted but didn't take effect in time.

## How it works

Four functions, from CoreGraphics / SkyLight:

| Function | Role |
| --- | --- |
| `CGSGetDisplayList` | List every display slot, **including disabled ones** |
| `CGSBeginDisplayConfiguration` | Open a configuration transaction (same as the public `CGBeginDisplayConfiguration`) |
| `CGSConfigureDisplayEnabled` | Enable/disable a display — no public equivalent exists |
| `CGSCompleteDisplayConfiguration` | Commit |

All four `dlsym` fine out of either `CoreGraphics.framework` or `SkyLight.framework` (the former
forwards to the latter). Both implementations here try SkyLight first and fall back to
CoreGraphics; if the symbols are gone they fail loudly at startup instead of misbehaving.

`CGConfigureOption` on commit: `1 = kCGConfigureForSession` (default, reverts on restart),
`2 = kCGConfigurePermanently`.

### Trap 1: a disabled display vanishes from the public API

The moment the built-in display is disabled, it drops out of the public world entirely:

| | `CGSGetDisplayList` | `CGGetOnlineDisplayList` | `CGDisplayIsOnline` | `CGDisplayIsBuiltin` | UUID |
| --- | --- | --- | --- | --- | --- |
| Enabled | has id=1 | has id=1 | 1 | 1 | ok |
| **Disabled** | **still has id=1** | absent | 0 | **1** | NULL |

Enumerate with the public `CGGetOnlineDisplayList` and you can never find that display again —
you've turned it off and lost the handle to turn it back on. The private `CGSGetDisplayList`
keeps the slot, and `CGDisplayIsBuiltin` still answers correctly for a disabled slot, so the
display stays locatable.

`CGSGetDisplayList` also reports empty slots with nothing plugged in (offline, non-builtin,
1×1, NULL UUID). Filter them out, or the black-screen guard will think there's an external
display attached when there isn't.

### Trap 2: losing every physical display conjures a fake one

Unplug the external display while the built-in one is off and macOS does two things at once:

- **Both display slots disappear from `CGSGetDisplayList` together**
- **A virtual display is inserted to stand in** — `active=1`, `online=1`, 1920×1080, with
  vendor / model set to the ASCII magic numbers `0x756e6b6e` (`"unkn"`) and `0x76697274` (`"virt"`)

That defeats a naive guard from both directions: the built-in display can't be enumerated (no ID
to restore), and the fake display looks like `builtin=0 && active=1` — i.e. "an external display
is still lit" — so nothing gets restored. The user is left with a black screen.

So the condition to check is not "built-in is off and there's no external display". It has to be
**`isStranded`: no *real* display is lit**, where "real" excludes the virtual one.

Recovery is a three-stage fallback:

1. Built-in display still enumerable — normal path
2. Enable the remembered ID directly (so the ID must be persisted *before* turning it off)
3. Batch-enable in one transaction

**What decides success is speed, not which stage you reach.** Recovery only works inside a
narrow window: the display IDs go invalid moments after the unplug, and once they do, nothing
works. So the first `enable` must go out with zero delay — any slow step ahead of it
(re-detecting hardware, waiting for state to settle) amounts to giving up. Version 1.2 put a
four second wait there and broke machines that had always recovered fine.

Miss the window and on some machines it is unrecoverable — see [Known issue](#known-issue-some-macs-cannot-auto-recover-after-an-unplug).

Two things about stage 3 that are easy to get wrong:

**The IDs must come from a real record, never from guessing a range.** `CGDirectDisplayID` is
opaque. On some Macs it is `1`, `2`, `3`; on others it is `69733248`. Iterating `0..<40` works
on the former and silently never touches the built-in display on the latter. So every ID the
app has seen is persisted while enumeration still works, and recovery uses that set.

**`CGSCompleteDisplayConfiguration` lies.** It routinely returns `kCGErrorIllegalArgument`
(1001) *while the display does come back on*. Treating that return code as failure produces
a bogus error dialog and aborts a recovery that actually worked — so the real display state is
polled instead, and only a genuinely unchanged state counts as a failure.

### Black-screen protection

1. Refuse to turn the display off unless another **real** display is lit (`--force` overrides in the CLI)
2. Three independent triggers: `CGDisplayRegisterReconfigurationCallback` (CoreGraphics level,
   more dependable than the AppKit notification), `didChangeScreenParametersNotification`, and a
   **1-second poll as a backstop** — in the degenerate state above the first two can both go quiet,
   and the poll costs a few CG calls per second
3. On `isStranded`, run the three-stage recovery
4. On quit, restore first if the screen would be left black

"Lit" means `isActive && !isAsleep && !isVirtual`. A closed lid makes the built-in display
*asleep*, not disabled, and the virtual display is *active* with no physical output — three
distinct states that must not be conflated.

### Main display

If the built-in display happens to be the main one, turning it off moves the main display —
and with it the menu bar and Dock — to the external monitor. The API call succeeds, but it
surprises people, so the menu says so up front and offers to switch the main display first.

macOS has no "make this the main display" call. The trick is to move the target display's origin
to `(0,0)` and translate every other display by the same offset (`CGConfigureDisplayOrigin`,
a public API), leaving the relative arrangement intact.

## Known issue: some Macs cannot auto-recover after an unplug

**The failure reports so far are concentrated on M3 machines.**

On those, unplugging the external display while the built-in one is off leaves the screen
black, and no software approach brings it back. In that state the display IDs are simply
invalid, and all of the following were measured to fail:

- Enabling the built-in display ID alone (session or permanent) — the commit returns
  `kCGErrorIllegalArgument` even when the transaction touches nothing else
- Batch-enabling every known ID, or `0..40`
- `CGSDetectDisplays` to force a hardware rescan
- Disabling the virtual display (the transaction succeeds; the system immediately makes another)
- `CGRestorePermanentDisplayConfiguration`

**If you hit the black screen: close the lid and open it again.** That is a hardware-level
display re-enumeration and is the only method confirmed to work. Plugging the external
display back in also works.

The likely explanation is that the display coprocessor on these machines releases the
built-in framebuffer once every physical display is gone, leaving nothing for software to
re-acquire — so only a real hardware event re-initialises it. **This remains unconfirmed.**

If this affects you, enable **Diagnostic log** in the menu, reproduce, and attach
`~/Library/Logs/DisplayToggle.log` to an issue — it records the chip and model.

## Known caveat

Turning the display off relocates its windows to the other monitor, and turning it back on
**does not move them back**. That's macOS behavior, not something this tool controls.

## Compatibility

Verified on macOS 27.0 (M4 Pro, Apple Silicon). The app targets macOS 13 and up. Private symbols
can disappear at any release; both implementations check at startup and fail with a clear message.

## License

MIT
