import Foundation
import AppKit
import CoreGraphics
import CGVirtualDisplayPrivate

// MARK: - State files (~/.agent-display/displays/<name>.json)

struct DisplayState: Codable {
    var name: String
    var pid: Int32
    var displayID: UInt32
    var width: Int
    var height: Int
    var hidpi: Bool
    var createdAt: Date

    var alive: Bool { kill(pid, 0) == 0 }

    var dict: [String: Any] {
        var d: [String: Any] = [
            "name": name, "pid": Int(pid), "displayID": Int(displayID),
            "width": width, "height": height, "hidpi": hidpi, "virtual": true,
        ]
        if CGDisplayIsActive(displayID) != 0 { d["bounds"] = rectDict(CGDisplayBounds(displayID)) }
        return d
    }

    static var dir: URL {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-display/displays", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func url(for name: String) -> URL {
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return dir.appendingPathComponent(String(safe) + ".json")
    }

    static func load(_ name: String) -> DisplayState? {
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(DisplayState.self, from: data)
    }

    func save() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        try enc.encode(self).write(to: DisplayState.url(for: name), options: .atomic)
    }

    static func remove(_ name: String) { try? FileManager.default.removeItem(at: url(for: name)) }

    /// All live states; stale files (dead pid) are cleaned up.
    static func all() -> [DisplayState] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var out: [DisplayState] = []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), let s = try? dec.decode(DisplayState.self, from: d) else { continue }
            if s.alive { out.append(s) } else { try? FileManager.default.removeItem(at: f) }
        }
        return out.sorted { $0.name < $1.name }
    }
}

// MARK: - Display lookup

func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func screenName(_ id: CGDirectDisplayID) -> String? {
    NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    }?.localizedName
}

/// Accepts a virtual display name, a numeric display ID, "main", or a screen's localized name.
func resolveDisplay(_ s: String) throws -> CGDirectDisplayID {
    if s.lowercased() == "main" { return CGMainDisplayID() }
    if let n = UInt32(s), activeDisplays().contains(n) { return n }
    if let st = DisplayState.load(s), st.alive { return st.displayID }
    if let id = activeDisplays().first(where: { screenName($0)?.lowercased() == s.lowercased() }) { return id }
    throw ToolError("no display named '\(s)'. Run `agent-display list`.")
}

func displayFor(point p: CGPoint) -> CGDirectDisplayID? {
    activeDisplays().first { CGDisplayBounds($0).contains(p) }
}

func listDisplays() -> [String: Any] {
    let virtuals = Dictionary(uniqueKeysWithValues: DisplayState.all().map { ($0.displayID, $0) })
    let displays: [[String: Any]] = activeDisplays().map { id in
        var d: [String: Any] = [
            "displayID": Int(id),
            "bounds": rectDict(CGDisplayBounds(id)),
            "pixelWidth": CGDisplayPixelsWide(id),
            "pixelHeight": CGDisplayPixelsHigh(id),
            "main": CGDisplayIsMain(id) != 0,
            "builtin": CGDisplayIsBuiltin(id) != 0,
        ]
        if let n = screenName(id) { d["name"] = n }
        if let v = virtuals[id] { d["virtual"] = true; d["agentDisplayName"] = v.name; d["pid"] = Int(v.pid) }
        return d
    }
    return ["displays": displays]
}

// MARK: - Hosting a virtual display (foreground process; display lives as long as it does)

private var hostedDisplay: CGVirtualDisplay?
private var signalSources: [DispatchSourceSignal] = []

private func stableSerial(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
    return h
}

enum DisplayHost {
    static func runForeground(_ a: Args) -> Never {
        do { try host(a) } catch {
            print(jsonString(["error": "\(error)"]))
            exit(1)
        }
        let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    private static func host(_ a: Args) throws {
        let name = a.str("name") ?? "Agent Display"
        let width = a.int("width") ?? 1920
        let height = a.int("height") ?? 1080
        let hidpi = a.bool("hidpi") ?? false
        let refresh = a.double("refresh") ?? 60

        if let existing = DisplayState.load(name), existing.alive {
            throw ToolError("display '\(name)' already running (pid \(existing.pid))")
        }

        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)

        let scale = hidpi ? 2 : 1
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.name = name
        desc.maxPixelsWide = UInt32(width * scale)
        desc.maxPixelsHigh = UInt32(height * scale)
        // ~110 points per inch, a typical desktop monitor density.
        desc.sizeInMillimeters = CGSize(width: Double(width) / 110 * 25.4, height: Double(height) / 110 * 25.4)
        desc.vendorID = 0xA9E7
        desc.productID = 0xD15B
        desc.serialNum = stableSerial(name)
        desc.terminationHandler = { _, _ in
            log("virtual display terminated by the system")
            DisplayState.remove(name)
            exit(0)
        }

        guard let display = CGVirtualDisplay(descriptor: desc) else {
            throw ToolError("CGVirtualDisplay init failed (unsupported macOS version?)")
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hidpi ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt32(width * scale), height: UInt32(height * scale), refreshRate: refresh)]
        guard display.apply(settings) else { throw ToolError("applySettings failed") }
        hostedDisplay = display
        let id = display.displayID

        // Wait for WindowServer to bring the display online.
        let deadline = Date().addingTimeInterval(5)
        while !activeDisplays().contains(id), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        guard activeDisplays().contains(id) else { throw ToolError("display \(id) never came online") }

        if hidpi { selectHiDPIMode(id, width: width, height: height) }
        if let pos = a.str("position") { arrange(id, position: pos) }

        let state = DisplayState(name: name, pid: getpid(), displayID: id, width: width, height: height, hidpi: hidpi, createdAt: Date())
        try state.save()

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                DisplayState.remove(name)
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
        print(jsonString(state.dict))
        fflush(stdout)
    }

    private static func selectHiDPIMode(_ id: CGDirectDisplayID, width: Int, height: Int) {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return }
        if let m = modes.first(where: { $0.width == width && $0.height == height && $0.pixelWidth == width * 2 }) {
            CGDisplaySetDisplayMode(id, m, nil)
        }
    }

    /// Place the virtual display at the far edge of the arrangement so the user's
    /// cursor rarely wanders onto it.
    private static func arrange(_ id: CGDirectDisplayID, position: String) {
        let others = activeDisplays().filter { $0 != id }.map { CGDisplayBounds($0) }
        guard !others.isEmpty else { return }
        let union = others.reduce(others[0]) { $0.union($1) }
        let me = CGDisplayBounds(id)
        let origin: CGPoint
        switch position.lowercased() {
        case "left": origin = CGPoint(x: union.minX - me.width, y: union.minY)
        case "above", "top": origin = CGPoint(x: union.minX, y: union.minY - me.height)
        case "below", "bottom": origin = CGPoint(x: union.minX, y: union.maxY)
        default: origin = CGPoint(x: union.maxX, y: union.minY)
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        _ = CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
        _ = CGCompleteDisplayConfiguration(config, .forSession)
    }
}

// MARK: - start / stop (manage a background host process)

enum DisplayManager {
    static func start(_ a: Args) async throws -> Output {
        let name = a.str("name") ?? "Agent Display"
        if let s = DisplayState.load(name), s.alive {
            var d = s.dict; d["alreadyRunning"] = true
            return .json(d)
        }
        DisplayState.remove(name)

        guard let exe = Bundle.main.executablePath else { throw ToolError("cannot locate own executable") }
        var argv = [exe, "create", "--name", name]
        for k in ["width", "height", "hidpi", "refresh", "position"] {
            if let v = a.str(k) { argv += ["--\(k)", v] }
        }
        let logPath = DisplayState.dir.appendingPathComponent(DisplayState.url(for: name).deletingPathExtension().lastPathComponent + ".log").path

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(0x0400)) // POSIX_SPAWN_SETSID: survive the caller's shell
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_addopen(&fa, 2, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        defer { posix_spawnattr_destroy(&attr); posix_spawn_file_actions_destroy(&fa) }

        let cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &fa, &attr, cargs, environ)
        guard rc == 0 else { throw ToolError("posix_spawn failed: \(String(cString: strerror(rc)))") }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let s = DisplayState.load(name), s.pid == pid { return .json(s.dict) }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                let logText = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
                throw ToolError("display host exited: \(logText.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ToolError("timed out waiting for display '\(name)' (see \(logPath))")
    }

    static func stop(_ a: Args) async throws -> Output {
        let targets: [DisplayState]
        if a.bool("all") == true {
            targets = DisplayState.all()
        } else {
            let name = a.str("name") ?? "Agent Display"
            guard let s = DisplayState.load(name) else { throw ToolError("no running display named '\(name)'") }
            targets = [s]
        }
        var stopped: [String] = []
        for s in targets {
            if s.alive { kill(s.pid, SIGTERM) }
            let deadline = Date().addingTimeInterval(3)
            while s.alive, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            if s.alive { kill(s.pid, SIGKILL) }
            DisplayState.remove(s.name)
            stopped.append(s.name)
        }
        return .json(["stopped": stopped])
    }
}
