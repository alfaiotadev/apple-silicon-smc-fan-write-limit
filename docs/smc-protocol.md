# Talking to AppleSMC on Apple Silicon

What smcfan relies on. All of it was found by experiment; Apple documents
none of it. Verified on M1 Max and M4 Max under macOS 26.

## Who may call

Three conditions have to hold before the SMC returns values:

| Condition                                 | Without it                                                    |
|-------------------------------------------|---------------------------------------------------------------|
| Binary signed with **Developer ID Application** + **hardened runtime** (`codesign --options runtime`) | Every `IOConnectCallStructMethod` returns `kIOReturnNotPrivileged` (`0xE00002C2`) |
| Process started by **launchd as a system LaunchDaemon** (root) | Calls go through, but the SMC answers `0x84` (denied) or `0x89` (not found) for keys that exist. Plain `sudo` is not enough. |
| The struct below filled in exactly        | `0x84`/`0x89` again, which is easy to mistake for the previous row |

Not required: `SMJobBless`, entitlements, notarization, an app bundle or a
TCC prompt.

## Transport

```
IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
IOServiceOpen(service, mach_task_self_, 0, &conn)
IOConnectCallStructMethod(conn, 2, in, 80, out, &80)
```

## The 80-byte struct

| Offset | Field     | Size | Notes                                                                    |
|--------|-----------|------|--------------------------------------------------------------------------|
| `0x00` | key       | 4    | FourCC as **UInt32 little-endian**: `"F0Md"` is bytes `64 4D 30 46`      |
| `0x1C` | dataSize  | 4    | UInt32 LE. Output of cmd 9, **required input** of cmd 5/6                |
| `0x20` | dataType  | 4    | UInt32 LE type FourCC (`"flt "`, `"ui8 "`, …). Output of 9, input of 5/6 |
| `0x24` | dataAttr  | 1    | Output of 9, input of 5/6                                                |
| `0x28` | result    | 1    | Output. `0x00` ok, `0x82` writes locked, `0x84` denied, `0x89` not found |
| `0x2A` | command   | 1    | `5` read, `6` write, `8` key-at-index, `9` key info                      |
| `0x2C` | index     | 4    | UInt32 LE, cmd 8 only                                                    |
| `0x30` | data      | ≤32  | Output of cmd 5, input of cmd 6                                          |

Note that the command byte is at `0x2A`. Intel-era write-ups put it at
`0x27`, which doesn't work here.

## Reading a key

1. cmd 9 with only the key filled in. The reply carries size, type and
   attributes at `0x1C`/`0x20`/`0x24`. These are constant for a given chip
   and OS, so cache them.
2. cmd 5 with key **plus** size, type and attributes copied in. The value
   is at `0x30`.

Writing (cmd 6) works the same way as reading, with the value at `0x30` in
the input.

## Fan keys

| Key       | Type   | Meaning                                         |
|-----------|--------|-------------------------------------------------|
| `FNum`    | `ui8 ` | number of fans                                  |
| `F<n>Ac`  | `flt ` | actual RPM (0 when the fan is stopped at idle)  |
| `F<n>Mn`  | `flt ` | minimum RPM                                     |
| `F<n>Mx`  | `flt ` | maximum RPM                                     |
| `F<n>Tg`  | `flt ` | target RPM (**writable**)                       |
| `F<n>Md`  | `ui8 ` | mode (**writable**): 1 = forced; see below      |
| `F<n>St`  | `ui8 ` | fan status (3 on an idle M4 Max)                |
| `Ftst`    | `ui8 ` | present on M4 Max (value 0); purpose unknown    |

`F<n>Md` has more than two values. An M4 Max with no tool involved reports
**`Md = 3`** while macOS controls the fans (and `F<n>St = 3`, `Ac = Tg = 0`
with the fans stopped at idle). Writing `Md = 0` also hands the fan back to
macOS. So treat **anything other than 1** as "macOS is in charge", and don't
write `0` to a fan that already reads 3. That write is wasted budget.

To force a fan, write `Md = 1`, then `Tg = rpm`. To release it, write
`Md = 0`. macOS resets `Md` to 0 now and then, so a held fan has to be
written again. Each write counts towards the [write limit](write-limit.md).

Reference values: an M4 Max reports `F0Mn = 1350` and `F0Mx = 5777`. An
M1 Max reports `F0Mn = 1499`, `F0Mx = 5348` and `F1Mx = 5776`; its two fans
are not identical.

## Temperature keys

The names differ per chip family. Some keys exist but return placeholder
values (`0.0`, `1.5`, exactly `40.0`) while their cluster is power-gated,
so smcfan ignores readings below 15 °C and exactly 40.0 °C. See
[porting.md](porting.md) for how the per-chip lists were built.

## Enumerating keys

`#KEY` (4 bytes, **big-endian**) holds the number of keys. cmd 8 with an
index at `0x2C` returns the key name at `0x00..0x03`, again in reversed byte
order. `smcfan dump-keys` walks the whole table this way and writes
`index  key  type  size  value` to `/var/run/smcfan/keys.tsv`. It only
reads.
