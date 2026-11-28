import AppKit
import CedricCore

/// CEDRIC_CHECK=sidebarclick (Scripts/sidebar-click-check.sh): how long a
/// folder sidebar click takes until the file's text is on screen, for a
/// research folder like Derek's (0.6.1): Markdown notes, a pcap capture,
/// a GPX track and big wardrive logs. Writes the folder in the check's
/// temp folder, opens it in the sidebar and clicks the rows with real
/// mouse events (FolderSidebar.clicked, the onOpen route a click takes).
/// For each kind of file:
///
///   cold     a click on a file not opened before in this run (copies of
///            each kind, so each sample is a first open)
///   reopen   the same file again after its tab was closed
///   switch   a click on a file whose tab is open, from another tab
///   dblclick a double click on a closed file (Markdown only: the second
///            onOpen of a double click)
///
/// Each sample: `shown`, the click until the first display pass of that
/// file's text view (SidebarOpenTrace); `stall`, the longest the main
/// thread went without a turn of its run loop (a 1 ms timer's gaps) from
/// the click until just after that pass; `after`, the longest gap in the
/// 0.5 s after it (deferred work: colouring, spelling, git, the owl); and
/// the OpenSignpost phases. Prints `metric name=value` lines (median, p95
/// and max over the samples) and `phase` lines (median ms per phase).
///
///   CEDRIC_SIDEBARCLICK_REPEATS=7     samples per kind and mode (default 7)
///   CEDRIC_SIDEBARCLICK_KINDS=a,b     only these kinds (default all)
@MainActor
extension DevChecks {
    static func sidebarClickCheck(_ name: String, _ app: AppDelegate) -> Bool {
        guard name == "sidebarclick" else { return false }
        SidebarClickBench.shared = SidebarClickBench(app)
        SidebarClickBench.shared?.start()
        return true
    }
}

@MainActor
final class SidebarClickBench {
    static var shared: SidebarClickBench?

    struct Kind {
        let name: String
        let ext: String
        let bytes: Int
        let make: (Int) -> Data
    }

    struct Sample {
        var shown = 0.0, stall = 0.0, after = 0.0, sync = 0.0
        var phases: [String: Double] = [:]
    }

    let app: AppDelegate
    let folder: URL
    let repeats: Int
    var kinds: [Kind] = []
    var files: [String: [URL]] = [:]
    var samples: [String: [Sample]] = [:]
    var order: [String] = []
    var notedFallback = false

    init(_ app: AppDelegate) {
        self.app = app
        // In CEDRIC_CHECK_OUT when given: the script's temp folder, removed even if this run dies.
        folder = DevChecks.out.appendingPathComponent("2026-09-03_idaho-falls", isDirectory: true)
        repeats = max(1, DevEnvironment.values["CEDRIC_SIDEBARCLICK_REPEATS"].flatMap(Int.init) ?? 7)
    }

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    // MARK: Fixture

    /// Deterministic bytes (a small LCG), so every run reads the same files.
    struct Rand {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    static func repeated(_ block: Data, to bytes: Int, header: (Int) -> String = { _ in "" }) -> Data {
        var d = Data(capacity: bytes + block.count)
        var k = 0
        while d.count < bytes {
            d.append(Data(header(k).utf8))
            d.append(block)
            k += 1
        }
        return d
    }

    static func logBlock(seed: UInt64) -> Data {
        var r = Rand(s: seed)
        var s = ""
        s.reserveCapacity(1 << 21)
        var i = 0
        while s.utf8.count < 1_000_000 {
            let ts = String(format: "2026-09-03T%02d:%02d:%02d.%06d-0600", 14 + i / 360_000 % 8, i / 6000 % 60, i / 100 % 60, r.int(1_000_000))
            let mac = (0..<6).map { _ in String(format: "%02X", r.int(256)) }.joined(separator: ":")
            switch i % 97 {
            case 0:
                // A long line: an information element dump.
                let hex = (0..<(600 + r.int(1400))).map { _ in String(format: "%02x", r.int(256)) }.joined()
                s += "\(ts) [wlan0mon] IE-DUMP bssid=\(mac) len=\(hex.count / 2) data=\(hex)\n"
            case 13:
                s += "$GPGGA,\(14 + i % 8)2207.00,4329.\(String(format: "%04d", r.int(10000))),N,11202.\(String(format: "%04d", r.int(10000))),W,1,09,0.9,1441.\(r.int(10)),M,-16.2,M,,*\(String(format: "%02X", r.int(256)))\n"
            case 41:
                s += "\(ts) WARN  gps: fix lost (hdop=\(r.int(30)).\(r.int(10)) sats=\(r.int(4)))\n"
            default:
                let kind = ["BEACON", "PROBE-REQ", "PROBE-RESP", "DATA", "ASSOC-REQ", "DEAUTH"][r.int(6)]
                s += "\(ts) [wlan0mon] \(kind) bssid=\(mac) ssid=\"IF-Net-\(r.int(9000) + 1000)\" ch=\([1, 6, 11, 36, 149][r.int(5)]) rssi=-\(40 + r.int(55)) enc=\(["WPA2-PSK", "WPA3-SAE", "OPEN", "WEP"][r.int(4)]) lat=43.\(String(format: "%05d", r.int(100_000))) lon=-112.\(String(format: "%05d", r.int(100_000))) seq=\(i)\n"
            }
            i += 1
        }
        return Data(s.utf8)
    }

    static func markdown(paragraphs: Int, seed: UInt64) -> Data {
        var r = Rand(s: seed)
        let words = ["access", "point", "channel", "beacon", "signal", "survey", "Idaho", "Falls", "router", "client", "probe",
                     "encryption", "handshake", "capture", "the", "a", "and", "of", "with", "near", "street", "north", "strength"]
        var s = "# Idaho Falls wardrive, 2026-09-03\n\n"
        for p in 0..<paragraphs {
            if p % 6 == 0 { s += "## Section \(p / 6 + 1)\n\n" }
            if p % 9 == 4 { s += "- [x] \(words[r.int(words.count)]) checked\n- [ ] [[tracker_0]] cross-check\n- see `wardrive_\(r.int(4)).log`\n\n" }
            if p % 11 == 7 { s += "```sh\ntshark -r ap_sta_0.pcap -Y 'wlan.fc.type_subtype == 8' | wc -l\n```\n\n" }
            let n = 30 + r.int(60)
            s += (0..<n).map { _ in words[r.int(words.count)] }.joined(separator: " ") + " **\(r.int(100))** dBm.\n\n"
        }
        return Data(s.utf8)
    }

    static func gpx(bytes: Int) -> Data {
        var r = Rand(s: 3)
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"wardrive\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n  <trk><name>Idaho Falls</name><trkseg>\n"
        var i = 0
        while s.utf8.count < bytes {
            s += "    <trkpt lat=\"43.\(String(format: "%05d", r.int(100_000)))\" lon=\"-112.\(String(format: "%05d", r.int(100_000)))\"><ele>14\(r.int(10)).\(r.int(10))</ele><time>2026-09-03T\(String(format: "%02d:%02d:%02d", 14 + i / 3600 % 8, i / 60 % 60, i % 60))Z</time><extensions><speed>\(r.int(20)).\(r.int(10))</speed></extensions></trkpt>\n"
            i += 1
        }
        s += "  </trkseg></trk>\n</gpx>\n"
        return Data(s.utf8)
    }

    static func pcap(bytes: Int, seed: UInt64) -> Data {
        var d = Data([0xD4, 0xC3, 0xB2, 0xA1, 0x02, 0x00, 0x04, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0x7F, 0, 0, 0])
        var r = Rand(s: seed)
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        while d.count < bytes {
            for k in stride(from: 0, to: chunk.count, by: 8) {
                var v = r.next() ^ (r.next() << 31)
                withUnsafeBytes(of: &v) { raw in for j in 0..<8 { chunk[k + j] = raw[j] } }
            }
            d.append(contentsOf: chunk.prefix(bytes - d.count))
        }
        return d
    }

    func makeFixture() {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let logBlock = Self.logBlock(seed: 11)
        func log(_ bytes: Int) -> (Int) -> Data {
            { k in Self.repeated(logBlock, to: bytes) { b in "2026-09-03T14:00:00.000000-0600 INFO  wardrive: block \(b) of copy \(k)\n" } }
        }
        let mb = 1_000_000
        kinds = [
            Kind(name: "md_small", ext: "md", bytes: 4000) { k in Self.markdown(paragraphs: 3 + k % 8 * 2, seed: UInt64(20 + k)) },
            Kind(name: "md_300k", ext: "md", bytes: 300_000) { k in Self.markdown(paragraphs: 760, seed: UInt64(40 + k)) },
            Kind(name: "gpx_2m", ext: "gpx", bytes: 2 * mb) { _ in Self.gpx(bytes: 2 * mb) },
            Kind(name: "log_2m", ext: "log", bytes: 2 * mb, make: log(2 * mb)),
            Kind(name: "log_8m", ext: "log", bytes: 8 * mb, make: log(8 * mb)),
            Kind(name: "log_30m", ext: "log", bytes: 30 * mb, make: log(30 * mb)),
            Kind(name: "log_120m", ext: "log", bytes: 120 * mb, make: log(120 * mb)),
            Kind(name: "pcap_5m", ext: "pcap", bytes: 5 * mb) { k in Self.pcap(bytes: 5 * mb, seed: UInt64(70 + k)) },
            Kind(name: "pcap_60m", ext: "pcap", bytes: 60 * mb) { k in Self.pcap(bytes: 60 * mb, seed: UInt64(90 + k)) },
        ]
        if let only = DevEnvironment.values["CEDRIC_SIDEBARCLICK_KINDS"] {
            let names = Set(only.split(separator: ",").map(String.init))
            kinds = kinds.filter { names.contains($0.name) }
        }
        // Derek's own names for the first of each; the rest are copies.
        let firstNames = ["md_small": "SUMMARY.md", "pcap_5m": "ap_sta_0.pcap", "gpx_2m": "tracker_0.gpx", "log_2m": "wardrive_0.log",
                          "log_8m": "wardrive_1.log", "log_30m": "wardrive_2.log", "log_120m": "wardrive_3.log"]
        for kind in kinds {
            // A first open of each sample, plus two more for `switch`; the
            // 120 MB log: three copies (0.4 GB).
            let copies = kind.bytes >= 100 * mb ? 3 : repeats + 1
            var urls: [URL] = []
            for k in 0..<copies {
                let name = k == 0 ? firstNames[kind.name] ?? "\(kind.name)_0.\(kind.ext)" : "\(kind.name)_\(k).\(kind.ext)"
                let u = folder.appendingPathComponent(name)
                try? kind.make(k).write(to: u)
                urls.append(u)
            }
            files[kind.name] = urls
        }
        print("sidebarclick: fixture \(folder.path): " + kinds.map { k in
            let size = (try? files[k.name]![0].resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return "\(k.name)=\(files[k.name]!.count)x\(size)"
        }.joined(separator: " "))
        fflush(stdout)
    }

    // MARK: Probe

    private var probe: Timer?
    private var lastTick = 0.0
    private var maxGap = 0.0
    /// What the probe waits for in the sample being taken.
    private enum Wait { case idle, shown(Double), settle(until: Double), done }
    private var wait = Wait.idle
    private var current = Sample()
    private var shownAt: Double?
    private var finishSample: ((Sample?) -> Void)?
    private var deadline = 0.0

    private func startProbe() {
        let t = Timer(timeInterval: 0.001, repeats: true) { _ in MainActor.assumeIsolated { SidebarClickBench.shared?.tick() } }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        probe = t
        lastTick = Self.now()
    }

    private func tick() {
        let t = Self.now()
        maxGap = max(maxGap, t - lastTick - 0.001)
        lastTick = t
        switch wait {
        case .idle, .done: return
        case .shown(let t0):
            if let s = shownAt {
                // This tick comes after the display pass that drew it.
                current.shown = (s - t0) * 1000
                current.stall = max(0, maxGap) * 1000
                maxGap = 0
                wait = .settle(until: t + 0.5)
            } else if t > deadline {
                wait = .done
                finishSample?(nil)
            }
        case .settle(let until):
            guard t >= until else { return }
            current.after = max(0, maxGap) * 1000
            current.phases = OpenSignpost.stopRecording()
            wait = .done
            finishSample?(current)
        }
    }

    // MARK: Clicks

    var sidebar: FolderSidebar? { FolderSidebar.shared }

    func row(_ url: URL) -> Int {
        guard let s = sidebar, let rel = FolderTree.relativePath(of: url.standardizedFileURL, in: s.rootURL),
              let n = s.root.descendant(rel) else { return -1 }
        return s.outline.row(forItem: n)
    }

    /// The same file (the temp folder is reached through /var and /private/var).
    static func same(_ a: URL?, _ b: URL) -> Bool {
        a?.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    func tab(_ url: URL) -> EditorWindowController? {
        app.tabs.first { Self.same($0.doc.fileURL, url) }
    }

    /// Before a sample: the row on screen and not selected (so a click
    /// that isn't taken shows), after a turn of the run loop.
    func prepare(_ url: URL, _ next: @escaping () -> Void) {
        guard let o = sidebar?.outline else { next(); return }
        redock()
        let r = row(url)
        o.deselectAll(nil)
        if r >= 0 { o.scrollRowToVisible(r) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { next() }
    }

    /// A real click (or two, `double`) on the row's name.
    func click(_ url: URL, double: Bool = false) {
        guard let s = sidebar else { return }
        let o = s.outline
        let r = row(url)
        guard r >= 0, let w = o.window else { print("sidebarclick: no row for \(url.lastPathComponent)"); return }
        let rect = o.frameOfCell(atColumn: 0, row: r)
        let p = o.convert(NSPoint(x: rect.minX + 30, y: rect.midY), to: nil)
        let t = ProcessInfo.processInfo.systemUptime
        for n in double ? [1, 2] : [1] {
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: t + Double(n) * 0.01,
                                                windowNumber: w.windowNumber, context: nil, eventNumber: 2 * n, clickCount: n, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: t + Double(n) * 0.01 + 0.005,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 2 * n + 1, clickCount: n, pressure: 0)
            else { return }
            NSApp.postEvent(up, atStart: false)
            if NSApp.isActive && w.isKeyWindow { w.sendEvent(down) } else { o.mouseDown(with: down) }
        }
        if o.selectedRow != r {
            // The way FolderCheck does it when an inactive window doesn't take a synthetic click.
            if !notedFallback { print("check: note: synthetic click not taken by the inactive outline; selecting the row and opening as the click would") }
            notedFallback = true
            SidebarOpenTrace.clicked(url)
            o.selectRowIndexes([r], byExtendingSelection: false)
            s.activateSelection()
            // A double click: the click, then doubleClicked's own open.
            if double {
                SidebarOpenTrace.clicked(url, double: true)
                s.activateSelection()
            }
        }
    }

    /// One sample: the click on `url`, until its text is shown and 0.5 s more.
    func sample(_ key: String, _ url: URL, double: Bool = false, _ next: @escaping () -> Void) {
        prepare(url) { [self] in
            if samples[key] == nil { order.append(key) }
            current = Sample()
            shownAt = nil
            SidebarOpenTrace.onShownForChecks = { [weak self] f in
                if Self.same(f, url) { self?.shownAt = Self.now() }
            }
            finishSample = { [weak self] s in
                guard let self else { return }
                self.finishSample = nil
                if let s { self.samples[key, default: []].append(s) } else {
                    print("sidebarclick: \(key) \(url.lastPathComponent): not shown within 60 s")
                    _ = OpenSignpost.stopRecording()
                    DevChecks.expect(false, "\(key): \(url.lastPathComponent) shown within 60 s")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { next() }
            }
            OpenSignpost.startRecording()
            let t0 = Self.now()
            deadline = t0 + 60
            lastTick = t0
            maxGap = 0
            click(url, double: double)
            current.sync = (Self.now() - t0) * 1000
            wait = .shown(t0)
        }
    }

    /// Opens `url` with a click, not timed (waits for its tab).
    func open(_ url: URL, _ next: @escaping () -> Void) {
        prepare(url) { [self] in
            click(url)
            waitFor({ [self] in tab(url) != nil }, next)
        }
    }

    /// An inactive app (a check run with another app in front, or the
    /// screen locked) makes no tab key when one closes, so the sidebar
    /// isn't docked again until then: docked in the front tab, as that
    /// tab becoming key does (AppDelegate.tabBecameKey). Not timed.
    func redock() {
        guard sidebar?.window == nil, let t = app.currentTab ?? app.tabs.last else { return }
        app.folderSidebarFollow(t)
        t.window?.makeKeyAndOrderFront(nil)
    }

    func close(_ url: URL, _ next: @escaping () -> Void) {
        tab(url)?.window?.performClose(nil)
        waitFor({ [self] in tab(url) == nil }, { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next() } })
    }

    func waitFor(_ cond: @escaping () -> Bool, timeout: Double = 60, _ next: @escaping () -> Void) {
        let end = Self.now() + timeout
        func poll() {
            if cond() || Self.now() > end { next(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
        }
        poll()
    }

    // MARK: Run

    func start() {
        let t0 = Self.now()
        makeFixture()
        print(String(format: "sidebarclick: fixture written in %.1f s", Self.now() - t0))
        // A tab with a file outside the folder, as when Owlink was already open.
        let other = app.open(DevChecks.write("notes-outside.txt", "already open\n"))
        DevChecks.sized(other)
        app.openFolder(folder)
        startProbe()
        waitFor({ [self] in sidebar?.isShown == true && (sidebar?.outline.numberOfRows ?? 0) >= kinds.count }) { [self] in
            DevChecks.expect(sidebar?.isShown == true, "the folder is shown in the sidebar", "\(sidebar?.outline.numberOfRows ?? -1) rows")
            sidebar?.window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.steps() }
        }
    }

    func steps() {
        var steps: [(@escaping () -> Void) -> Void] = []
        for kind in kinds {
            let urls = files[kind.name]!
            // cold: each copy once (the last two stay for `switch`).
            for u in urls.dropLast(urls.count > 2 ? 2 : 0) {
                steps.append { [self] n in sample("\(kind.name)_cold", u) { self.close(u, n) } }
            }
            // reopen: the first copy, closed and clicked again.
            for _ in 0..<repeats {
                steps.append { [self] n in sample("\(kind.name)_reopen", urls[0]) { self.close(urls[0], n) } }
            }
            // switch: two tabs open, a click on the one not in front.
            let a = urls[urls.count - 2], b = urls[urls.count - 1]
            steps.append { [self] n in open(a) { self.open(b, n) } }
            for k in 0..<repeats {
                let u = k % 2 == 0 ? a : b
                steps.append { [self] n in sample("\(kind.name)_switch", u, n) }
            }
            steps.append { [self] n in close(a) { self.close(b, n) } }
            if kind.name == "md_small" {
                for _ in 0..<repeats {
                    steps.append { [self] n in sample("md_small_dblclick", urls[0], double: true) { self.close(urls[0], n) } }
                }
            }
        }
        var i = 0
        func step() {
            guard i < steps.count else { report(); return }
            let s = steps[i]
            i += 1
            s(step)
        }
        step()
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Nearest rank.
    static func p95(_ v: [Double]) -> Double {
        let s = v.sorted()
        guard !s.isEmpty else { return 0 }
        return s[min(s.count - 1, Int((0.95 * Double(s.count)).rounded(.up)) - 1)]
    }

    func report() {
        probe?.invalidate()
        for key in order {
            let list = samples[key] ?? []
            DevChecks.expect(!list.isEmpty, "\(key): \(list.count) samples")
            let shown = list.map(\.shown), stall = list.map(\.stall), after = list.map(\.after), sync = list.map(\.sync)
            DevHooks.metric("\(key)_shown_median_ms", Self.median(shown))
            DevHooks.metric("\(key)_shown_p95_ms", Self.p95(shown))
            DevHooks.metric("\(key)_stall_median_ms", Self.median(stall))
            DevHooks.metric("\(key)_stall_max_ms", stall.max() ?? 0)
            DevHooks.metric("\(key)_after_max_ms", after.max() ?? 0)
            DevHooks.metric("\(key)_click_sync_median_ms", Self.median(sync))
            DevHooks.metric("\(key)_samples", Double(list.count))
            let names = Set(list.flatMap(\.phases.keys)).sorted()
            let phases = names.map { n in (n, Self.median(list.map { ($0.phases[n] ?? 0) * 1000 })) }
                .filter { $0.1 >= 0.05 }.sorted { $0.1 > $1.1 }
            print("phase \(key) " + phases.map { String(format: "%@=%.2f", $0.0.replacingOccurrences(of: " ", with: "_"), $0.1) }.joined(separator: " "))
        }
        fflush(stdout)
        try? FileManager.default.removeItem(at: folder)
        DevChecks.finish()
    }
}
