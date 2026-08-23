# good_mouse

Pointer sensitivity and acceleration for a trackball that Karabiner-Elements has seized.

Karabiner grabs the physical device and re-emits through its own virtual HID pointing device. Pointer
sensitivity on macOS is set per-device on the kernel's acceleration filter, so tuning the physical
trackball stops working the moment Karabiner holds it — the settings apply to a device that no longer
emits anything.

Tuning the virtual device instead is the fix, but utilities that identify devices as
vendor-product-**transport** can't reach it: the Karabiner virtual device publishes no transport at
all, so it never appears in their device lists.

`good_mouse` matches on HID **usage** instead, finds the virtual device, and applies sensitivity, scroll
and a tunable acceleration curve to it. Karabiner keeps every binding, untouched.

- No GUI, no event tap, no kext or system extension
- No Accessibility or Input Monitoring permission
- Zero added latency — the OS's existing `IOHIDPointerScrollFilter` does the math
- One profile covers the trackball on both Bluetooth and its wireless dongle

**Status:** implemented; pointer/scroll writes are pending an on-device confirmation run.

## Usage

```sh
swift build
.build/debug/goodmouse write-default-config     # ~/.config/goodmouse/config.json
.build/debug/goodmouse devices                  # what is present, and what each rule claims
.build/debug/goodmouse plot                     # the curve the config produces
.build/debug/goodmouse apply --dry-run          # the exact writes, and why each is in the plan
.build/debug/goodmouse apply
.build/debug/goodmouse status                   # desired vs live, per key
.build/debug/goodmouse install-agent            # run `watch` at login
```

`devices` is the diagnostic worth knowing: its TRANSPORT column shows `—` for the Karabiner virtual
device, which is precisely why transport-keyed utilities cannot list it.

## Documentation

[AGENTS.md](./AGENTS.md) — architecture, verified API reference, curve math, gotchas.
