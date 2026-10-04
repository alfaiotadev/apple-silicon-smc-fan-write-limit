"""End-to-end tests for the smcfan daemon + client, against the in-memory FakeSMC.

Each test starts `smcfan daemon --fake` with SMCFAN_ROOT pointing at a fresh
temp directory, drives it with the real client commands, and checks the
replies, the live state file and the write ledger. No root, no signing, no
hardware. Python stdlib only.

    make test          # builds build/smcfan-check first
"""

import json
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
import uuid

REPO = pathlib.Path(__file__).resolve().parent.parent
BIN = os.environ.get("SMCFAN_BIN", str(REPO / "build" / "smcfan-check"))


class DaemonCase(unittest.TestCase):
    # Per-test daemon environment; override in subclasses or before start().
    fake_env: dict = {}

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="smcfan-test-")
        self.proc = None

    def tearDown(self):
        self.stop()
        shutil.rmtree(self.root, ignore_errors=True)

    # --- helpers ----------------------------------------------------------

    def env(self, **extra):
        e = dict(os.environ, SMCFAN_ROOT=self.root)
        e.update({k: str(v) for k, v in {**self.fake_env, **extra}.items()})
        return e

    def start(self, **extra):
        self.log = open(os.path.join(self.root, "daemon.log"), "a")
        self.proc = subprocess.Popen([BIN, "daemon", "--fake"], env=self.env(**extra),
                                     stdout=self.log, stderr=self.log)
        deadline = time.time() + 5
        while time.time() < deadline:
            if os.path.exists(self.state_path):
                return
            time.sleep(0.05)
        self.fail("daemon did not write its state file:\n" + self.daemon_log())

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            self.proc.wait(timeout=5)
        self.proc = None

    def daemon_log(self):
        try:
            return pathlib.Path(self.root, "daemon.log").read_text()
        except OSError:
            return ""

    @property
    def state_path(self):
        return os.path.join(self.root, "var/run/smcfan/state.json")

    def cli(self, *args, ok=True):
        r = subprocess.run([BIN, *args], env=self.env(), capture_output=True, text=True, timeout=15)
        if ok:
            self.assertEqual(r.returncode, 0, f"smcfan {' '.join(args)} failed:\n{r.stdout}{r.stderr}")
        return r

    def state(self):
        return json.loads(self.cli("status", "--json").stdout)

    def wait_state(self, pred, timeout=5.0, what="condition"):
        deadline = time.time() + timeout
        while time.time() < deadline:
            s = self.state()
            if pred(s):
                return s
            time.sleep(0.2)
        self.fail(f"timed out waiting for {what}; last state:\n{json.dumps(s, indent=1)}")

    def fan(self, s, i):
        return next(f for f in s["fans"] if f["id"] == i)

    def ledger(self):
        return json.loads(pathlib.Path(self.root, "var/db/smcfan/ledger.json").read_text())


class TestBasics(DaemonCase):
    def test_status_reports_fans_temps_and_full_budget(self):
        self.start()
        s = self.state()
        self.assertEqual(len(s["fans"]), 2)
        self.assertEqual(self.fan(s, 0)["min_rpm"], 1350)
        self.assertEqual(self.fan(s, 0)["max_rpm"], 5777)
        self.assertEqual(len(s["temps"]["cpu"]), 2)
        w = s["writes"]
        self.assertEqual((w["used"], w["budget"], w["remaining"], w["wedged"]), (0, 100, 100, False))
        human = self.cli("status").stdout
        self.assertIn("0/~100 used", human)
        self.assertIn("~100 left", human)

    def test_set_costs_two_writes_and_repeating_it_costs_none(self):
        self.start()
        r = self.cli("set", "0", "2500")
        self.assertIn("ok, 2 SMC writes spent", r.stdout)
        s = self.state()
        self.assertEqual(self.fan(s, 0)["mode"], 1)
        self.assertEqual(self.fan(s, 0)["forced_rpm"], 2500)
        self.assertEqual(s["writes"]["used"], 2)

        r = self.cli("set", "0", "2500")
        self.assertIn("ok, 0 SMC writes spent", r.stdout)
        r = self.cli("set", "0", "2600")
        self.assertIn("ok, 1 SMC write spent", r.stdout)
        self.assertEqual(self.state()["writes"]["used"], 3)

    def test_target_is_clamped_to_fan_limits(self):
        self.start()
        r = self.cli("set", "1", "99999")
        self.assertIn("5777 rpm (clamped", r.stdout)

    def test_auto_costs_one_write_then_none(self):
        self.start()
        self.cli("set", "0", "2000")
        self.assertIn("ok, 1 SMC write spent", self.cli("auto", "0").stdout)
        self.assertIn("ok, 0 SMC writes spent", self.cli("auto", "0").stdout)
        s = self.state()
        self.assertNotEqual(self.fan(s, 0)["mode"], 1)
        self.assertNotIn("forced_rpm", self.fan(s, 0))

    def test_auto_on_untouched_fans_costs_nothing(self):
        # Md = 3 (macOS in control, as on an M4 Max) must not trigger a write.
        self.start()
        self.assertIn("ok, 0 SMC writes spent", self.cli("auto").stdout)

    def test_set_all_forces_every_fan(self):
        self.start()
        self.assertIn("ok, 4 SMC writes spent", self.cli("set", "all", "3000").stdout)
        s = self.state()
        self.assertTrue(all(f["mode"] == 1 for f in s["fans"]))

    def test_bad_input_is_rejected_without_writes(self):
        self.start()
        self.assertNotEqual(self.cli("set", "7", "2000", ok=False).returncode, 0)
        self.assertNotEqual(self.cli("set", "0", "fast", ok=False).returncode, 0)
        self.assertEqual(self.state()["writes"]["used"], 0)

    def test_commands_are_picked_up_quickly(self):
        self.start()
        t0 = time.time()
        self.cli("set", "0", "2000")
        self.assertLess(time.time() - t0, 1.0)


class TestBatching(DaemonCase):
    def test_burst_of_commands_for_one_fan_costs_one_write_set(self):
        self.start()
        inbox = pathlib.Path(self.root, "var/run/smcfan/inbox")
        outbox = pathlib.Path(self.root, "var/run/smcfan/outbox")
        ids = []
        now = time.time()
        # Ten commands land in the same inbox pass; mtimes fix their order.
        for i, rpm in enumerate(range(2000, 3000, 100)):
            cid = uuid.uuid4().hex
            tmp = inbox / f".{cid}.tmp"
            tmp.write_text(json.dumps({"id": cid, "op": "set", "fan": 0, "rpm": float(rpm)}))
            os.utime(tmp, (now + i * 0.01, now + i * 0.01))
            ids.append(cid)
        for cid in ids:
            os.rename(inbox / f".{cid}.tmp", inbox / f"{cid}.json")

        deadline = time.time() + 5
        while time.time() < deadline and not all((outbox / f"{c}.json").exists() for c in ids):
            time.sleep(0.05)
        replies = [json.loads((outbox / f"{c}.json").read_text()) for c in ids]
        self.assertTrue(all(r["ok"] for r in replies), replies)
        s = self.state()
        self.assertEqual(self.fan(s, 0)["forced_rpm"], 2900, "last command should win")
        self.assertEqual(s["writes"]["used"], 2, "ten sets in one batch must cost one Md + one Tg write")


class TestRateLimit(DaemonCase):
    fake_env = {"SMCFAN_MAX_WRITES_PER_MIN": 4}

    def test_writes_beyond_the_per_minute_limit_are_refused(self):
        self.start()
        self.cli("set", "0", "2000")          # 2 writes
        self.cli("set", "0", "2100")          # 1
        self.cli("set", "0", "2200")          # 1 -> 4 in the last minute
        r = self.cli("set", "0", "2300", ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("rate limited", r.stderr)
        s = self.state()
        self.assertEqual(s["writes"]["used"], 4)
        self.assertEqual(self.fan(s, 0)["forced_rpm"], 2200, "refused command must not change the target")

    def test_release_to_auto_is_never_rate_limited(self):
        self.start()
        self.cli("set", "all", "2000")        # 4 writes, limit reached
        self.assertIn("ok, 2 SMC writes spent", self.cli("auto").stdout)

    def test_fan_that_macos_keeps_reclaiming_is_released(self):
        # macOS takes the fan back every 0.5 s; holding it would need ~2 writes/s.
        self.start(SMCFAN_FAKE_RECLAIM_S=0.5)
        self.cli("set", "0", "2000")
        s = self.wait_state(lambda s: "forced_rpm" not in self.fan(s, 0), timeout=10, what="hold to be dropped")
        self.assertIn("released", s.get("note", ""))
        self.assertLessEqual(s["writes"]["used"], 4 + 1, "may not exceed the limit (+1 release)")


class TestWriteLock(DaemonCase):
    fake_env = {"SMCFAN_FAKE_LIMIT": 3}

    def test_0x82_marks_writes_locked_and_stops_further_writes(self):
        self.start()
        self.cli("set", "0", "2000")          # writes 1-2 succeed
        r = self.cli("set", "1", "2000", ok=False)   # write 3 ok (Md), write 4 -> 0x82
        self.assertIn("0x82", r.stderr)
        s = self.state()
        self.assertTrue(s["writes"]["wedged"])
        used = s["writes"]["used"]
        self.assertEqual(used, 4)

        r = self.cli("set", "0", "3000", ok=False)
        self.assertIn("locked", r.stderr)
        self.assertEqual(self.state()["writes"]["used"], used, "no write may be attempted once locked")
        self.assertIn("LOCKED (0x82)", self.cli("status").stdout)
        # Releasing a still-forced fan needs a write, so it fails honestly, at no cost.
        r = self.cli("auto", ok=False)
        self.assertIn("locked", r.stderr)
        self.assertEqual(r.stderr.count("locked"), 1, "one message, not one per fan")
        self.assertEqual(self.state()["writes"]["used"], used)


class TestSafety(DaemonCase):
    def test_hold_with_ttl_is_released_when_it_expires(self):
        self.start()
        self.cli("set", "0", "2000", "--ttl", "1")
        self.wait_state(lambda s: self.fan(s, 0)["mode"] != 1, timeout=5, what="TTL release")

    def test_hot_sensor_refuses_new_holds(self):
        self.start(SMCFAN_FAKE_TEMP=96)
        r = self.cli("set", "0", "2000", ok=False)
        self.assertIn("96 °C", r.stderr)
        self.assertEqual(self.state()["writes"]["used"], 0)

    def test_hot_sensor_releases_forced_fans(self):
        temp_file = pathlib.Path(self.root, "temp")
        temp_file.write_text("50")
        self.start(SMCFAN_FAKE_TEMP_FILE=temp_file)
        self.cli("set", "0", "2000")
        temp_file.write_text("96")
        s = self.wait_state(lambda s: self.fan(s, 0)["mode"] != 1, timeout=5, what="hot release")
        self.assertIn("96", s.get("note", ""))

    def test_counter_survives_daemon_restart_in_same_boot(self):
        self.start()
        self.cli("set", "0", "2000")
        self.cli("auto", "0")
        self.stop()
        self.start()
        self.assertEqual(self.state()["writes"]["used"], 3)

    def test_stopping_the_daemon_releases_held_fans(self):
        self.start()
        self.cli("set", "0", "2000")
        self.stop()
        led = self.ledger()
        self.assertEqual(led["forced"], [])
        self.assertEqual(led["writes_used"], 3, "set (2) + release on SIGTERM (1)")
        self.assertEqual(led["last_write"]["key"], "F0Md")

    def test_counter_resets_on_a_new_boot(self):
        self.start()
        self.cli("set", "0", "2000")
        self.stop()
        path = pathlib.Path(self.root, "var/db/smcfan/ledger.json")
        led = json.loads(path.read_text())
        led["boot_time"] -= 3600              # pretend the ledger is from an earlier boot
        path.write_text(json.dumps(led))
        self.start()
        self.assertEqual(self.state()["writes"]["used"], 0)


class TestClientWithoutDaemon(unittest.TestCase):
    def test_status_explains_missing_daemon(self):
        root = tempfile.mkdtemp()
        try:
            r = subprocess.run([BIN, "status"], env=dict(os.environ, SMCFAN_ROOT=root),
                               capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("daemon not running", r.stderr)
        finally:
            shutil.rmtree(root)

    def test_example_snapshot_renders(self):
        r = subprocess.run([BIN, "status", "--state", str(REPO / "examples/state-m4max.json")],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("37/~100 used", r.stdout)
        self.assertIn("forced 2500 rpm", r.stdout)


if __name__ == "__main__":
    unittest.main()
