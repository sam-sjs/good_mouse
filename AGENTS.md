# AGENTS.md

Project instructions for `good_mouse`. Read this before touching code.

While the project is being built there is a local `docs/PLAN.md` holding the build order and phase
gates. It is gitignored and deleted on completion, so it is absent from a fresh clone and absent once
the work is done — check for it, but do not expect it. Everything durable lives in this file.

---

## What this is

A lightweight macOS CLI daemon that sets pointer/scroll sensitivity and acceleration for a trackball
that **Karabiner-Elements has seized** — the case off-the-shelf pointer utilities cannot handle.

No GUI. No event tap. No kext or system extension. No Accessibility permission.

## The problem, and why the fix looks the way it does

1. Karabiner **seizes** the ELECOM DEFT Pro. Verifiable in `/var/log/karabiner/core_service.log`:
   `DEFT Pro TrackBall (device_id:…) hid queue value monitor is started (grabbed).`
2. It re-emits the manipulated stream through **`Karabiner DriverKit VirtualHIDPointing 1.8.0`**.
3. Pointer sensitivity on macOS is not applied by intercepting events. It is applied by the kernel's
   per-device acceleration filter, configured through `IOHIDServiceClientSetProperty` on a device's
   HID service. Tuning the **physical** trackball therefore does nothing while Karabiner holds it — the
   settings land on a device that emits nothing.
4. The obvious next move — tune the virtual device instead — is what off-the-shelf utilities cannot do.
   They identify devices as vendor-product-**transport** (e.g. `56e-132-0-USB`), and the Karabiner
   virtual device publishes **no `Transport` property at all**, so it can never form a key and never
   appears in their device lists.

**We fix (4)** by matching on **HID usage** rather than transport. The virtual device is fully live in
the HID event system (`DeviceOpenedByEventSystem = Yes`, `HIDPointerAccelerationType` published by
`IOHIDPointerScrollFilter`, `PrimaryUsagePage 1 / PrimaryUsage 2`), so it can be tuned like any mouse.

Verify the missing transport at any time — this returns `0`:

```sh
ioreg -c IOHIDDevice -r -l | awk '/VirtualHIDPointing/,/^ *$/' | grep -c '"Transport"'
```

### `ioreg` prints these keys twice, and the copies disagree

A property we write shows up in two places under the same device, and **grepping the wrong one gives
a confident false negative.** Measured directly: with a service override of `HIDScrollResolution =
777` in force and read back correctly by `goodmouse status`, the standalone entry showed
`50921472` (777) while the copy nested inside the `HIDEventServiceProperties` dictionary still showed
`589824` (9).

The standalone entry tracked the live override; the `HIDEventServiceProperties` copy was stale. So
prefer `goodmouse status`, which reads through `IOHIDServiceClientCopyProperty` — the same path the
filter uses. Reach for `ioreg` only as an independent cross-check, and when you do, know which of the
two you have matched.

### Do not try to intercept upstream of Karabiner

This was investigated and rejected. Do not reopen it without new information.

- A HID interface opens as a **unit**. The DEFT Pro's Mouse interface carries motion, buttons 1–8 and
  the wheel in one report. Seizing it to filter motion also takes buttons 4–8 from Karabiner and breaks
  the user's "ELECOM DEFT Pro TrackBall: Fn2 layer" rule.
- Re-injecting buttons lands *downstream* of Karabiner's manipulators, so it does not restore the rule.
- Genuinely being upstream means publishing our own DriverKit virtual HID device for Karabiner to grab:
  an Apple-granted DriverKit entitlement, a system extension, notarization.
- It is also unnecessary — macOS applies pointer acceleration *after* Karabiner, on the virtual device.
  That is where the curve belongs.

### Consequences worth knowing

- All pointing devices Karabiner grabs merge into the one virtual device and therefore **share one
  profile**. To tune a device separately, set `ignore: true` for it in Karabiner so it keeps its own HID
  service — it then loses Karabiner's pointing-button remapping but keeps keyboard/consumer remapping.
- The DEFT Pro's Bluetooth and wireless-dongle identities both merge into the virtual device, so **one
  profile covers both transports** — no per-transport duplication.

---

## Verified API reference

Everything below was read from the macOS 26.5.2 SDK, Apple's published IOHIDFamily source, or the
shipping binary on this machine. **Do not re-derive from memory — recall is wrong here.** Re-verify at
the cited paths if in doubt.

### Public SDK keys

`$(xcrun --show-sdk-path)/System/Library/Frameworks/IOKit.framework/Headers/`

| Constant | Literal | Header |
|---|---|---|
| `kIOHIDPointerResolutionKey` | `HIDPointerResolution` | `hidsystem/IOHIDParameter.h` |
| `kIOHIDPointerAccelerationTypeKey` | `HIDPointerAccelerationType` | `hid/IOHIDEventServiceKeys.h` |
| `kIOHIDMouseAccelerationTypeKey` | `HIDMouseAcceleration` | `hid/IOHIDEventServiceKeys.h` |
| `kIOHIDPointerAccelerationKey` | `HIDPointerAcceleration` | `hid/IOHIDEventServiceKeys.h` |
| `kIOHIDUseLinearScalingMouseAccelerationKey` | `HIDUseLinearScalingMouseAcceleration` | `hid/IOHIDEventServiceKeys.h` |
| `kIOHIDPointerAccelerationMinimumKey` | `HIDPointerAccelerationMinimum` | IOHIDFamily `IOHIDKeys.h` |
| `kIOHIDScrollResolutionKey` | `HIDScrollResolution` | `hid/IOHIDEventServiceKeys.h` |
| `kHIDAccelGainLinearKey` | `HIDAccelGainLinear` | `hidsystem/IOHIDParameter.h` |
| `kHIDAccelGainParabolicKey` | `HIDAccelGainParabolic` | `hidsystem/IOHIDParameter.h` |
| `kHIDAccelGainCubicKey` | `HIDAccelGainCubic` | `hidsystem/IOHIDParameter.h` |
| `kHIDAccelGainQuarticKey` | `HIDAccelGainQuartic` | `hidsystem/IOHIDParameter.h` |
| `kHIDAccelTangentSpeedLinearKey` | `HIDAccelTangentSpeedLinear` | `hidsystem/IOHIDParameter.h` |
| `kHIDAccelTangentSpeedParabolicRootKey` | `HIDAccelTangentSpeedParabolicRoot` | `hidsystem/IOHIDParameter.h` |
| `kHIDAccelIndexKey` | `HIDAccelIndex` | `hidsystem/IOHIDParameter.h` |

### SPI keys — not in any header

String literals confirmed by dumping
`/System/Library/HIDPlugins/IOHIDPointerScrollFilter.plugin/Contents/MacOS/IOHIDPointerScrollFilter`:

| Constant | Literal |
|---|---|
| `kIOHIDUserPointerAccelCurvesKey` | `UserPointerAccelCurvesKey` |
| `kIOHIDUserScrollAccelCurvesKey` | `UserScrollAccelCurvesKey` |
| `kIOHIDPointerAccelerationAlgorithmKey` | `HIDPointerAccelerationAlgorithm` |
| `kIOHIDScrollAccelerationAlgorithmKey` | `HIDScrollAccelerationAlgorithm` |
| `kIOHIDServiceFilterDebugKey` | `ServiceFilterDebug` |

> The user-curve keys are **not** prefixed `HID`. That is genuinely surprising and easy to "correct"
> into something wrong.

`HIDPointerAccelerationAlgorithm`: `0` = table, `1` = parametric, `2` = default.

`ServiceFilterDebug` is readable via `IOHIDServiceClientCopyProperty`, but **it does not do the job it
looks like it does.** Every filter in a service's chain answers that key with its own serialised
state, and the first responder wins. On this machine that is `IOHIDEventProcessorFilter`, which
shadows `IOHIDPointerScrollFilter` completely — so the read succeeds, returns a plausible-looking
dictionary, and says nothing whatsoever about acceleration.

**Use the unified log instead.** `IOHIDPointerScrollFilter` logs one line per axis every time it
rebuilds:

```sh
/usr/bin/log show --last 60s --info --style compact \
  --predicate 'subsystem == "com.apple.iohid" AND eventMessage CONTAINS "acceleration"'
```

```
Pointer acceleration (enabled) HIDMouseAcceleration:45056 HIDMouseAcceleration:(null) HIDPointerAcceleration:(null) 45056
```

`enabled` vs `disabled` is `_pointerAcceleration >= 0` — i.e. whether an accelerator was built at all.
The first key named is the one the filter resolved the value from. `goodmouse status --filter-debug`
runs this query.

Three traps in that one command:

- **`--info` is required.** These are `Df` records; without it the query returns nothing and reads as
  a negative result.
- **`/usr/bin/log`, by absolute path.** zsh has a `log` builtin that shadows it, consumes the
  arguments, exits 0 and prints nothing. It looks exactly like "the filter logged nothing".
- **The filter runs inside WindowServer**, so the lines are attributed to that process, not to
  `goodmouse` or `hidd`.

### Functions

More is public than expected. On the macOS 26.5 SDK, `IOKit/hidsystem/IOHIDServiceClient.h` and
`IOKit/hidsystem/IOHIDEventSystemClient.h` both ship as public headers and between them declare:

| Public | Note |
|---|---|
| `IOHIDServiceClientSetProperty` / `CopyProperty` | Everything this project writes goes through these |
| `IOHIDServiceClientGetRegistryID` | Returns `CFTypeRef` (a CFNumber). A real getter — do not go via `CopyProperty` |
| `IOHIDServiceClientConformsTo(service, usagePage, usage)` | The usage test that replaces transport matching |
| `IOHIDEventSystemClientCreateSimpleClient` | See the client-type table below — **not** the one to use |
| `IOHIDEventSystemClientCopyServices` | One-shot enumeration |

Both headers also declare the `IOHIDServiceClientRef` / `IOHIDEventSystemClientRef` typedefs as
`CF_BRIDGED_TYPE`, which Swift imports as the class types **`IOHIDServiceClient`** and
**`IOHIDEventSystemClient`** (the `…Ref` spellings are marked obsoleted in Swift 3 and will not
compile). **Our SPI header must not redeclare those typedefs** — it imports the two SDK headers
instead. Redeclaring them conflicts.

Only matching, notification and scheduling remain SPI. **`Sources/GoodMouseC/include/IOHIDSPI.h` is
the declaration list** — it is what actually compiles, so read it there rather than trusting a copy
here. Its header comment carries the typedef warning above.

`RegisterDeviceMatchingBlock` fires for devices already present as well as new arrivals, so it doubles
as enumeration.

### Which client type — this decides whether anything works

Measured on this machine, unprivileged, against all five types plus the public simple client:

| Client | Sees the virtual device | Reads `HIDPointerResolution` |
|---|---|---|
| `IOHIDEventSystemClientCreate` (no type) | yes | **yes** |
| `…CreateWithType(Monitor)` | yes | yes |
| `…CreateWithType(Passive)` | yes | yes |
| `…CreateWithType(Simple)` | yes | **no — nil** |
| `IOHIDEventSystemClientCreateSimpleClient` | yes | **no — nil** |
| `…CreateWithType(Admin)` | **no — 0 services** | — |

Use plain `IOHIDEventSystemClientCreate`. The simple clients enumerate fine and are a trap: they show
the device and then read `nil` for the very property being tuned. Admin returns nothing at all without
privilege.

### The event-system client must outlive its service clients

An `IOHIDServiceClient` does not retain the client that vended it. Release the event-system client and
the service objects survive as objects but go inert: **every read returns nil and every write silently
returns false**, with no error anywhere. Under optimisation this shows up as a segfault instead.

This is easy to do by accident — returning a service from a function that created the client locally is
enough. `HIDService` therefore holds a strong reference to its owning client.

### Why `UserPointerAccelCurvesKey` is the supported hook

From `IOHIDPointerScrollFilter.cpp` in `apple-oss-distributions/IOHIDFamily`:

```cpp
IOHIDAccelerationAlgorithm * IOHIDPointerScrollFilter::createPointerParametricAlgorithm(SInt32 resolution) {
    CFArrayRefWrap userCurves ((CFArrayRef)copyCachedProperty (CFSTR(kIOHIDUserPointerAccelCurvesKey)), true);
    if (userCurves && userCurves.Count () > 0) {
        return IOHIDParametricAcceleration::CreateWithParameters(userCurves, _pointerAcceleration,
                                                                 FIXED_TO_DOUBLE(resolution), FRAME_RATE);
    }
    // else falls back to driver-published kHIDAccelParametricCurvesKey ("HIDAccelCurves")
}
```

User curves are checked **before** the driver's. This hook exists for exactly our use case, and the key
is in the filter's `_cachedPropertyList`, so writing it triggers a full `setupAcceleration()` rebuild.

### A curve with no gains is silently discarded

`ACCELL_CURVE::isValid()` in `IOHIDAccelerationAlgorithm.hpp` is:

```cpp
bool isValid () { return GainLinear || GainParabolic || GainCubic || GainQudratic; }
```

Invalid curves are dropped from the set. If that leaves the set empty, `CreateWithParameters` returns
NULL and **no accelerator is built at all** — so a curve with every gain at zero does not give a slow
pointer, it gives raw 1:1 motion. Tangent speeds alone are not enough. `ConfigLoader` rejects this
case rather than letting it fail silently.

Note also `GainQudratic` — Apple's own spelling of the quartic field. The *key* is
`HIDAccelGainQuartic`; only the C++ member is misspelt.

### Which key carries the acceleration value

From `setupPointerAcceleration`, in this order:

1. `HIDPointerAccelerationType` — its **value** is the name of the key to read
2. failing that, `HIDMouseAcceleration`
3. failing that, `HIDPointerAcceleration`

`HIDMouseAcceleration` comes **before** `HIDPointerAcceleration`; getting that pair backwards writes to
a key the filter never reads, which fails silently. `setupScrollAcceleration` mirrors it exactly:
`HIDScrollAccelerationType` → `HIDMouseScrollAcceleration` → `HIDScrollAcceleration`.

On the Karabiner virtual device `HIDPointerAccelerationType` is `"HIDMouseAcceleration"`.

### Scroll resolution is per-axis

`setupScrollAcceleration` reads `HIDScrollResolutionX`, `…Y`, `…Z` per axis and falls back to the
generic `HIDScrollResolution` **only when the axis key is absent**. Writing the generic key alone
therefore leaves any published axis key in force. Write the generic key always, plus each axis key the
service actually publishes — and do not invent axis keys the device never had.

### `mode: "linear"` has two conditions, not one

The short-circuit in `setupPointerAcceleration` is:

```cpp
if (isMouseAcceleration && useLinearMousePointerAcceleration.Reference() && (SInt32)… != 0)
```

`isMouseAcceleration` is set when the acceleration came from `HIDMouseAcceleration` — so on a device
whose type is `HIDTrackpadAcceleration` the flag is ignored entirely. On that path:

- `IOHIDSimpleAccelerator(_pointerAcceleration)` is a flat multiplier, and **resolution is never
  consulted**
- an acceleration of exactly 0 falls back to `HIDPointerAccelerationMinimum`, then to the
  `kIOHIDFamilyPreferenceApplicationID` preference of the same name

---

## Apply ordering — non-obvious, get it right

`_cachedPropertyList` (keys whose arrival triggers a rebuild) **does not include
`HIDPointerResolution`**. Resolution is read fresh from the service during
`setupPointerAcceleration()`, so it only takes effect on the *next* rebuild. Write in this order:

1. `HIDPointerResolution` — IOFixed
2. `UserPointerAccelCurvesKey` — CFArray of CFDictionary
3. `HIDPointerAccelerationAlgorithm` = `1` (parametric)
4. `HIDUseLinearScalingMouseAcceleration` = `0` — non-zero short-circuits to a plain linear scaler
5. **Last:** the acceleration value, written to the key *named by* `HIDPointerAccelerationType`
   (`HIDMouseAcceleration` on this device). It is cached, so it fires the rebuild that picks up 1–4.

Scroll mirrors this: `HIDScrollResolution`, `UserScrollAccelCurvesKey`,
`HIDScrollAccelerationAlgorithm`, then the key named by `HIDScrollAccelerationType`
(`HIDMouseScrollAcceleration`).

A **negative** acceleration value makes the filter return early and build no accelerator at all — raw
1:1 motion, with resolution also inert. That is `mode: "raw"`.

### The trigger must fire even when its value is unchanged

Step 5 only works if it is actually *performed*. That collides head-on with the loop guard — compare
live against desired before writing, or the property-changed callback spins on our own writes — and
**the loop guard wins by default, silently.**

A config differing from the live one *only* in `HIDPointerResolution` then applies cleanly, shows the
new value in `ioreg`, reports no drift in `goodmouse status`, and changes nothing whatsoever: steps
1–4 are not cached, step 5 got skipped as unchanged, and the filter is still running the accelerator
it built last time.

This cost a full on-device A/B to find — two configs 200× apart in resolution, identical in every
other key, felt identical. `PropertyWrite.triggersRebuild` marks the write, and `Applicator.apply`
re-writes it whenever an earlier write *in the same axis* changed, and only then, so the loop still
converges to a fixed point. `WritePlanner.stockPlan` (what `goodmouse restore` writes) carries the
same mark for the same reason. `RebuildTriggerTests` covers both halves: that it fires, and that a
no-op pass stays a no-op.

Corollary: **`goodmouse status` cannot see this class of failure on its own.** It compares stored
properties, not the accelerator the filter built. `status --filter-debug` reads the kernel filter
log, which can — see *Verified API reference* above.

---

## The curve math

From `IOHIDAccelerationAlgorithm.cpp`. Constants: `FRAME_RATE = 67.0`, `kCursorScale = 96.0/67.0`,
`kDefaultPointerResolutionFixed = 400 << 16`. IOFixed = `value * 65536`.

Curve selection: take the last curve whose `HIDAccelIndex <= acceleration`; if a next curve exists,
linearly interpolate every parameter by `ratio = (accel − lo.Index) / (hi.Index − lo.Index)`.

Shape: polynomial ramp → straight line → square-root taper, so the curve never runs away. The three
segments meet at `TangentSpeedLinear` (the knee) and `TangentSpeedParabolicRoot` (the taper), and the
curve is continuous across both.

**`Sources/GoodMouseKit/CurveModel.swift` is the statement of this algorithm.** It is a direct port,
it imports no IOKit so it stays readable, and `CurveModelTests` pins the parts that are easy to get
wrong — continuity at both boundaries, interpolation between curves, and the gain-power rule below.
Prefer reading it over any prose restatement, including this one.

---

## Gotchas

- **`(GP*v)^2`, not `GP*v^2`.** Each gain is raised to *its own* power. Getting this wrong makes
  `goodmouse plot` lie about what the kernel is doing. There is a unit test for it; keep it.
- **Higher `HIDPointerResolution` means a *slower* pointer.** Easy to invert. Clamp to `10...1995`.
- **Scroll resolution needs its own clamp.** It is a notches-per-unit figure in the single digits —
  this machine publishes `9` — not a DPI figure. Applying the pointer's floor of 10 silently rewrites
  a perfectly good setting. `AxisKind.resolutionRange` keeps the two apart.
- **All curve values are IOFixed** (`Int(round(v * 65536))`) inside CFDictionary, not doubles.
- **Not every number is IOFixed, though.** `HIDPointerAccelerationAlgorithm`,
  `HIDScrollAccelerationAlgorithm` and `HIDUseLinearScalingMouseAcceleration` are plain integers.
  Rendering `2` as `3.05e-05` in `status` output is a real bug, not a cosmetic one — it makes the
  algorithm field unreadable. `HIDKeys.plainIntegerKeys` is the list.
- **Loop guard on reassert.** Always compare live vs desired before writing, or the property-changed
  callback will spin on our own writes — **except for the rebuild trigger**, which must be written
  even when unchanged. See *Apply ordering* above; this pair is the subtlest thing in the project.
- **A successful write is not a write that took.** `IOHIDServiceClientSetProperty` returning true
  only means the service accepted it. `Applicator.apply` reads every write back and reports a
  mismatch as `IGNORED` rather than `wrote`. This is defensive: scroll resolution normally persists
  (40, 400, 777 and 1000 were all verified to stick), but one write of 400 was observed not to
  survive immediately after a `restore` that also cleared the curves and reset both algorithms, and
  that was never reproduced. Given how many bugs here have been silent no-ops, the extra read is
  worth it — but treat the detector as unproven rather than as a fix for a known fault.
- **`goodmouse restore` cannot restore scroll.** `kDefaultPointerResolutionFixed` (400) and the stock
  `HIDPointerAcceleration` (0.6875) are documented constants, so the pointer keys have a knowable
  stock value. Scroll resolution and scroll acceleration are published per device by the driver —
  this machine reports 9 and 0.3125 — and nothing predicts them. Writing the pointer defaults there
  is much worse than leaving them: 400 is a 44× change to scroll resolution, and an earlier version
  of `stockPlan` did exactly that. `WritePlanner.unrestorableKeys` names what is skipped so the
  command can say so.
- **`CurveModel.swift` must not import IOKit.** It is pure math so it stays unit-testable and drives the
  plot.
- **Signals:** `signal(SIGTERM, SIG_IGN)` before creating the `DispatchSourceSignal`, or the source
  never fires and `restore()` is skipped on shutdown.
- **Never `queue.sync` inside a dispatch source handler bound to that same queue.** The signal and
  timer sources in `watch` are all created with `queue:` set to the monitor's callback queue, so
  their handlers are *already running on it*. A `queue.sync` in the shutdown path is a self-wait;
  libdispatch detects it and traps with `Illegal instruction` in `__DISPATCH_WAIT_FOR_QUEUE__`
  rather than hanging, so it presents as a crash on Ctrl-C, not as a deadlock. The handlers are
  already serialised by the queue — just do the work directly.
- **`watch` must print to stdout, not only `os.Logger`.** launchd captures stdout to
  `~/Library/Logs/goodmouse/`, and a foreground run shows nothing at all otherwise. Set
  `setvbuf(stdout, nil, _IOLBF, 0)` too: stdout to a file is block-buffered, so without it the
  agent's log stays empty for a long time.

## What `restore` means, in two places

They are deliberately different, and neither is wrong:

- **`goodmouse restore`** writes *stock* values — the documented neutral for each key, plus resolution
  400 and acceleration 0.6875. A separate process cannot know what an earlier `apply` overwrote.
- **Ctrl-C / SIGTERM in `watch`** writes back what that process captured before its own first write.
  If the device was already in the config's state when `watch` started, there is nothing to undo and
  it correctly reports restoring 0 keys.

---

## Build, test, run

```sh
swift build
swift test
.build/debug/goodmouse devices
```

SwiftPM executable, no Xcode project. Swift 6.3, target `.macOS(.v14)`.

Dependencies: `swift-argument-parser`, and `swift-testing` for the test target. The latter is an
explicit package dependency rather than the toolchain's bundled `Testing` module because this machine
has **Command Line Tools only, no Xcode** — that toolchain ships neither `Testing` nor `XCTest`, so
`import Testing` does not resolve without it.

`goodmouse apply --dry-run` and `goodmouse status` are the two commands to reach for first: neither
writes anything, and between them they show every key, its desired value, its live value, and why the
write is in the plan.

## Testing on hardware

Two preconditions, and a test run is meaningless without both:

1. **Karabiner must actually be seizing the trackball.** If its event modification is off, the physical
   DEFT Pro keeps its own HID service and motion never reaches the virtual device — so nothing written
   to the virtual device can be felt, however correct the write. Confirm with
   `grep 'hid queue value monitor is started (grabbed)' /var/log/karabiner/core_service.log`.
2. **Quit any other pointer-tuning utility, including its background agent.** Anything else writing
   these properties will fight us and confuse the result. A GUI app being closed is not enough — the
   login item keeps writing. Check both:

   ```sh
   launchctl list | grep -iv apple      # look for a third-party pointer agent
   ls ~/Library/LaunchAgents/
   ```

   Stop one with `launchctl bootout gui/$UID/<label>`.

Stale values from earlier tooling may already be present: the physical DEFT Pro currently carries
`HIDPointerResolution=124518400` (1900) and `HIDMouseAcceleration=589824` (9.0), which are inert only
while Karabiner has the device seized.

Independent confirmation of what actually landed:

```sh
ioreg -c IOHIDDevice -r -l | grep -A3 VirtualHIDPointing
tail -f /var/log/karabiner/core_service.log
```

### This machine

| Thing | Value |
|---|---|
| macOS | 26.5.2 (Tahoe), build 25F84, x86_64 |
| Swift | 6.3 |
| DEFT Pro (wireless dongle) | VID `1390`/`0x056E`, PID `306`/`0x0132` |
| DEFT Pro (Bluetooth) | VID `1390`/`0x056E`, PID `307`/`0x0133` |
| Karabiner VirtualHIDPointing | VID `5824`/`0x16C0`, PID `10202`/`0x27DA` |
| Corne keyboard | VID `7504`/`0x1D50`, PID `24926`/`0x615E` — over BLE it **does** publish a GenericDesktop Mouse service, so usage matching sweeps it in |
| Karabiner DriverKit | 1.8.0 |

The built-in trackpad is a separate service with its own `HIDTrackpadAcceleration` and is unaffected by
anything this project does. Karabiner grabs only the keyboard half of the internal keyboard/trackpad.

## Reference material

- `apple-oss-distributions/IOHIDFamily`, `IOHIDEventSystemPlugIns/` — `IOHIDPointerScrollFilter.cpp`
  and `IOHIDAccelerationAlgorithm.cpp` are the authority on every behaviour described above. When
  something here disagrees with observed behaviour, that source settles it.
- `pqrs-org/Karabiner-Elements` — for how the grab and the virtual device work.
- The SDK headers and the shipping filter binary, both cited inline above, for key literals.
