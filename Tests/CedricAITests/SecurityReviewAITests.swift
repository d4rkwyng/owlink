import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// The 0.2.1 security review's fixes (CedricAI side).
@Suite(.offPool) struct SecurityReviewAITests {
    // MARK: 6. DNS rebinding: connect to the checked address

    @Test func requestsGoToTheCheckedAddress() throws {
        let req = URLRequest(url: URL(string: "http://studio.local:1234/v1/chat/completions")!)
        let pin = LocalModelClient.Pin(host: "studio.local", addresses: ["fd00::5", "192.168.1.20"])
        let r = pin.apply(req)
        #expect(r.url?.absoluteString == "http://192.168.1.20:1234/v1/chat/completions", "IPv4 first")
        #expect(r.value(forHTTPHeaderField: "Host") == "studio.local:1234", "the name stays in the Host header")
        // IPv6 only: bracketed.
        let v6 = LocalModelClient.Pin(host: "box.ts.net", addresses: ["fd7a:115c:a1e0::1"]).apply(URLRequest(url: URL(string: "http://box.ts.net:11434/api/tags")!))
        #expect(v6.url?.absoluteString == "http://[fd7a:115c:a1e0::1]:11434/api/tags")
        #expect(v6.value(forHTTPHeaderField: "Host") == "box.ts.net:11434")
        // An address in the URL already: nothing to pin.
        let lit = URLRequest(url: URL(string: "http://127.0.0.1:1234/v1/models")!)
        #expect(LocalModelClient.Pin(host: "127.0.0.1", addresses: ["127.0.0.1"]).apply(lit) == lit)
        // https: the certificate is checked against the name; left alone.
        let tls = URLRequest(url: URL(string: "https://studio.local/v1/models")!)
        #expect(LocalModelClient.Pin(host: "studio.local", addresses: ["192.168.1.20"]).apply(tls) == tls)
        // Only an IPv6 link-local address (its interface was dropped): not pinned.
        #expect(LocalModelClient.Pin(host: "x.local", addresses: ["fe80::1"]).address == nil)
        // The redirect guard still allows the pinned server's own redirects.
        #expect(LocalEndpointPolicy.allowsRedirect(from: r.url!, to: URL(string: "http://192.168.1.20:1234/v1/models")!))
    }

    @Test func checkLocalPinsWhatItResolved() async throws {
        var client = LocalModelClient(baseURL: URL(string: "http://studio.local:1234/v1")!, timeout: 5)
        client.resolver = { _ in ["10.0.0.7"] }
        let pin = try await client.checkLocal()
        #expect(pin.address == "10.0.0.7")
        // A public answer is still refused.
        client.resolver = { _ in ["10.0.0.7", "8.8.8.8"] }
        await #expect(throws: LocalAIError.endpointNotLocal("studio.local")) { try await client.checkLocal() }
    }

    // No real-time deadline on the client (`withoutRealDeadline`): what is
    // checked is where the request goes, not how fast a busy runner gets it there.
    @Test(.timeLimit(.minutes(1))) func aRebindAfterTheCheckIsNotFollowed() async throws {
        // The name's first answer is private (a real server on 127.0.0.1);
        // every later answer is public. The request must go to the address
        // that was checked, with the name in the Host header, and the name
        // must be looked up once: a second lookup is where a rebind lands.
        let server = try OneShotHTTPServer(body: #"{"data":[{"id":"m"}]}"#)
        let lookups = Locked(0)
        var client = LocalModelClient(baseURL: URL(string: "http://rebind-test.local:\(server.port)/v1")!, timeout: 5).withoutRealDeadline()
        client.resolver = { _ in
            lookups.mutate { $0 += 1; return $0 } == 1 ? ["127.0.0.1"] : ["8.8.8.8"]
        }
        #expect(try await client.listModels().map(\.id) == ["m"])
        #expect(lookups.mutate { $0 } == 1, "looked up once, not again at connect time")
        let head = try #require(server.requestHead)
        #expect(head.hasPrefix("GET /v1/models "), "\(head)")
        #expect(head.lowercased().contains("host: rebind-test.local:\(server.port)\r\n"), "\(head)")
        // A second call looks up again and gets the public answer: refused
        // before any connection.
        await #expect(throws: LocalAIError.endpointNotLocal("rebind-test.local")) { try await client.listModels() }
    }

    // MARK: 0.2.1 review M3: IPv6 link-local zones, the peer check after https

    @Test func linkLocalZonesAreAddresses() throws {
        // The policy takes the decoded zone, as URL.host and getnameinfo give it.
        for a in ["fe80::1%en0", "FE80::1%lo0", "fe80::1ce8:63fb:78fa:d96f%en0", "fe80::1%17", "fd00::1%en0"] {
            #expect(LocalEndpointPolicy.isPrivateAddress(a), "\(a)")
        }
        for a in ["8.8.8.8%en0", "192.168.1.1%en0", "2606:4700::1111%en0", "fe80::1%", "fe80::1%en0/x", "fe80::1%en 0"] {
            #expect(!LocalEndpointPolicy.isPrivateAddress(a), "\(a)")
        }
        #expect(LocalEndpointPolicy.isLinkLocalV6("fe80::1%en0") && LocalEndpointPolicy.isLinkLocalV6("febf::1"))
        #expect(!LocalEndpointPolicy.isLinkLocalV6("fec0::1") && !LocalEndpointPolicy.isLinkLocalV6("169.254.1.1"))
        // A URL with a zone ("%25" in the URL, decoded by URL.host).
        #expect(LocalEndpointPolicy.isAllowed(URL(string: "http://[fe80::1%25en0]:1234/v1")!))
        #expect(LocalEndpointPolicy.isAllowed(URL(string: "http://[::ffff:192.168.1.5]:1234/v1")!), "IPv4-mapped LAN address")
        #expect(!LocalEndpointPolicy.isAllowed(URL(string: "http://[2606:4700::1111%25en0]/v1")!))
        #expect(!LocalEndpointPolicy.isAllowed(URL(string: "http://[fec0::1]/v1")!), "site-local is deprecated, not LAN")
        // Typed with a bare "%": written "%25" in the endpoint URL.
        let typed = try #require(LocalAISettings.parseEndpoint("[fe80::1%en0]:1234"))
        #expect(typed.absoluteString == "http://[fe80::1%25en0]:1234/v1")
        #expect(typed.host == "fe80::1%en0")
        #expect(LocalAISettings.parseEndpoint("http://[fe80::1%25en0]:1234")?.absoluteString == "http://[fe80::1%25en0]:1234/v1")
        #expect(LocalAISettings.parseEndpoint("[fe80::1%en0]:1234")!.appendingPathComponent("models").absoluteString
                == "http://[fe80::1%25en0]:1234/v1/models")
    }

    @Test func linkLocalAnswerIsPinnedWithItsZone() async throws {
        let req = URLRequest(url: URL(string: "http://studio.local:1234/v1/models")!)
        // mDNS gave only a link-local address, with its interface: pinned to it.
        let pin = LocalModelClient.Pin(host: "studio.local", addresses: ["fe80::1ce8:63fb:78fa:d96f%en0"])
        #expect(pin.address == "fe80::1ce8:63fb:78fa:d96f%en0")
        let r = pin.apply(req)
        #expect(r.url?.absoluteString == "http://[fe80::1ce8:63fb:78fa:d96f%25en0]:1234/v1/models")
        #expect(r.url?.host == "fe80::1ce8:63fb:78fa:d96f%en0")
        #expect(r.value(forHTTPHeaderField: "Host") == "studio.local:1234")
        // IPv4, then a routable IPv6 address, come before a link-local one.
        #expect(LocalModelClient.Pin(host: "s.local", addresses: ["fe80::1%en0", "192.168.1.20"]).address == "192.168.1.20")
        #expect(LocalModelClient.Pin(host: "s.local", addresses: ["fe80::1%en0", "fd00::5"]).address == "fd00::5")
        // Without a zone it can't be connected to: not pinned.
        #expect(LocalModelClient.Pin(host: "s.local", addresses: ["fe80::1"]).address == nil)
        // A link-local address in the URL is already an address.
        #expect(LocalModelClient.Pin(host: "fe80::1%en0", addresses: ["fe80::1%en0"]).address == nil)
        #expect(LocalModelClient.Pin(host: "[fe80::1%en0]", addresses: ["fe80::1%en0"]).address == nil)
        // checkLocal takes the zoned answer the lookup gives.
        var client = LocalModelClient(baseURL: URL(string: "http://studio.local:1234/v1")!, timeout: 5)
        client.resolver = { _ in ["fe80::1%en0"] }
        #expect(try await client.checkLocal().address == "fe80::1%en0")
        client.resolver = { _ in ["fe80::1%en0", "2606:4700::1111"] }
        await #expect(throws: LocalAIError.endpointNotLocal("studio.local")) { try await client.checkLocal() }
        // The real lookup keeps the zone of a link-local address.
        let looked = await LocalEndpointPolicy.resolve("fe80::1%lo0")
        #expect(!looked.isEmpty && looked.allSatisfy { $0 == "fe80::1%lo0" }, "\(looked)")
    }

    @Test func peerCheckRefusesAPublicConnection() async throws {
        let g = LocalModelClient.RedirectGuard()
        g.record(["192.168.1.20", "fe80::1%en0", "::1"])
        try await g.checkPeers(wait: 0)
        let pub = LocalModelClient.RedirectGuard()
        pub.record(["10.0.0.2", "8.8.8.8"])
        await #expect(throws: LocalAIError.endpointNotLocal("8.8.8.8")) { try await pub.checkPeers(wait: 0) }
        // No report (no connection, a stub protocol): passes after the
        // wait, measured on the clock and not longer. A clock whose sleeps
        // return at once: no dependence on how busy the machine is.
        let none = LocalModelClient.RedirectGuard()
        let clock = SteppingClock()
        try await none.checkPeers(wait: 0.05, clock: clock)
        #expect(abs(clock.now - 0.05) < 1e-9, "waited the whole 0.05 s, no more: \(clock.now)")
        #expect(clock.sleeps >= 5 && clock.sleeps <= 6, "\(clock.sleeps) polls")
        // A poll that oversleeps (a busy machine) uses the wait up; it doesn't add to it.
        let slowPolls = SteppingClock(oversleep: 100)
        try await LocalModelClient.RedirectGuard().checkPeers(wait: 0.05, clock: slowPolls)
        #expect(slowPolls.sleeps == 1, "one late poll ends the wait: \(slowPolls.sleeps)")
        // A report that arrives during the wait is checked.
        let late = LocalModelClient.RedirectGuard()
        let reporting = SteppingClock { if $0 == 3 { late.record(["8.8.8.8"]) } }
        await #expect(throws: LocalAIError.endpointNotLocal("8.8.8.8")) { try await late.checkPeers(wait: 1, clock: reporting) }
        #expect(reporting.sleeps == 3)
    }

    /// Time that moves only when slept on; each sleep returns at once
    /// (after `oversleep` × the asked time) and calls `onSleep` with the count.
    final class SteppingClock: OwlClock, @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval = 0
        private var n = 0
        let oversleep: Double
        let onSleep: @Sendable (Int) -> Void
        init(oversleep: Double = 1, onSleep: @escaping @Sendable (Int) -> Void = { _ in }) {
            self.oversleep = oversleep
            self.onSleep = onSleep
        }
        var now: TimeInterval { lock.withLock { t } }
        var sleeps: Int { lock.withLock { n } }
        func sleep(seconds: TimeInterval) async throws {
            let count: Int = lock.withLock { t += seconds * oversleep; n += 1; return n }
            onSleep(count)
        }
    }

    // Neither the client's deadline nor the guard's wait is on the wall
    // clock here (`withoutRealDeadline`, `FrozenClock`): URLSession's report
    // is awaited however late a busy runner delivers it.
    @Test(.timeLimit(.minutes(1))) func peerCheckSeesARealConnection() async throws {
        let server = try OneShotHTTPServer(body: #"{"data":[{"id":"m"}]}"#)
        let base = URL(string: "http://127.0.0.1:\(server.port)/v1")!
        let client = LocalModelClient(baseURL: base, timeout: 5).withoutRealDeadline()
        // Through the client: the peer (127.0.0.1) is private, the list comes back.
        #expect(try await client.listModels().map(\.id) == ["m"])
        // The guard got the connection's address from URLSession.
        let again = try OneShotHTTPServer(body: "{}")
        let g = LocalModelClient.RedirectGuard()
        let (bytes, _) = try await URLSession(configuration: .ephemeral)
            .bytes(for: URLRequest(url: URL(string: "http://127.0.0.1:\(again.port)/")!), delegate: g)
        for try await _ in bytes {}
        try await g.checkPeers(wait: 2, clock: FrozenClock())
        #expect(g.connectedAddresses?.contains("127.0.0.1") == true)
    }

    // MARK: 10. Installed models are re-hashed before a load

    @Test func modelIsRehashedAfterAnyChange() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = Data((0..<10_000).map { UInt8($0 % 251) })
        let model = testModel(body: body)
        let store = ModelStore(directory: dir)
        let file = store.fileURL(for: model)
        try body.write(to: file)
        #expect(store.verifiedForLoad(model), "the catalog's bytes load")
        #expect(FileManager.default.fileExists(atPath: store.stampURL(for: model).path), "and the check is remembered")
        #expect(store.verifiedForLoad(model))
        // Same size, other bytes, written in place: refused.
        var evil = body
        evil[5000] ^= 0xff
        let h = try FileHandle(forWritingTo: file)
        try h.seek(toOffset: 5000)
        try h.write(contentsOf: evil[5000..<5001])
        try h.close()
        #expect(!store.verifiedForLoad(model), "a changed file is hashed again and refused")
        // Swapped for another file (new inode), same size and bytes as the evil one: refused.
        try FileManager.default.removeItem(at: file)
        try evil.write(to: file)
        #expect(!store.verifiedForLoad(model))
        // A symbolic link to the right bytes: refused.
        let real = dir.appendingPathComponent("elsewhere.bin")
        try body.write(to: real)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)
        #expect(!store.verifiedForLoad(model))
        // Put back: loads again; delete() takes the remembered check too.
        try FileManager.default.removeItem(at: file)
        try body.write(to: file)
        #expect(store.verifiedForLoad(model))
        try store.delete(model)
        #expect(!FileManager.default.fileExists(atPath: store.stampURL(for: model).path))
    }

    /// The remembered check includes the ctime, which user space can't set:
    /// bytes rewritten in place with the old mtime put back (utimensat) are
    /// still hashed again, and so is a chmod round trip.
    @Test func modelRehashIsKeyedOnCtime() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = Data((0..<10_000).map { UInt8($0 % 251) })
        let model = testModel(body: body)
        let store = ModelStore(directory: dir)
        let file = store.fileURL(for: model)
        let stampFile = store.stampURL(for: model)
        try body.write(to: file)
        #expect(store.verifiedForLoad(model))
        let first = try String(contentsOf: stampFile, encoding: .utf8)
        func times() -> stat { var st = stat(); _ = lstat(file.path, &st); return st }

        // chmod round trip: same bytes, mode and mtime, new ctime: hashed
        // again (and accepted), so the stamp is rewritten.
        usleep(20_000)
        let pre = times()
        #expect(chmod(file.path, 0o400) == 0 && chmod(file.path, pre.st_mode & 0o7777) == 0)
        let post = times()
        #expect(post.st_mtimespec.tv_sec == pre.st_mtimespec.tv_sec && post.st_mtimespec.tv_nsec == pre.st_mtimespec.tv_nsec
                 && post.st_mode == pre.st_mode, "only the ctime moved")
        #expect(store.verifiedForLoad(model))
        let second = try String(contentsOf: stampFile, encoding: .utf8)
        #expect(second != first, "a new ctime forces a re-hash")

        // Same size, other bytes, the old mtime put back: refused.
        let before = times()
        usleep(20_000)
        var evil = body
        evil[5000] ^= 0xff
        let h = try FileHandle(forWritingTo: file)
        try h.seek(toOffset: 5000)
        try h.write(contentsOf: evil[5000..<5001])
        try h.close()
        var ts = [before.st_atimespec, before.st_mtimespec]
        #expect(utimensat(AT_FDCWD, file.path, &ts, 0) == 0)
        let after = times()
        #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
        #expect(!store.verifiedForLoad(model), "mtime set back doesn't hide a rewrite")

        // A stamp from before ctime was in it (no "c" field): hashed once, then rewritten.
        try body.write(to: file)
        #expect(store.verifiedForLoad(model))
        let st = times()
        let old = "\(st.st_dev) \(st.st_ino) \(st.st_size) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec) \(model.sha256)\n"
        try Data(old.utf8).write(to: stampFile)
        #expect(store.verifiedForLoad(model))
        let upgraded = try String(contentsOf: stampFile, encoding: .utf8)
        #expect(upgraded != old && upgraded.contains(" c"), "an old stamp is replaced after one re-hash")
    }
}

/// A real HTTP server on 127.0.0.1 for one connection (URLSession reports a
/// real peer address for it, unlike `StubServer`'s URL protocol). Answers
/// every request on that connection with `body`, then closes.
final class OneShotHTTPServer: @unchecked Sendable {
    let port: Int
    private let seen = Locked<String?>(nil)
    /// The request's head, once it has been read.
    var requestHead: String? { seen.mutate { $0 } }

    init(body: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(fd, sp, len) == 0 && listen(fd, 4) == 0 && getsockname(fd, sp, &len) == 0
            }
        }
        guard ok else { close(fd); throw POSIXError(.EADDRINUSE) }
        port = Int(UInt16(bigEndian: addr.sin_port))
        let listener = fd
        let seen = self.seen
        Thread.detachNewThread {
            defer { close(listener) }
            let c = accept(listener, nil, nil)
            guard c >= 0 else { return }
            defer { close(c) }
            // No read timeout, as accept has none: a busy runner may send the
            // request late, and the test's time limit bounds the wait.
            var got = [UInt8]()
            var buf = [UInt8](repeating: 0, count: 4096)
            while !String(decoding: got, as: UTF8.self).contains("\r\n\r\n") {
                let n = read(c, &buf, buf.count)
                if n <= 0 { return }
                got += buf[0..<n]
            }
            seen.mutate { $0 = String(decoding: got, as: UTF8.self) }
            let payload = Array(body.utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            let out = Array(head.utf8) + payload
            _ = out.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
        }
    }
}
