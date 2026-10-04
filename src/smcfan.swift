// smcfan — watch temperatures and fan speeds on an Apple Silicon Mac, force a
// fan to a fixed RPM, and keep count of how many SMC writes you have left
// before the SMC locks writes until the next reboot.
//
// One binary, two roles:
//   * `smcfan daemon` runs as a root LaunchDaemon. That context is required:
//     the SMC rejects value reads/writes from a plain `sudo` process.
//   * every other subcommand is an unprivileged client that reads the daemon's
//     state file and drops commands into its inbox.
//
// See README.md for the write limit (SMC result 0x82) this tool tracks.

import Darwin
import Foundation
import IOKit

// MARK: - Paths and tunables ---------------------------------------------------

let LABEL = "io.github.alfaiotadev.smcfan"
let HELPER_PATH = "/Library/PrivilegedHelperTools/smcfan"
let PLIST_PATH = "/Library/LaunchDaemons/\(LABEL).plist"
let LINK_PATH = "/usr/local/bin/smcfan"
let LOG_PATH = "/var/log/smcfan.log"

// SMCFAN_ROOT prefixes the runtime paths so the test suite can run a fake
// daemon in a temp directory. Unset in normal use.
let ROOT = ProcessInfo.processInfo.environment["SMCFAN_ROOT"] ?? ""
let RUN_DIR = "\(ROOT)/var/run/smcfan"
let STATE_PATH = "\(RUN_DIR)/state.json"      // live snapshot, world-readable
let INBOX_DIR = "\(RUN_DIR)/inbox"            // root:admin 0770, clients write here
let OUTBOX_DIR = "\(RUN_DIR)/outbox"          // root:admin 0775, daemon replies here
let KEYS_PATH = "\(RUN_DIR)/keys.tsv"         // output of `smcfan dump-keys`
let DB_DIR = "\(ROOT)/var/db/smcfan"
let LEDGER_PATH = "\(DB_DIR)/ledger.json"     // write counter, survives daemon restarts

let TICK_S = 1.0          // snapshot + hold maintenance
let INBOX_POLL_S = 0.1    // commands are picked up this often
let MAX_BATCH = 32        // commands handled per inbox pass; the rest wait
let MAX_CMD_AGE_S = 10.0  // older commands are dropped (the client gave up at 8 s)
// Writes accepted per boot before 0x82, observed on an M4 Max (macOS 26).
// An estimate, not a known constant: override with SMCFAN_BUDGET in the plist.
let DEFAULT_BUDGET = 100
// If any temperature sensor reaches this, forced fans are released to auto.
let HOT_RELEASE_C = 95.0
// Rate limit on SMC writes, so a script or a held-down key can't burn the
// budget. Releasing a fan to auto is always allowed. Override with
// SMCFAN_MAX_WRITES_PER_MIN in the plist.
let DEFAULT_MAX_WRITES_PER_MIN = 12

// MARK: - SMC IOConnect plumbing ---------------------------------------------
//
// 80-byte struct for IOConnectCallStructMethod(selector 2). Verified on M1 Max
// and M4 Max under macOS 26 — see docs/smc-protocol.md.

let STRUCT_SIZE = 80
let SELECTOR: UInt32 = 2
let SIZE_OFF = 0x1C, TYPE_OFF = 0x20, ATTR_OFF = 0x24
let RESULT_OFF = 0x28, CMD_OFF = 0x2A, INDEX_OFF = 0x2C, DATA_OFF = 0x30
let CMD_READ: UInt8 = 5, CMD_WRITE: UInt8 = 6, CMD_INDEX: UInt8 = 8, CMD_INFO: UInt8 = 9
let SMC_NOT_PRIVILEGED: UInt8 = 0x82

struct KeyInfo {
    let size: UInt32
    let type: String       // "flt ", "ui8 ", ...
    let typeBytes: [UInt8] // raw little-endian bytes, re-sent with cmd 5/6
    let attr: UInt8
}

protocol SMCDevice: AnyObject {
    func info(_ key: String) -> KeyInfo?
    func readBytes(_ key: String) -> (KeyInfo, [UInt8])?
    func write(_ key: String, _ bytes: [UInt8]) -> UInt8?
    func keyAt(_ index: UInt32) -> String?
}

extension SMCDevice {
    func read(_ key: String) -> Double? {
        guard let (ki, b) = readBytes(key) else { return nil }
        return decode(ki, b)
    }
}

final class SMC: SMCDevice {
    private var conn: io_connect_t = 0
    private var infoCache: [String: KeyInfo?] = [:]

    init?() {
        guard let matching = IOServiceMatching("AppleSMC") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(conn) }

    private func call(_ inp: [UInt8]) -> (kr: kern_return_t, out: [UInt8]) {
        var ip = inp
        var out = [UInt8](repeating: 0, count: STRUCT_SIZE)
        var outSize = STRUCT_SIZE
        let kr = IOConnectCallStructMethod(conn, SELECTOR, &ip, STRUCT_SIZE, &out, &outSize)
        return (kr, out)
    }

    // The key goes in as a little-endian UInt32, i.e. the FourCC bytes reversed.
    private func keyStruct(_ key: String) -> [UInt8] {
        let b = Array(key.utf8)
        precondition(b.count == 4, "SMC keys are exactly 4 ASCII characters")
        var inp = [UInt8](repeating: 0, count: STRUCT_SIZE)
        for (i, byte) in b.reversed().enumerated() { inp[i] = byte }
        return inp
    }

    func info(_ key: String) -> KeyInfo? {
        if let cached = infoCache[key] { return cached }
        var inp = keyStruct(key)
        inp[CMD_OFF] = CMD_INFO
        let r = call(inp)
        var ki: KeyInfo? = nil
        if r.kr == KERN_SUCCESS && r.out[RESULT_OFF] == 0 {
            let size = (0..<4).reduce(UInt32(0)) { $0 | UInt32(r.out[SIZE_OFF + $1]) << (8 * $1) }
            let tb = Array(r.out[TYPE_OFF..<TYPE_OFF + 4])
            ki = KeyInfo(size: size, type: String(bytes: tb.reversed(), encoding: .ascii) ?? "????",
                         typeBytes: tb, attr: r.out[ATTR_OFF])
        }
        infoCache[key] = ki
        return ki
    }

    // cmd 5 and cmd 6 must carry size/type/attr from a prior cmd 9.
    private func withInfo(_ key: String, _ ki: KeyInfo, _ cmd: UInt8) -> [UInt8] {
        var inp = keyStruct(key)
        for i in 0..<4 { inp[SIZE_OFF + i] = UInt8((ki.size >> (8 * UInt32(i))) & 0xFF) }
        for i in 0..<4 { inp[TYPE_OFF + i] = ki.typeBytes[i] }
        inp[ATTR_OFF] = ki.attr
        inp[CMD_OFF] = cmd
        return inp
    }

    func readBytes(_ key: String) -> (KeyInfo, [UInt8])? {
        guard let ki = info(key) else { return nil }
        let r = call(withInfo(key, ki, CMD_READ))
        guard r.kr == KERN_SUCCESS, r.out[RESULT_OFF] == 0 else { return nil }
        return (ki, Array(r.out[DATA_OFF..<DATA_OFF + Int(min(ki.size, 32))]))
    }

    // Returns the SMC result byte (0 = success), or nil if the key is unknown.
    // A kernel-level failure is reported as 0xFF.
    func write(_ key: String, _ bytes: [UInt8]) -> UInt8? {
        guard let ki = info(key), bytes.count == Int(ki.size) else { return nil }
        var inp = withInfo(key, ki, CMD_WRITE)
        for (i, b) in bytes.enumerated() { inp[DATA_OFF + i] = b }
        let r = call(inp)
        return r.kr == KERN_SUCCESS ? r.out[RESULT_OFF] : 0xFF
    }

    func keyAt(_ index: UInt32) -> String? {
        var inp = [UInt8](repeating: 0, count: STRUCT_SIZE)
        for i in 0..<4 { inp[INDEX_OFF + i] = UInt8((index >> (8 * UInt32(i))) & 0xFF) }
        inp[CMD_OFF] = CMD_INDEX
        let r = call(inp)
        guard r.kr == KERN_SUCCESS, r.out[RESULT_OFF] == 0 else { return nil }
        let s = String(bytes: [r.out[3], r.out[2], r.out[1], r.out[0]], encoding: .ascii) ?? ""
        return s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) ? s : nil
    }
}

func decode(_ ki: KeyInfo, _ b: [UInt8]) -> Double? {
    switch ki.type {
    case "flt " where b.count >= 4:
        let f = Float(bitPattern: (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[$1]) << (8 * $1) })
        return f.isFinite ? Double(f) : nil
    case "ui8 " where b.count >= 1:
        return Double(b[0])
    case "ui16" where b.count >= 2:
        return Double(UInt16(b[0]) | UInt16(b[1]) << 8)
    case "si16" where b.count >= 2:
        return Double(Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8))
    default:
        return nil
    }
}

func encodeFloat(_ v: Double) -> [UInt8] {
    let u = Float(v).bitPattern
    return (0..<4).map { UInt8((u >> (8 * UInt32($0))) & 0xFF) }
}

// In-memory stand-in for the SMC, used by `smcfan daemon --fake` and the test
// suite. Two fans; locks writes with 0x82 after SMCFAN_FAKE_LIMIT of them;
// optionally mimics macOS reclaiming forced fans every SMCFAN_FAKE_RECLAIM_S;
// every temperature key reads SMCFAN_FAKE_TEMP (or SMCFAN_FAKE_TEMP_FILE).
final class FakeSMC: SMCDevice {
    let env = ProcessInfo.processInfo.environment
    lazy var limit = env["SMCFAN_FAKE_LIMIT"].flatMap(Int.init) ?? DEFAULT_BUDGET
    lazy var reclaimEvery = env["SMCFAN_FAKE_RECLAIM_S"].flatMap(Double.init)
    lazy var fixedTemp = env["SMCFAN_FAKE_TEMP"].flatMap(Double.init) ?? 45
    // SMCFAN_FAKE_TEMP_FILE lets a test change the temperature while running.
    var temp: Double {
        guard let path = env["SMCFAN_FAKE_TEMP_FILE"],
              let s = try? String(contentsOfFile: path, encoding: .utf8),
              let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return fixedTemp }
        return v
    }
    var writes = 0
    var lastReclaim = Date()
    var values: [String: Double] = ["FNum": 2]

    static let flt = KeyInfo(size: 4, type: "flt ", typeBytes: Array("flt ".utf8.reversed()), attr: 0)
    static let ui8 = KeyInfo(size: 1, type: "ui8 ", typeBytes: Array("ui8 ".utf8.reversed()), attr: 0)

    init() {
        for id in 0..<2 {
            values["F\(id)Mn"] = 1350; values["F\(id)Mx"] = 5777
            // An M4 Max reports Md = 3 while macOS controls the fan.
            values["F\(id)Tg"] = 0; values["F\(id)Md"] = 3
        }
    }

    func info(_ key: String) -> KeyInfo? {
        if key == "FNum" || key.hasSuffix("Md") { return values[key] == nil ? nil : FakeSMC.ui8 }
        return values[key] != nil || key.hasPrefix("T") || key.hasSuffix("Ac") ? FakeSMC.flt : nil
    }

    func readBytes(_ key: String) -> (KeyInfo, [UInt8])? {
        if let every = reclaimEvery, Date().timeIntervalSince(lastReclaim) >= every {
            for id in 0..<2 { values["F\(id)Md"] = 3 }
            lastReclaim = Date()
        }
        guard let ki = info(key) else { return nil }
        var v = values[key] ?? 0
        if key.hasPrefix("T") { v = temp }
        if key.hasSuffix("Ac"), let id = Int(String(key.dropFirst().prefix(1))) {
            v = values["F\(id)Md"] == 1 ? values["F\(id)Tg"] ?? 0 : 1400
        }
        return (ki, ki.type == "ui8 " ? [UInt8(v)] : encodeFloat(v))
    }

    func write(_ key: String, _ bytes: [UInt8]) -> UInt8? {
        guard let ki = info(key), key.hasSuffix("Md") || key.hasSuffix("Tg") else { return nil }
        writes += 1
        if writes > limit { return SMC_NOT_PRIVILEGED }
        values[key] = decode(ki, bytes)
        return 0
    }

    func keyAt(_ index: UInt32) -> String? {
        let keys = ["#KEY"] + values.keys.sorted()
        return Int(index) < keys.count ? keys[Int(index)] : nil
    }
}

// MARK: - Environment ----------------------------------------------------------

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: buf)
}

func bootTime() -> Double {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
    return Double(tv.tv_sec)
}

func chipFamily() -> String {
    let brand = sysctlString("machdep.cpu.brand_string")   // "Apple M4 Max"
    guard let r = brand.range(of: #"M[0-9]+"#, options: .regularExpression) else { return brand }
    return String(brand[r])
}

// Temperature keys differ per chip family. Only keys observed to report live,
// varying Celsius values are listed; see docs/porting.md to add a family.
func temperatureKeys(_ family: String) -> (cpu: [String], gpu: [String]) {
    switch family {
    case "M1":
        return ((1...8).map { String(format: "Tp%02d", $0) },
                ["Tg05", "Tg0d", "Tg0f", "Tg0F", "Tg01", "Tg02", "Tg03", "Tg04"])
    case "M4":
        // Per-P-core keys exist but snap to placeholders whenever their
        // cluster power-gates; the E-cluster aggregates stay stable.
        return (["Tex0", "Tex1", "Tex2", "Tex3"],
                ["Tg0Y", "Tg0S", "Tg1F", "Tg1V", "Tg2Y", "Tg2Q", "Tg3K", "Tg3a"])
    default:
        return ([], [])
    }
}

// Idle, power-gated sensors return synthetic values (0.0, 1.5, exactly 40.0, ...).
func plausibleTemp(_ v: Double) -> Bool { v >= 15 && v < 150 && v != 40.0 }

// MARK: - JSON helpers ---------------------------------------------------------

func readJSON(_ path: String) -> [String: Any]? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

func writeJSON(_ path: String, _ obj: Any, mode: Int = 0o644) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted]) else { return }
    try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(ts) \(s)\n".data(using: .utf8)!)
}

func fail(_ s: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write("smcfan: \(s)\n".data(using: .utf8)!)
    exit(code)
}

// MARK: - Daemon -----------------------------------------------------------------

struct Forced { var rpm: Double; var expiresAt: Double? }

final class Daemon {
    let smc: SMCDevice
    let family = chipFamily()
    let temps: (cpu: [String], gpu: [String])
    let budget: Int
    let maxPerMin: Int
    var recentWrites: [Double] = []   // timestamps of writes in the last 60 s
    let boot = bootTime()
    var fanCount = 0
    var writesUsed = 0
    var wedged = false
    var lastWrite: [String: Any]? = nil
    var forced: [Int: Forced] = [:]
    var note: String? = nil
    var stopping = false
    var lastMaxTemp: Double? = nil

    init(smc: SMCDevice) {
        self.smc = smc
        temps = smc is FakeSMC ? (["TfC0", "TfC1"], ["TfG0"]) : temperatureKeys(family)
        let env = ProcessInfo.processInfo.environment
        budget = max(1, env["SMCFAN_BUDGET"].flatMap(Int.init) ?? DEFAULT_BUDGET)
        maxPerMin = max(2, env["SMCFAN_MAX_WRITES_PER_MIN"].flatMap(Int.init) ?? DEFAULT_MAX_WRITES_PER_MIN)
    }

    // MARK: ledger

    func loadLedger() {
        guard let l = readJSON(LEDGER_PATH), (l["boot_time"] as? Double) == boot else {
            log("new boot session; write counter starts at 0")
            return
        }
        writesUsed = l["writes_used"] as? Int ?? 0
        wedged = l["wedged"] as? Bool ?? false
        lastWrite = l["last_write"] as? [String: Any]
        // Fans a previous (crashed) daemon left forced in this boot session.
        for f in l["forced"] as? [[String: Any]] ?? [] {
            if let id = f["fan"] as? Int { forced[id] = Forced(rpm: 0, expiresAt: 0) }
        }
        log("resumed boot session: \(writesUsed) writes used, wedged=\(wedged)")
    }

    func saveLedger() {
        writeJSON(LEDGER_PATH, [
            "boot_time": boot, "writes_used": writesUsed, "wedged": wedged,
            "last_write": lastWrite ?? NSNull(),
            "forced": forced.keys.sorted().map { ["fan": $0] },
        ] as [String: Any], mode: 0o600)
    }

    // Every cmd=6 goes through here, so the counter is exact for this tool.
    func write(_ key: String, _ bytes: [UInt8]) -> String? {
        if wedged { return "SMC writes are locked (0x82) until reboot" }
        guard let result = smc.write(key, bytes) else { return "\(key): unknown key" }
        writesUsed += 1
        recentWrites.append(Date().timeIntervalSince1970)
        lastWrite = ["key": key, "result": String(format: "0x%02X", result), "ts": Date().timeIntervalSince1970]
        if result == SMC_NOT_PRIVILEGED {
            wedged = true
            log("\(key) -> 0x82 after \(writesUsed) writes this boot: writes locked until reboot")
        }
        saveLedger()
        return result == 0 ? nil : String(format: "\(key): SMC result 0x%02X", result)
    }

    // MARK: fan control

    func fanIds(_ fan: Int) -> [Int] { fan < 0 ? Array(0..<fanCount) : [fan] }

    func writesLastMinute() -> Int {
        let cutoff = Date().timeIntervalSince1970 - 60
        recentWrites.removeAll { $0 < cutoff }
        return recentWrites.count
    }

    // Seconds until `n` more writes fit under the per-minute limit.
    func rateWait(_ n: Int) -> Int {
        let used = writesLastMinute()
        guard used + n > maxPerMin else { return 0 }
        guard n <= maxPerMin, !recentWrites.isEmpty else { return 60 }
        let oldestThatMustExpire = recentWrites[min(recentWrites.count - 1, used + n - maxPerMin - 1)]
        return max(1, Int((oldestThatMustExpire + 60 - Date().timeIntervalSince1970).rounded(.up)))
    }

    // Writes needed to bring fan `id` to `rpm` from its current SMC state.
    func cost(_ id: Int, _ rpm: Double) -> Int {
        let mdCost = smc.read("F\(id)Md") == 1 ? 0 : 1
        let tgCost = smc.read("F\(id)Tg").map { abs($0 - rpm) < 1 } == true ? 0 : 1
        return mdCost + tgCost
    }

    // Anything but Md = 1 means macOS is in charge: an M4 Max reports 3 while
    // its own fan control runs, and 0 after a tool released the fan. Only a
    // forced fan needs the (counted) write.
    func release(_ id: Int) -> String? {
        forced.removeValue(forKey: id)
        saveLedger()
        guard let md = smc.read("F\(id)Md"), md == 1 else { return nil }
        return write("F\(id)Md", [0])
    }

    // Keep forced fans at their target, writing only what has drifted.
    // macOS's thermal control resets F<n>Md to 0 from time to time.
    // A fan whose write fails is dropped instead of retried every tick, so a
    // failing write can't drain the budget. Returns the failures by fan id.
    @discardableResult
    func enforce(maxTemp: Double?) -> [Int: String] {
        let now = Date().timeIntervalSince1970
        if let t = maxTemp, t >= HOT_RELEASE_C, !forced.isEmpty {
            note = String(format: "released forced fans: sensor at %.0f °C", t)
            log(note!)
            for id in forced.keys.sorted() { _ = release(id) }
            return [:]
        }
        var errors: [Int: String] = [:]
        for (id, f) in forced.sorted(by: { $0.key < $1.key }) {
            if let exp = f.expiresAt, now >= exp {
                _ = release(id)
                continue
            }
            var err: String? = nil
            // macOS keeps reclaiming this fan faster than the rate limit allows:
            // stop holding it rather than spend the budget fighting.
            let needed = cost(id, f.rpm)
            if needed > 0 && rateWait(needed) > 0 {
                _ = release(id)
                note = "fan \(id) released: holding it needed more than \(maxPerMin) writes/min"
                log(note!)
                continue
            }
            if smc.read("F\(id)Md") != 1 { err = write("F\(id)Md", [1]) }
            if err == nil, (smc.read("F\(id)Tg").map { abs($0 - f.rpm) >= 1 } ?? true) {
                err = write("F\(id)Tg", encodeFloat(f.rpm))
            }
            if let err {
                errors[id] = err
                forced.removeValue(forKey: id)
                saveLedger()
                note = "fan \(id) released after failed write: \(err)"
                log(note!)
            }
        }
        return errors
    }

    // Apply one command to the desired state. `set` only records the target;
    // processInbox() writes once for the whole batch, so ten quick `set`s to
    // the same fan cost no more than the last one. Returns a reply, or nil for
    // a `set` whose outcome is known only after that write.
    func handle(_ cmd: [String: Any], batch: inout [Int: Double]) -> [String: Any]? {
        let op = cmd["op"] as? String ?? ""
        let fan = cmd["fan"] as? Int ?? -1
        if op == "dump-keys" { return dumpKeys() }
        guard fan >= -1, fan < fanCount else { return ["ok": false, "error": "no fan \(fan) (this Mac has \(fanCount))"] }
        switch op {
        case "set":
            if wedged { return ["ok": false, "error": "SMC writes are locked (0x82) until reboot"] }
            if let t = lastMaxTemp, t >= HOT_RELEASE_C {
                return ["ok": false, "error": String(format: "refused: a sensor is at %.0f °C, fans stay on auto", t)]
            }
            guard let rpm = cmd["rpm"] as? Double else { return ["ok": false, "error": "missing rpm"] }
            let ttl = cmd["ttl_s"] as? Double
            var targets: [(Int, Double)] = []
            for id in fanIds(fan) {
                guard let mn = smc.read("F\(id)Mn"), let mx = smc.read("F\(id)Mx") else {
                    return ["ok": false, "error": "cannot read F\(id)Mn/F\(id)Mx"]
                }
                targets.append((id, min(mx, max(mn, rpm))))
            }
            // Cost of the batch's final state, not of each command: a later
            // command for the same fan replaces the earlier one.
            var tentative = batch
            for (id, target) in targets { tentative[id] = target }
            let needed = tentative.reduce(0) { $0 + cost($1.key, $1.value) }
            let wait = rateWait(needed)
            if wait > 0 {
                return ["ok": false, "error": "rate limited: max \(maxPerMin) SMC writes/min, try again in \(wait) s", "writes_spent": 0]
            }
            batch = tentative
            for (id, target) in targets {
                forced[id] = Forced(rpm: target, expiresAt: ttl.map { Date().timeIntervalSince1970 + $0 })
            }
            note = nil
            saveLedger()
            return nil
        case "auto":
            let before = writesUsed
            var errors: [String] = []
            for id in fanIds(fan) { if let e = release(id), !errors.contains(e) { errors.append(e) } }
            return errors.isEmpty ? ["ok": true, "writes_spent": writesUsed - before]
                                  : ["ok": false, "error": errors.joined(separator: "; "), "writes_spent": writesUsed - before]
        default:
            return ["ok": false, "error": "unknown op '\(op)'"]
        }
    }

    // Walk the whole SMC key table (read-only) so new chip families can be mapped.
    func dumpKeys() -> [String: Any] {
        guard let (_, b) = smc.readBytes("#KEY"), b.count >= 4 else { return ["ok": false, "error": "#KEY unreadable"] }
        let total = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        var lines = ["# \(sysctlString("machdep.cpu.brand_string")) \(sysctlString("hw.model")) keys=\(total)",
                     "# index\tkey\ttype\tsize\tvalue"]
        for i in 0..<total {
            guard let key = smc.keyAt(i), let ki = smc.info(key) else { continue }
            var value = "<unreadable>"
            if let (_, bytes) = smc.readBytes(key) {
                value = decode(ki, bytes).map { String(format: "%.3f", $0) }
                    ?? bytes.prefix(8).map { String(format: "%02x", $0) }.joined()
            }
            lines.append("\(i)\t\(key)\t\(ki.type)\t\(ki.size)\t\(value)")
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: KEYS_PATH, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: KEYS_PATH)
        return ["ok": true, "path": KEYS_PATH, "keys": total]
    }

    func processInbox() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: INBOX_DIR) else { return }
        let now = Date().timeIntervalSince1970
        var replies: [(String, [String: Any])] = []
        var deferred: [(String, [String: Any])] = []   // `set`s awaiting the batch write
        var batch: [Int: Double] = [:]
        let before = writesUsed

        // Clients write ".<id>.tmp" and rename, so only complete files match.
        // Oldest first, so within a batch the last command for a fan wins.
        let entries: [(name: String, mtime: Double)] = names.filter { $0.hasSuffix(".json") }.map { name in
            let m = (try? fm.attributesOfItem(atPath: "\(INBOX_DIR)/\(name)")[.modificationDate] as? Date)?.timeIntervalSince1970
            return (name, m ?? now)
        }
        for (name, mtime) in entries.sorted(by: { ($0.mtime, $0.name) < ($1.mtime, $1.name) }).prefix(MAX_BATCH) {
            let path = "\(INBOX_DIR)/\(name)"
            let cmd = readJSON(path)
            try? fm.removeItem(atPath: path)
            guard let cmd, let id = cmd["id"] as? String, id.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil else {
                log("dropped malformed command \(name)")
                continue
            }
            if now - mtime > MAX_CMD_AGE_S {
                log("dropped stale command \(id)")
                continue
            }
            if let reply = handle(cmd, batch: &batch) {
                replies.append((id, reply))
            } else {
                deferred.append((id, cmd))
            }
        }

        if !deferred.isEmpty {
            let errors = enforce(maxTemp: nil)
            let spent = writesUsed - before
            for (id, cmd) in deferred {
                let fan = cmd["fan"] as? Int ?? -1
                let failed = fanIds(fan).compactMap { f in errors[f].map { "fan \(f): \($0)" } }
                if !failed.isEmpty {
                    replies.append((id, ["ok": false, "error": failed.joined(separator: "; "), "writes_spent": spent]))
                    continue
                }
                let rpm = cmd["rpm"] as? Double ?? 0
                let fans: [[String: Any]] = fanIds(fan).compactMap { f in
                    guard let fz = forced[f] else { return nil }
                    let mn = smc.read("F\(f)Mn") ?? 0, mx = smc.read("F\(f)Mx") ?? .infinity
                    let own = min(mx, max(mn, rpm))
                    // A later command in the same batch replaced this one.
                    return ["fan": f, "rpm": own, "clamped": own != rpm, "superseded": fz.rpm != own]
                }
                replies.append((id, ["ok": true, "fans": fans, "writes_spent": spent]))
            }
        }

        // Publish the new state before replying, so a client that reads it
        // right after the reply sees the effect of its command.
        if !replies.isEmpty { publish() }
        for (id, var reply) in replies {
            reply["id"] = id
            log("command \(id) -> \(reply)")
            writeJSON("\(OUTBOX_DIR)/\(id).json", reply, mode: 0o664)
        }
    }

    // MARK: snapshot

    func readTemps(_ keys: [String]) -> [[String: Any]] {
        keys.compactMap { k in smc.read(k).flatMap { plausibleTemp($0) ? ["key": k, "c": ($0 * 10).rounded() / 10] : nil } }
    }

    func publish() {
        let (state, maxTemp) = snapshot()
        lastMaxTemp = maxTemp
        writeJSON(STATE_PATH, state)
    }

    func snapshot() -> (state: [String: Any], maxTemp: Double?) {
        let fans: [[String: Any]] = (0..<fanCount).map { id in
            var f: [String: Any] = ["id": id]
            for (s, field) in [("Ac", "actual_rpm"), ("Tg", "target_rpm"), ("Mn", "min_rpm"), ("Mx", "max_rpm"), ("Md", "mode")] {
                if let v = smc.read("F\(id)\(s)") { f[field] = (v * 10).rounded() / 10 }
            }
            if let fz = forced[id] {
                f["forced_rpm"] = fz.rpm
                if let e = fz.expiresAt { f["forced_until"] = e }
            }
            return f
        }
        let cpu = readTemps(temps.cpu), gpu = readTemps(temps.gpu)
        let all = (cpu + gpu).compactMap { $0["c"] as? Double }
        var state: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "pid": Int(getpid()),
            "chip": sysctlString("machdep.cpu.brand_string"),
            "model": sysctlString("hw.model"),
            "fans": fans,
            "temps": ["cpu": cpu, "gpu": gpu],
            "writes": [
                "boot_time": boot, "used": writesUsed, "budget": budget,
                "remaining": max(0, budget - writesUsed), "wedged": wedged,
                "last_minute": writesLastMinute(), "max_per_minute": maxPerMin,
                "last": lastWrite ?? NSNull(),
            ] as [String: Any],
        ]
        if let note { state["note"] = note }
        return (state, all.max())
    }

    // MARK: run loop

    func prepareDirs() {
        let fm = FileManager.default
        for (dir, mode) in [(RUN_DIR, 0o755), (INBOX_DIR, 0o770), (OUTBOX_DIR, 0o775), (DB_DIR, 0o700)] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var attrs: [FileAttributeKey: Any] = [.posixPermissions: mode, .ownerAccountID: 0]
            // Members of `admin` may submit commands without sudo.
            if dir == INBOX_DIR || dir == OUTBOX_DIR { attrs[.groupOwnerAccountName] = "admin" }
            try? fm.setAttributes(attrs, ofItemAtPath: dir)
        }
    }

    func run() -> Never {
        prepareDirs()
        if let n = smc.read("FNum") { fanCount = min(8, Int(n)) }
        log("starting: \(sysctlString("machdep.cpu.brand_string")), \(fanCount) fans, budget \(budget)")
        if fanCount == 0 {
            log("FNum unreadable: wrong signing/launch context, or a fanless Mac")
        }
        loadLedger()

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [unowned self] in self.stopping = true }
            src.resume()
            _ = Unmanaged.passRetained(src)
        }

        var nextTick = Date.distantPast
        while !stopping {
            if Date() >= nextTick {
                publish()
                let before = (writesUsed, forced.count)
                enforce(maxTemp: lastMaxTemp)
                if (writesUsed, forced.count) != before { publish() }
                nextTick = Date().addingTimeInterval(TICK_S)
            }
            processInbox()
            RunLoop.main.run(until: Date().addingTimeInterval(INBOX_POLL_S))
        }
        // Never leave a fan pinned when the daemon goes away.
        for id in forced.keys.sorted() { _ = release(id) }
        try? FileManager.default.removeItem(atPath: STATE_PATH)
        log("stopped")
        exit(0)
    }
}

// MARK: - Client -----------------------------------------------------------------

// Live daemon state, or a human-readable reason it isn't available.
// Set by --state FILE: render a saved snapshot instead of the live daemon state.
var stateOverride: String? = nil

func currentState() -> (state: [String: Any]?, error: String?) {
    if let path = stateOverride {
        return readJSON(path).map { ($0, nil) } ?? (nil, "cannot read \(path)")
    }
    guard let s = readJSON(STATE_PATH) else {
        return (nil, "daemon not running (no \(STATE_PATH)). Install it with: sudo smcfan install")
    }
    if let ts = s["ts"] as? Double, Date().timeIntervalSince1970 - ts > 10 {
        return (nil, "daemon state is stale (last update \(Int(Date().timeIntervalSince1970 - ts)) s ago); see \(LOG_PATH)")
    }
    return (s, nil)
}

func loadState() -> [String: Any] {
    let (s, err) = currentState()
    guard let s else { fail(err ?? "no state") }
    return s
}

// Submit a command to the daemon and wait for its reply. Failures come back as
// ["ok": false, "error": ...] so interactive callers can show them inline.
func send(_ cmd: [String: Any], timeout: Double = 8) -> [String: Any] {
    let id = UUID().uuidString
    var c = cmd
    c["id"] = id
    guard let d = try? JSONSerialization.data(withJSONObject: c) else { return ["ok": false, "error": "encode failed"] }
    let tmp = "\(INBOX_DIR)/.\(id).tmp"
    guard FileManager.default.createFile(atPath: tmp, contents: d) else {
        return ["ok": false, "error": "cannot write to \(INBOX_DIR) (your user must be in the admin group, or use sudo)"]
    }
    // Rename into place so the daemon never reads a half-written command.
    guard rename(tmp, "\(INBOX_DIR)/\(id).json") == 0 else { return ["ok": false, "error": "cannot submit command"] }
    let out = "\(OUTBOX_DIR)/\(id).json"
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let r = readJSON(out) {
            try? FileManager.default.removeItem(atPath: out)
            return r
        }
        usleep(100_000)
    }
    return ["ok": false, "error": "no reply from daemon within \(Int(timeout)) s"]
}

func fmt(_ v: Any?, _ f: String = "%.0f") -> String {
    guard let d = v as? Double else { return "-" }
    return String(format: f, d)
}

func render(_ s: [String: Any], color: Bool, selected: Int? = nil) -> String {
    func c(_ code: String, _ t: String) -> String { color ? "\u{1B}[\(code)m\(t)\u{1B}[0m" : t }
    var out: [String] = []
    out.append(c("1", "smcfan") + "  \(s["chip"] ?? "?") (\(s["model"] ?? "?"))")
    out.append("")

    let temps = s["temps"] as? [String: Any] ?? [:]
    for (label, key) in [("CPU", "cpu"), ("GPU", "gpu")] {
        let vals = (temps[key] as? [[String: Any]] ?? []).compactMap { $0["c"] as? Double }
        if vals.isEmpty { out.append("\(label)  -   (no sensor map for this chip, see docs/porting.md)"); continue }
        let avg = vals.reduce(0, +) / Double(vals.count), mx = vals.max()!
        let tone = mx >= 90 ? "31" : mx >= 75 ? "33" : "32"
        out.append("\(label)  avg " + c(tone, String(format: "%5.1f °C", avg)) + String(format: "   max %5.1f °C   (%d sensors)", mx, vals.count))
    }
    out.append("")

    out.append("FAN  ACTUAL   TARGET     MIN     MAX  MODE")
    for f in s["fans"] as? [[String: Any]] ?? [] {
        let id = f["id"] as? Int ?? 0
        var mode = (f["mode"] as? Double) == 1 ? c("33", "forced") : "auto"
        if let r = f["forced_rpm"] as? Double {
            mode = c("33", "forced \(Int(r)) rpm")
            if let u = f["forced_until"] as? Double { mode += " (\(max(0, Int(u - Date().timeIntervalSince1970))) s left)" }
        }
        let cols = [("actual_rpm", 6), ("target_rpm", 8), ("min_rpm", 7), ("max_rpm", 7)].map { key, width in
            let v = fmt(f[key])
            return String(repeating: " ", count: max(0, width - v.count)) + v
        }
        let head = String(format: "%3d  ", id) + cols.joined(separator: " ")
        out.append((selected == id ? c("7", ">" + head.dropFirst()) : head) + "  " + mode)
    }
    out.append("")

    let w = s["writes"] as? [String: Any] ?? [:]
    let used = w["used"] as? Int ?? 0, budget = w["budget"] as? Int ?? DEFAULT_BUDGET
    let remaining = w["remaining"] as? Int ?? 0
    if w["wedged"] as? Bool == true {
        out.append("SMC writes  " + c("31;1", "LOCKED (0x82): reboot to restore fan control") + " (\(used) by smcfan this boot)")
    } else {
        let width = 30
        let filled = min(width, Int((Double(used) / Double(budget) * Double(width)).rounded()))
        let tone = remaining <= budget / 5 ? "31" : remaining <= budget / 2 ? "33" : "32"
        out.append("SMC writes  [" + c(tone, String(repeating: "#", count: filled)) + String(repeating: ".", count: width - filled)
                   + "] \(used)/~\(budget) used, " + c(tone, "~\(remaining) left") + " before a reboot is needed")
    }
    if let bt = w["boot_time"] as? Double {
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
        out.append("            counted since boot at \(df.string(from: Date(timeIntervalSince1970: bt))); writes by other tools are not seen")
    }
    if let note = s["note"] as? String { out.append(c("33", "note: \(note)")) }
    return out.joined(separator: "\n")
}

func parseFan(_ arg: String?) -> Int {
    guard let arg, arg != "all" else { return -1 }
    guard let n = Int(arg), n >= 0 else { fail("fan must be a number or 'all'", code: 64) }
    return n
}

func printReply(_ r: [String: Any]) -> Never {
    if r["ok"] as? Bool == true {
        var msg = "ok"
        if let spent = r["writes_spent"] as? Int { msg += ", \(spent) SMC write\(spent == 1 ? "" : "s") spent" }
        print(msg)
        if let fans = r["fans"] as? [[String: Any]] {
            for f in fans {
                var line = "fan \(f["fan"] ?? "?") -> \(fmt(f["rpm"])) rpm"
                if (f["clamped"] as? Bool) == true { line += " (clamped to fan limits)" }
                if (f["superseded"] as? Bool) == true { line += " (superseded by a newer command)" }
                print(line)
            }
        }
        exit(0)
    }
    fail(r["error"] as? String ?? "failed")
}

// MARK: - TUI ------------------------------------------------------------------
//
// Plain termios + ANSI escapes, no curses. Adjusting a target only changes a
// local pending value; nothing reaches the SMC until Enter, so browsing and
// fiddling with +/- costs no writes.

var savedTermios = termios()
var termiosSaved = false

func restoreTerminal() {
    if termiosSaved { tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios) }
    // Show cursor, leave the alternate screen.
    print("\u{1B}[?25h\u{1B}[?1049l", terminator: "")
    fflush(stdout)
}

func enterRawMode() {
    guard tcgetattr(STDIN_FILENO, &savedTermios) == 0 else { fail("stdin is not a terminal") }
    termiosSaved = true
    var raw = savedTermios
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)   // keep ISIG so Ctrl-C still works
    // read() returns after 0.2 s even without input: that's the refresh tick.
    withUnsafeMutableBytes(of: &raw.c_cc) { cc in
        cc[Int(VMIN)] = 0
        cc[Int(VTIME)] = 2
    }
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig) { _ in restoreTerminal(); exit(0) } }
    print("\u{1B}[?1049h\u{1B}[?25l", terminator: "")
}

enum Key { case up, down, left, right, char(Character) }

// Everything typed since the last tick; fast typing or key repeat delivers
// several keys in one read().
func readKeys() -> [Key] {
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(STDIN_FILENO, &buf, buf.count)
    guard n > 0 else { return [] }
    var keys: [Key] = []
    var i = 0
    while i < n {
        let b = buf[i]
        if b == 0x1B, i + 2 < n, buf[i + 1] == UInt8(ascii: "[") {
            switch buf[i + 2] {
            case UInt8(ascii: "A"): keys.append(.up)
            case UInt8(ascii: "B"): keys.append(.down)
            case UInt8(ascii: "C"): keys.append(.right)
            case UInt8(ascii: "D"): keys.append(.left)
            default: break
            }
            i += 3
            continue
        }
        if b == 0x0A || b == 0x0D { keys.append(.char("\n")) }
        else if b >= 0x20 && b < 0x7F { keys.append(.char(Character(UnicodeScalar(b)))) }
        i += 1
    }
    return keys
}

func tui() -> Never {
    let ttlChoices: [Double?] = [nil, 30, 60, 300]
    var selected = 0
    var ttlIdx = 0
    var pending: [Int: Double] = [:]  // fan id -> target the user is dialling in
    var message = "↑↓ pick a fan, ←→ or +/- to dial a target, Enter to apply"
    var lastDraw = Date.distantPast
    var dirty = true
    var queued: [Key] = []

    enterRawMode()
    defer { restoreTerminal() }

    func fans(_ s: [String: Any]?) -> [[String: Any]] { s?["fans"] as? [[String: Any]] ?? [] }

    while true {
        let (state, err) = currentState()
        let fanList = fans(state)
        if !fanList.isEmpty { selected = min(selected, fanList.count - 1) }
        let fan = fanList.isEmpty ? nil : fanList[selected]
        let mn = fan?["min_rpm"] as? Double ?? 0, mx = fan?["max_rpm"] as? Double ?? 0
        let isForced = fan?["forced_rpm"] != nil
        if let fan, pending[selected] == nil {
            let start = fan["forced_rpm"] as? Double ?? fan["actual_rpm"] as? Double ?? mn
            pending[selected] = min(mx, max(mn, (start / 100).rounded() * 100))
        }
        let target = pending[selected] ?? 0
        let w = state?["writes"] as? [String: Any] ?? [:]
        let wedged = w["wedged"] as? Bool == true

        if dirty || Date().timeIntervalSince(lastDraw) >= 1 {
            var screen = "\u{1B}[H"
            if let state {
                screen += render(state, color: true, selected: selected)
            } else {
                screen += "smcfan\n\n" + (err ?? "no state")
            }
            let ttl = ttlChoices[ttlIdx].map { "\(Int($0)) s" } ?? "until released"
            let cost = wedged ? "locked until reboot" : "costs \(isForced ? 1 : 2) write\(isForced ? "" : "s")"
            screen += "\n\n"
            screen += fan == nil ? "" : String(format: "fan %d  target  ◂ %5.0f rpm ▸   hold: %@   Enter %@\n", selected, target, ttl, cost)
            screen += "↑↓ fan   ←→ ±100   [ ] ±500   n min   m max   t hold time   a auto   A all auto   q quit\n"
            screen += "\u{1B}[2m\(message)\u{1B}[0m"
            // Clear to end of each line and below, so shorter frames leave no residue.
            print(screen.replacingOccurrences(of: "\n", with: "\u{1B}[K\n") + "\u{1B}[K\u{1B}[J", terminator: "")
            fflush(stdout)
            lastDraw = Date()
            dirty = false
        }

        // One key per pass, so fan selection and limits are fresh for each.
        if queued.isEmpty { queued = readKeys() }
        guard !queued.isEmpty else { continue }
        let key = queued.removeFirst()
        dirty = true
        func dial(_ delta: Double) { pending[selected] = min(mx, max(mn, target + delta)) }
        switch key {
        case .up: selected = max(0, selected - 1)
        case .down: selected = min(max(0, fanList.count - 1), selected + 1)
        case .left, .char("-"): dial(-100)
        case .right, .char("+"), .char("="): dial(100)
        case .char("["): dial(-500)
        case .char("]"): dial(500)
        case .char("n"): pending[selected] = mn
        case .char("m"): pending[selected] = mx
        case .char("t"): ttlIdx = (ttlIdx + 1) % ttlChoices.count
        case .char("q"), .char("Q"): restoreTerminal(); exit(0)
        case .char("\n"):
            guard fan != nil else { break }
            message = "applying…"
            var cmd: [String: Any] = ["op": "set", "fan": selected, "rpm": target]
            if let ttl = ttlChoices[ttlIdx] { cmd["ttl_s"] = ttl }
            message = describe(send(cmd))
        case .char("a"):
            guard fan != nil else { break }
            message = describe(send(["op": "auto", "fan": selected]))
            pending[selected] = nil
        case .char("A"):
            message = describe(send(["op": "auto", "fan": -1]))
            pending.removeAll()
        default: dirty = false
        }
    }
}

func describe(_ r: [String: Any]) -> String {
    let spent = (r["writes_spent"] as? Int).map { ", \($0) SMC write\($0 == 1 ? "" : "s") spent" } ?? ""
    if r["ok"] as? Bool == true { return "ok" + spent }
    return "error: \(r["error"] as? String ?? "failed")" + spent
}

// MARK: - Install --------------------------------------------------------------

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func requireRoot(_ what: String) {
    if geteuid() != 0 { fail("\(what) needs root: sudo smcfan \(what)", code: 77) }
}

func install() {
    requireRoot("install")
    let fm = FileManager.default
    let source = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let sig = run("/usr/bin/codesign", ["-dvv", source]).output
    if !sig.contains("Authority=Developer ID Application") || !sig.contains("runtime") {
        print("warning: \(source) is not signed with a Developer ID Application certificate + hardened runtime.")
        print("         The SMC will refuse every call (kIOReturnNotPrivileged). See README > Build.")
    }
    run("/bin/launchctl", ["bootout", "system/\(LABEL)"])
    if source != HELPER_PATH {
        try? fm.removeItem(atPath: HELPER_PATH)
        do { try fm.copyItem(atPath: source, toPath: HELPER_PATH) } catch { fail("copy to \(HELPER_PATH): \(error)") }
    }
    try? fm.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: HELPER_PATH)

    let plist: [String: Any] = [
        "Label": LABEL,
        "ProgramArguments": [HELPER_PATH, "daemon"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "ThrottleInterval": 10,
        "StandardErrorPath": LOG_PATH,
        "StandardOutPath": LOG_PATH,
        "EnvironmentVariables": ["SMCFAN_BUDGET": String(DEFAULT_BUDGET),
                                 "SMCFAN_MAX_WRITES_PER_MIN": String(DEFAULT_MAX_WRITES_PER_MIN)],
    ]
    guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { fail("plist encode") }
    guard fm.createFile(atPath: PLIST_PATH, contents: data,
                        attributes: [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0]) else {
        fail("cannot write \(PLIST_PATH)")
    }
    try? fm.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
    try? fm.removeItem(atPath: LINK_PATH)
    try? fm.createSymbolicLink(atPath: LINK_PATH, withDestinationPath: HELPER_PATH)

    let r = run("/bin/launchctl", ["bootstrap", "system", PLIST_PATH])
    if r.status != 0 { fail("launchctl bootstrap failed: \(r.output)") }
    print("installed \(LABEL); `smcfan watch` to see it. Log: \(LOG_PATH)")
    exit(0)
}

func uninstall() {
    requireRoot("uninstall")
    // bootout sends SIGTERM; the daemon releases any forced fan before exiting.
    run("/bin/launchctl", ["bootout", "system/\(LABEL)"])
    for p in [PLIST_PATH, HELPER_PATH, RUN_DIR, DB_DIR] { try? FileManager.default.removeItem(atPath: p) }
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: LINK_PATH)) == HELPER_PATH {
        try? FileManager.default.removeItem(atPath: LINK_PATH)
    }
    print("uninstalled (log left at \(LOG_PATH))")
    exit(0)
}

// MARK: - main -------------------------------------------------------------------

let usage = """
smcfan — Apple Silicon fan monitor/control with an SMC write counter

  smcfan                            interactive TUI (status, when not on a terminal)
  smcfan tui                        interactive TUI: watch + set/auto from the keyboard
  smcfan status [--json]            temperatures, fans and writes left (one shot)
  smcfan watch [--interval S]       read-only status, refreshing (default 1 s)
  smcfan set <fan|all> <rpm> [--ttl S]
                                    hold fan(s) at <rpm> (clamped to min..max),
                                    optionally only for S seconds
  smcfan auto [fan|all]             hand fan(s) back to macOS (default: all)
  smcfan dump-keys                  write the full SMC key table to \(KEYS_PATH)

  --state FILE                      (any view) render a saved snapshot instead of
                                    the live daemon state; for testing/screenshots

  sudo smcfan install               install + start the root LaunchDaemon
  sudo smcfan uninstall             stop it and remove every installed file

Writes: the SMC stops accepting writes after roughly \(DEFAULT_BUDGET) of them per boot
(result 0x82) and only a reboot clears that. `set` costs 2 writes per fan,
`auto` 1, and keeping a fan forced costs more whenever macOS resets it.
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func option(_ name: String) -> Double? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count, let v = Double(args[i + 1]) else { fail("\(name) needs a number", code: 64) }
    args.removeSubrange(i...(i + 1))
    return v
}

if let i = args.firstIndex(of: "--state") {
    guard i + 1 < args.count else { fail("--state needs a file", code: 64) }
    stateOverride = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let command = args.first ?? (isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 ? "tui" : "status")
if !args.isEmpty { args.removeFirst() }

switch command {
case "daemon":
    if flag("--fake") { Daemon(smc: FakeSMC()).run() }
    guard let smc = SMC() else { log("IOServiceOpen(AppleSMC) failed"); exit(1) }
    Daemon(smc: smc).run()

case "status":
    let json = flag("--json")
    let s = loadState()
    if json {
        let d = try! JSONSerialization.data(withJSONObject: s, options: [.sortedKeys, .prettyPrinted])
        print(String(data: d, encoding: .utf8)!)
    } else {
        print(render(s, color: isatty(1) != 0))
    }

case "tui":
    tui()

case "watch":
    let interval = max(0.5, option("--interval") ?? 1)
    signal(SIGINT) { _ in print("\u{1B}[?25h"); exit(0) }
    print("\u{1B}[?25l", terminator: "")
    while true {
        print("\u{1B}[H\u{1B}[2J" + render(loadState(), color: true) + "\n\nCtrl-C to quit")
        usleep(UInt32(interval * 1_000_000))
    }

case "set":
    let ttl = option("--ttl")
    guard args.count == 2, let rpm = Double(args[1]), rpm >= 0 else { fail("usage: smcfan set <fan|all> <rpm> [--ttl S]", code: 64) }
    if let ttl, ttl < 1 { fail("--ttl must be at least 1 s", code: 64) }
    _ = loadState()
    var cmd: [String: Any] = ["op": "set", "fan": parseFan(args[0]), "rpm": rpm]
    if let ttl { cmd["ttl_s"] = ttl }
    printReply(send(cmd))

case "auto":
    _ = loadState()
    printReply(send(["op": "auto", "fan": parseFan(args.first)]))

case "dump-keys":
    _ = loadState()
    let r = send(["op": "dump-keys"], timeout: 60)
    if r["ok"] as? Bool == true { print("wrote \(r["keys"] ?? "?") keys to \(r["path"] ?? KEYS_PATH)"); exit(0) }
    printReply(r)

case "install": install()
case "uninstall": uninstall()
case "help", "-h", "--help": print(usage)
default: fail("unknown command '\(command)'\n\n\(usage)", code: 64)
}
