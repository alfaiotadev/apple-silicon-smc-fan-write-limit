# The SMC write limit (result 0x82)

Notes on what was observed, how, and what is still open. The data comes
from a small Apple Silicon fleet. The original fan-control daemon was the
predecessor of smcfan: it used the same IOKit calls and the same LaunchDaemon
context.

## Environment

- Apple M4 Max, `Mac16,5`, macOS 26 (Darwin 25.5)
- Caller: a Developer-ID-signed, hardened-runtime Swift binary running as a
  root LaunchDaemon. It writes `F<n>Md` (`ui8`) and `F<n>Tg` (`flt`) with
  `IOConnectCallStructMethod` selector 2, cmd 6. See
  [smc-protocol.md](smc-protocol.md).

## Symptom

After about 100 successful writes in one boot session, all of them `F0Md`,
`F1Md`, `F0Tg` and `F1Tg` from manual testing, every write fails:

```
startup-reset fan 0 failed: writeKey(F0Md) smc result=0x82
startup-reset fan 1 failed: writeKey(F1Md) smc result=0x82
```

- `IOConnectCallStructMethod` returns `KERN_SUCCESS`. The failure is the
  SMC result byte at offset `0x28`.
- Reads (cmd 5) on the same connection go on returning current RPMs,
  limits, targets and temperatures every 2 s.
- Even `F<n>Md = 0`, which only asks for what macOS is already doing, is
  rejected.
- The fans stay under macOS's automatic control, so the machine is safe.
  Only manual control is lost.

`0x82` fits a "not privileged" answer from the SMC firmware layer. It is
not `kIOReturnNotPrivileged` (`0xE00002C2`), which is IOKit's error and
what an unsigned caller gets.

## Reset attempts

All against the same locked session, in order of escalation:

| Attempt                                                      | Process         | Result              |
|--------------------------------------------------------------|-----------------|---------------------|
| `IOServiceClose` + `IOServiceOpen`, retry the write           | same PID        | `0x82`              |
| `launchctl bootout system` + `bootstrap` (new process, new connection) | new PID | `0x82`             |
| `pmset sleepnow`, then wake                                   | same PID        | `0x82`              |
| `shutdown -r now`                                             | after reboot    | **writes succeed**  |

First writes after the reboot:

```
POST fan/0/auto                 -> ok
POST fan/0 {target 2500, ttl 10} -> ok, forced 2500 rpm (min 1350, max 5777)
POST fan/0/auto                 -> ok
```

So the lock is not tied to the IOKit connection, the process or its code
signature. It survives sleep, which means it isn't something the SMC loses
in a low-power state either. It is reset only by a boot. That points to the
kernel's `AppleSMC` driver or to SMC firmware state that is re-initialised
at boot.

## A second way to hit it

A dashboard fan curve sent a new target every ~5 s per fan and kept the fans
forced. On the M4 Max that sustained write rate hit `0x82` **within
minutes**. The fans fell back to automatic control and stayed there until a
reboot.

Changing the curve to "write only on change, release to auto when idle"
made it much slower to reach the limit but didn't remove it. This is the
reasoning behind smcfan's design: count every write, write only when
something changed, and never write in the background just to keep a fan
held.

## Why holding a fan costs writes

macOS's thermal control resets `F<n>Md` to 0 from time to time, so a forced
fan falls back to auto unless something writes it again. Tools that re-send
`Md=1` + `Tg` every tick spend about 1 write per second per fan. That
exhausts a ~100-write budget in under a minute or two. smcfan reads first
and writes only when the value has drifted. How often macOS resets it, and
so how many writes a long hold costs, has not been measured yet. The live
counter shows it.

## Confirmed with smcfan

On the same M4 Max, still locked after 35 days of uptime, smcfan:

- read every fan and temperature key normally,
- got `0x82` on its first write (`F0Md = 1`), marked writes locked, and
  attempted no further writes,
- found the fans at `F<n>Md = 3` under macOS control. An earlier daemon had
  written `Md = 0` to both fans on **every start** as a "reset". That's two
  wasted writes per restart, which may have helped use up the budget.

## Open questions

1. **The exact budget.** Is it a fixed count per boot, or a rate limit
   (N writes per time window) that doesn't recover once tripped? A clean
   measurement: fresh boot, no other fan tool, a loop of `F0Md = 0` writes,
   count until `0x82`.
2. **Do all writes count the same?** `Md` vs `Tg`, and writes that don't
   change the value.
3. **Other chips and macOS versions.** Only the M4 Max on macOS 26 is
   confirmed. M1 Max machines in the same fleet weren't pushed to the limit.
4. **What is `Ftst`?** It exists on the M4 Max (reads 0). Community fan
   tools have used a key by that name to unlock manual fan control on
   Apple Silicon. Whether it changes the write limit hasn't been tested.
5. **Does a different caller avoid it?** FanControl's helper performs an
   extra user-client handshake that we haven't reproduced. If that handshake
   sets up a write session, the limit may only apply to callers that skip
   it.

If you measure any of these, please open an issue with your chip, model
identifier (`sysctl hw.model`), macOS build (`sw_vers`) and the write count
from `smcfan status --json` (`writes.used` at the moment `wedged` became
`true`).
