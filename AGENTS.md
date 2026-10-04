# AGENTS.md

A brief for AI coding agents (and humans) working on this repo. Read it
before you change anything. The user-facing docs are [README.md](README.md)
and [docs/](docs/).

## What this is

`smcfan` is a single-file Swift tool for Apple Silicon Macs. It shows
temperatures and fan speeds, can hold a fan at a fixed RPM, and counts SMC
writes. It counts because **the SMC accepts only about 100 fan writes per
boot**. After that every write returns `0x82` until a reboot
([docs/write-limit.md](docs/write-limit.md)). The write counter and the
write-saving design are the point of the project. Treat anything that adds
SMC writes as a regression.

## Layout

```
src/smcfan.swift        everything: SMC plumbing, FakeSMC, daemon, client, TUI, install
tests/test_daemon.py    end-to-end tests (Python stdlib unittest) against FakeSMC
examples/               saved state snapshot for rendering without a daemon
scripts/build.sh        swiftc + optional codesign (SIGN_IDENTITY)
docs/                   write-limit findings, SMC protocol, porting a new chip
```

The file is split by `// MARK:` sections, in this order: paths/tunables →
SMC plumbing (`SMCDevice` protocol, `SMC`, `FakeSMC`) → environment/chip
tables → JSON helpers → `Daemon` → client (`currentState`, `send`, `render`)
→ TUI → install/uninstall → `main`.

One binary, two roles:

- `smcfan daemon` is a root LaunchDaemon and the only thing that talks to
  the SMC. It publishes `/var/run/smcfan/state.json` once a second,
  polls `/var/run/smcfan/inbox/` every 0.1 s, replies in `outbox/`, and
  keeps the per-boot counter in `/var/db/smcfan/ledger.json`.
- Every other subcommand is an unprivileged client of those files.

## Hard rules

1. **Never add a write that isn't needed.** Every SMC write goes through
   `Daemon.write()`, which counts it. Don't call `smc.write` anywhere else.
   Read before writing (see `enforce()` and `release()`), and never write
   on a timer just to be safe.
2. **Keep the safety releases.** A forced fan must go back to auto on TTL
   expiry, at `HOT_RELEASE_C`, when holding it would exceed the rate limit,
   on SIGTERM, and on restart after a crash. Releasing to auto is never
   rate-limited.
3. **Writable keys are `F<n>Md` and `F<n>Tg` only.** Don't add generic SMC
   writes, a "raw write" command or new writable keys.
4. **No dependencies.** Swift stdlib, Foundation, IOKit and Darwin only. No
   SwiftPM packages, no curses, no Python packages in tests. A single
   `swiftc` call must build the tool.
5. **Don't run the real daemon's write paths on someone's Mac** without
   their explicit go-ahead. It uses up a budget that only a reboot restores.
   `smcfan status`, `watch`, `dump-keys` and `daemon --fake` are safe.
   `set`/`auto` against a real daemon are not free.
6. **No personal data in the repo.** No real names, hostnames, Tailscale
   names, Developer ID team identifiers or emails, including in examples,
   logs and commit messages. The project identity is `alfaiotadev`.

## Build, test, verify

```bash
make check     # swiftc -warnings-as-errors + render examples/state-m4max.json
make test      # end-to-end tests, ~12 s, no root, no hardware
```

Both must pass before you hand work back. `make test` starts the real
daemon code with `--fake` (an in-memory SMC) under `SMCFAN_ROOT=<tmpdir>`,
so it exercises the same inbox, batching, ledger and rendering as
production.

FakeSMC knobs (environment):

| Variable                    | Effect                                              |
|-----------------------------|-----------------------------------------------------|
| `SMCFAN_FAKE_LIMIT`         | writes accepted before every write returns `0x82`   |
| `SMCFAN_FAKE_RECLAIM_S`     | reset every fan's `Md` to 0 this often (simulates macOS) |
| `SMCFAN_FAKE_TEMP`          | value of every temperature key                      |
| `SMCFAN_FAKE_TEMP_FILE`     | read the temperature from this file on each access  |
| `SMCFAN_ROOT`               | prefix for `/var/run/smcfan` and `/var/db/smcfan`   |

Daemon tunables (also set in the installed plist): `SMCFAN_BUDGET`
(default 100) and `SMCFAN_MAX_WRITES_PER_MIN` (default 12).

To look at the UI without a daemon:

```bash
build/smcfan status --state examples/state-m4max.json
build/smcfan tui    --state examples/state-m4max.json   # keys work; commands fail (no daemon)
```

To drive the TUI from a script, give it a pty, e.g.
`(printf '\033[B++'; sleep 1; printf q) | script -q /tmp/out build/smcfan tui --state …`.

Real-hardware testing needs a Developer ID Application certificate
(`SIGN_IDENTITY=… scripts/build.sh`) and `sudo build/smcfan install`. Ad-hoc
signatures and plain `sudo` don't get SMC access. See
[docs/smc-protocol.md](docs/smc-protocol.md).

## When you change…

- **Daemon behaviour** (counting, batching, rate limit, releases): add or
  adjust a test in `tests/test_daemon.py`. Use FakeSMC knobs rather than
  sleeping. If FakeSMC can't express the scenario, extend FakeSMC.
- **Reply or state JSON**: both are an interface. `state.json` is read by
  `status --json` users and the TUI, and `examples/state-m4max.json` must
  still render. Add fields; don't rename or remove them.
- **Rendering**: run `make check`, then look at the `--state` output
  yourself. Alignment matters: columns are padded by hand, because
  `String(format: "%6@")` doesn't pad Swift strings.
- **A new chip family**: follow [docs/porting.md](docs/porting.md). Only add
  sensor keys that were checked on real hardware, and say which machine in
  a comment.
- **Anything about the write limit**: update
  [docs/write-limit.md](docs/write-limit.md) with the evidence (chip,
  `hw.model`, macOS build, write count). Keep observed facts and guesses
  clearly apart.

## Style

- Comments explain *why* (SMC quirks, the budget), not what the next line
  does.
- Errors meant for users say what to do next ("Install it with: sudo smcfan
  install", "try again in N s").
- Client-facing failures go through `fail()` (exit non-zero, message on
  stderr). Daemon diagnostics go through `log()` to `/var/log/smcfan.log`.
