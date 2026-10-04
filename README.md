# Apple Silicon SMC fan write limit, and `smcfan`

A small, dependency-free fan tool for Apple Silicon Macs that also keeps
count of a limit most fan tools don't tell you about: **the SMC accepts only
about 100 fan writes per boot.** After that, every write fails with SMC
result `0x82` until you reboot.

```
smcfan  Apple M4 Max (Mac16,5)

CPU  avg  47.4 °C   max  48.1 °C   (4 sensors)
GPU  avg  40.2 °C   max  43.4 °C   (4 sensors)

FAN  ACTUAL   TARGET     MIN     MAX  MODE
> 0    2499     2500    1350    5777  forced 2500 rpm
  1    1473     1350    1350    5777  auto

SMC writes  [###########...................] 37/~100 used, ~63 left before a reboot is needed
            counted since boot at 21.6.2026, 0.13; writes by other tools are not seen

fan 0  target  ◂  2500 rpm ▸   hold: until released   Enter costs 1 write
↑↓ fan   ←→ ±100   [ ] ±500   n min   m max   t hold time   a auto   A all auto   q quit
```

It's a proof of concept: one Swift file, no packages, no frameworks beyond
IOKit and Foundation.

### Status: what has been tested where

| Part                                                   | Real hardware (M4 Max, macOS 26.6) | Simulated SMC (`make test`) |
|--------------------------------------------------------|:----------------------------------:|:---------------------------:|
| Reading fans, limits, temperatures; `dump-keys`        | ✅                                 | ✅                          |
| Detecting `0x82` and refusing further writes           | ✅ (machine was already locked)    | ✅                          |
| `auto` on fans macOS already controls costs 0 writes   | ✅                                 | ✅                          |
| TUI and CLI against the live daemon                    | ✅                                 | ✅                          |
| Forcing a fan, holding it, write counting, rate limit, merging, safety releases | ⏳ not yet: needs a freshly booted machine | ✅ |

The write path uses the same SMC calls as an earlier daemon that forced fans
on M4 Max and M1 Max machines. smcfan's own write path hasn't been run on
hardware yet. Reports are welcome.

## The finding: an SMC write limit per boot

On Apple Silicon you control a fan by writing two SMC keys: `F<n>Md` (mode:
0 = auto, 1 = forced) and `F<n>Tg` (target RPM). Tools such as FanControl
and Macs Fan Control do exactly this.

We saw the following on an **M4 Max (Mac16,5), macOS 26**:

- After roughly **100 successful `WriteKey` (cmd 6) calls** in one boot
  session, every later write returns SMC result **`0x82`**. That covers both
  keys and both values, including the harmless "back to auto" write
  `F<n>Md = 0`.
- **Reads keep working.** RPMs, temperatures and fan limits all still
  update. The IOKit connection is fine, and the kernel returns
  `KERN_SUCCESS`. The rejection comes from the SMC's own result byte.
- **macOS keeps controlling the fans.** The machine stays thermally safe.
  You just can't override the fans any more.
- **Only a full reboot clears it.** Each of these was tried and failed:

  | Attempted reset                                          | Writes after |
  |----------------------------------------------------------|--------------|
  | Close and reopen the IOKit connection in the same process | `0x82`       |
  | Restart the daemon (`launchctl bootout` + `bootstrap`)    | `0x82`       |
  | Sleep and wake (`pmset sleepnow`)                         | `0x82`       |
  | **Full reboot**                                           | **ok**       |

- It's easy to hit this by accident. A fan curve that re-sends its target
  every few seconds, or a tool that re-asserts forced mode on every tick,
  uses up the budget within minutes.

What's still unknown, and where contributions are welcome:

- The exact number. "About 100" comes from mixed real-world use, not a
  controlled count. Does `Md` count the same as `Tg`? Is it a per-boot
  total or a rate limit inside a time window?
- Whether other chips (M1, M2, M3) and other macOS versions have the same
  limit.
- Which part of the system holds the lock. It survives a process restart and
  sleep, but not a reboot. That points to state in the kernel's `AppleSMC`
  driver or the SMC firmware, not to anything held by the calling process.

Details and raw evidence: [docs/write-limit.md](docs/write-limit.md).

## How smcfan deals with it

- **Counts every write it makes** (per boot, kept across daemon restarts)
  and shows how many remain out of a configurable budget (default 100).
- **Writes only when something changed.** Holding a fan doesn't mean
  writing every tick. The daemon reads `F<n>Md`/`F<n>Tg` once a second and
  writes only when macOS has reset them.
- **Nothing is written while you browse.** In the TUI, the arrow keys and
  `+`/`-` only change a local value. Pressing Enter writes it, and the TUI
  shows how many writes that will cost.
- **Rate-limits writes.** By default it allows at most 12 per minute
  (`SMCFAN_MAX_WRITES_PER_MIN`). Commands over the limit are refused with
  "try again in N s", so a script or a held-down key can't use up the
  budget. Releasing a fan to auto is never refused.
- **Merges bursts of commands.** Commands that arrive together are applied
  as one, and the last one for each fan wins. Ten quick `set`s cost the same
  as one. Commands are picked up within 0.1 s.
- **Stops writing once the SMC returns `0x82`** and tells you to reboot.
- **Fails safe.** A forced fan goes back to auto when its hold time runs
  out, when any sensor reaches 95 °C (new holds are refused at that
  temperature), when macOS keeps taking the fan back faster than the rate
  limit allows, or when the daemon stops. A daemon that crashed while
  holding a fan releases it when it restarts.

The counter only sees smcfan's own writes. If FanControl, Macs Fan Control
or another tool wrote to the SMC during the same boot, the real remaining
budget is lower than smcfan shows.

## Requirements

- An Apple Silicon Mac (checked on M1 Max and M4 Max, macOS 26).
- Xcode Command Line Tools (`swiftc`).
- **An Apple Developer ID Application certificate.** This is unavoidable,
  because the SMC ignores unsigned callers:

  | How the binary runs                                     | Result                                       |
  |---------------------------------------------------------|----------------------------------------------|
  | Ad-hoc signed, any user                                 | `kIOReturnNotPrivileged` from IOKit          |
  | Developer ID + hardened runtime, run directly or `sudo` | SMC rejects reads (`0x84`/`0x89`)            |
  | Developer ID + hardened runtime, **root LaunchDaemon**  | reads and writes work                        |

  That's why smcfan has a daemon. `SMJobBless`, entitlements and
  notarization are *not* needed. See [docs/smc-protocol.md](docs/smc-protocol.md).

## Build and install

```bash
security find-identity -v -p codesigning        # find your "Developer ID Application: …"
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build.sh
sudo build/smcfan install                       # LaunchDaemon + /usr/local/bin/smcfan link
smcfan                                          # TUI
```

`sudo smcfan uninstall` removes everything again. A forced fan is released
first.

## Usage

```
smcfan                         interactive TUI (status when not on a terminal)
smcfan status [--json]         one-shot view; --json for scripts
smcfan watch                   read-only, refreshing view
smcfan set <fan|all> <rpm> [--ttl S]
smcfan auto [fan|all]
smcfan dump-keys               full SMC key table -> /var/run/smcfan/keys.tsv
```

Members of the `admin` group can run every command except
`install`/`uninstall` without `sudo`.

Write costs: `set` costs 2 writes per fan (1 if the fan is already forced).
`auto` costs 1, or 0 if the fan is already in auto. Holding a fan costs
another 1–2 writes each time macOS takes the fan back. Watch the counter
while a fan is held to see how often that happens on your machine.

## Files

| Path                                         | What                                     |
|----------------------------------------------|------------------------------------------|
| `/Library/PrivilegedHelperTools/smcfan`      | the binary                               |
| `/Library/LaunchDaemons/io.github.alfaiotadev.smcfan.plist` | daemon; `SMCFAN_BUDGET`, `SMCFAN_MAX_WRITES_PER_MIN` |
| `/var/run/smcfan/state.json`                 | live snapshot (world-readable)           |
| `/var/run/smcfan/{inbox,outbox}/`            | client → daemon commands (root:admin)    |
| `/var/db/smcfan/ledger.json`                 | write counter for the current boot       |
| `/var/log/smcfan.log`                        | daemon log                               |

## Development

```bash
make check   # compile with -warnings-as-errors, render the example snapshot
make test    # end-to-end: real daemon + client against a simulated SMC (no root)
```

`smcfan daemon --fake` runs the daemon against an in-memory SMC that
locks writes after `SMCFAN_FAKE_LIMIT` writes. The test suite
([tests/test_daemon.py](tests/test_daemon.py), stdlib only) uses it to
check the counter, merging, rate limit, `0x82` handling and the safety
releases. You don't need a Mac with fans or a certificate to run it.

## Supported chips

Fan readout and control work on any Apple Silicon Mac with fans, because
`FNum` and `F<n>*` are the same everywhere. **Temperature readout needs a
per-chip sensor list.** Today there are lists for M1-family and M4-family
chips. On other chips smcfan shows fans and the write counter but no
temperatures. Adding a chip takes about 10 minutes:
[docs/porting.md](docs/porting.md).

## Disclaimer

This writes to undocumented SMC keys. It can't damage hardware: the firmware
clamps targets to the fans' min/max, and macOS still throttles the chip if
it gets too hot. But every write you make uses up budget you can only get
back by rebooting. Use at your own risk.

## Credits

- [Asahi Linux](https://asahilinux.org/) SMC documentation, for the
  key namespace and command semantics.
- FanControl and Macs Fan Control, for showing that fan writes are possible
  on Apple Silicon at all.

MIT licensed. See [LICENSE](LICENSE).
