import Foundation
import Testing
import CryptoKit
@testable import CedricAI
import CedricCore

// MARK: - Helpers

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-builtin-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func testModel(id: String = "m-\(UUID().uuidString.prefix(8))", body: Data, sha: String? = nil, size: Int64? = nil,
               family: String = "qwen2.5-coder", isDefault: Bool = true) -> BuiltInModel {
    let rev = String(repeating: "a", count: 40)
    let file = "\(id).gguf"
    return BuiltInModel(id: id, name: id, family: family, parametersB: 1.5, quantization: "Q4_K_M",
                        fileName: file, sizeBytes: size ?? Int64(body.count),
                        url: URL(string: "https://huggingface.co/x/y/resolve/\(rev)/\(file)")!,
                        revision: rev, sha256: sha ?? sha256Hex(body), license: "Apache-2.0",
                        licenseURL: URL(string: "https://huggingface.co/x/y")!, isDefault: isDefault)
}

/// Serves registered blobs over a fake HTTP stack with `Range` support,
/// in chunks with a delay so a test can pause mid-transfer.
final class BlobProtocol: URLProtocol, @unchecked Sendable {
    struct Blob: Sendable {
        var data: Data
        var chunk = 4096
        var delay: TimeInterval = 0.002
        var ignoreRange = false
        var status = 200
        /// Drop the connection after this many bytes of this response.
        var dropAfter: Int?
        /// Before dropping, wait (up to 5 s) until this says the client has
        /// taken the bytes sent so far. URLSession buffers what a protocol
        /// hands it and delivers it to the task delegate later; an error
        /// that arrives first discards the buffer, so the delegate never
        /// sees those bytes (a busy machine made that the case in ~1 run in
        /// 4). A real dropped connection comes after bytes the app has
        /// already received, which is what the test is about.
        var dropWhen: (@Sendable () -> Bool)?
        /// Stop sending after this many bytes until the test sets it to nil
        /// (`update`) or the task stops (pause, cancel); at most 60 s. A
        /// test that pauses or cancels mid-download needs the download not
        /// to finish first: unheld, the whole body arrives in well under a
        /// second, and a runner that stalls the test that long finds the
        /// partial already installed and gone (macos-26 CI).
        var holdAfter: Int?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var blobs: [String: Blob] = [:]
    nonisolated(unsafe) private static var log: [String: [String?]] = [:]   // path → Range headers seen

    static func serve(_ path: String, _ blob: Blob) { lock.withLock { blobs[path] = blob } }
    static func update(_ path: String, _ f: (inout Blob) -> Void) { lock.withLock { if var b = blobs[path] { f(&b); blobs[path] = b } } }
    static func ranges(_ path: String) -> [String?] { lock.withLock { log[path] ?? [] } }

    static var configuration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [BlobProtocol.self]
        return c
    }

    private let stopped = Box(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let range = request.value(forHTTPHeaderField: "Range")
        let blob: Blob? = Self.lock.withLock {
            Self.log[url.path, default: []].append(range)
            return Self.blobs[url.path]
        }
        let client = self.client
        let stopped = self.stopped
        let me = UncheckedRef(self)
        guard let blob else {
            let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var start = 0
        var status = blob.status
        var headers = ["Content-Type": "application/octet-stream", "Accept-Ranges": "bytes"]
        if status == 200, let range, !blob.ignoreRange, range.hasPrefix("bytes="),
           let n = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
            start = n
            status = 206
            headers["Content-Range"] = "bytes \(n)-\(blob.data.count - 1)/\(blob.data.count)"
        }
        let body = status < 300 ? blob.data.subdata(in: start..<blob.data.count) : Data()
        headers["Content-Length"] = "\(body.count)"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        Thread.detachNewThread {
            var sent = 0
            while sent < body.count {
                if stopped.value { return }
                if let hold = blob.holdAfter, sent >= hold {
                    let deadline = Date().addingTimeInterval(60)
                    while !stopped.value, Date() < deadline,
                          Self.lock.withLock({ Self.blobs[url.path]?.holdAfter }) != nil { Thread.sleep(forTimeInterval: 0.001) }
                    if stopped.value { return }
                }
                if let drop = blob.dropAfter, sent >= drop {
                    if let ready = blob.dropWhen {
                        let deadline = Date().addingTimeInterval(5)
                        while !ready(), !stopped.value, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
                    }
                    client?.urlProtocol(me.value, didFailWithError: URLError(.networkConnectionLost))
                    return
                }
                let n = min(blob.chunk, body.count - sent)
                client?.urlProtocol(me.value, didLoad: body.subdata(in: sent..<sent + n))
                sent += n
                if blob.delay > 0 { Thread.sleep(forTimeInterval: blob.delay) }
            }
            if !stopped.value { client?.urlProtocolDidFinishLoading(me.value) }
        }
    }

    override func stopLoading() { stopped.mutate { $0 = true } }
}

func randomBlob(_ n: Int) -> Data {
    var g = SystemRandomNumberGenerator()
    return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
}

// MARK: - Catalog

@Suite struct ModelCatalogTests {
    @Test func bundledCatalogIsValidAndPinned() throws {
        let url = try #require(ModelCatalog.bundledURL())
        let catalog = try ModelCatalog.decode(try Data(contentsOf: url))
        #expect(catalog.models.count == 5)
        let d = try #require(catalog.defaultModel)
        #expect(d.id == "qwen3-4b-instruct-2507-q4_k_m")
        #expect(d.sizeBytes <= 2_500_000_000)
        #expect(catalog.models.filter(\.isDefault).count == 1)
        for m in catalog.models {
            #expect(m.url.host == "huggingface.co" && m.url.scheme == "https")
            #expect(m.url.path.contains("/resolve/\(m.revision)/"))
            #expect(m.sha256.count == 64)
            #expect(m.quantization == "Q4_K_M")
            #expect(!m.license.isEmpty)
            // Pinned to a commit: the GGUF repo's own, or (when the quantiser's
            // repo has no LICENSE file) the original model repo's.
            #expect(m.licenseURL.absoluteString.contains(m.revision)
                    || m.licenseURL.path.range(of: "/blob/[0-9a-f]{40}/LICENSE$", options: .regularExpression) != nil)
        }
        let ids = catalog.models.map(\.id)
        #expect(ids.contains("qwen2.5-coder-1.5b-instruct-q4_k_m"))
        #expect(catalog.model(id: "qwen2.5-coder-7b-instruct-q4_k_m")?.minRAMGB == 16)
        #expect(catalog.model(id: "qwen3-4b-q4_k_m")?.promptModelName.contains("qwen3") == true)
        #expect(catalog.model(id: "qwen2.5-coder-7b-instruct-q4_k_m")?.needsMoreMemory(physicalMemory: 8 << 30) == true)
        #expect(catalog.model(id: "qwen2.5-coder-7b-instruct-q4_k_m")?.needsMoreMemory(physicalMemory: 16 << 30) == false)
        #expect(d.shortDescription == "4B · Q4_K_M · 2.5 GB")
    }

    /// The default is the Apache-2.0 Qwen3-4B-Instruct-2507, pinned to one
    /// file; the old default (Qwen Research License) stays an optional,
    /// labelled download so people who have it keep it.
    @Test func defaultIsApacheQwen3Instruct() throws {
        let catalog = try #require(ModelCatalog.bundled())
        let d = try #require(catalog.defaultModel)
        #expect(catalog.models.first == d)
        #expect(d.license == "Apache-2.0")
        #expect(d.licenseURL.absoluteString.hasPrefix("https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507/blob/"))
        #expect(d.fileName == "Qwen3-4B-Instruct-2507-Q4_K_M.gguf")
        #expect(d.sizeBytes == 2_497_281_120)
        #expect(d.sha256 == "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597")
        #expect(d.revision == "a06e946bb6b655725eafa393f4a9745d460374c9")
        #expect(d.minRAMGB == 8)
        #expect(!d.needsMoreMemory(physicalMemory: 8 << 30))
        let old = try #require(catalog.model(id: "qwen2.5-coder-3b-instruct-q4_k_m"))
        #expect(!old.isDefault)
        #expect(old.license.contains("non-commercial"))
        #expect(old.summary.hasPrefix("Non-commercial licence"))
        for m in catalog.models where m.license.lowercased().contains("non-commercial") { #expect(!m.isDefault) }
    }

    @Test func everyCatalogLicenseIsBundledAndClassifiedWithoutNetwork() throws {
        let catalog = try #require(ModelCatalog.bundled())
        for model in catalog.models {
            let url = try #require(ModelCatalog.bundledLicenseURL(for: model.license))
            #expect(url.isFileURL)
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(model.bundledLicenseText() == text)
            let confirmation = try #require(model.licenseConfirmation())
            #expect(confirmation.title == model.name)
            #expect(confirmation.licenseName == model.license)
            if model.isNonCommercial {
                #expect(confirmation.isNonCommercial)
                #expect(confirmation.body.localizedCaseInsensitiveContains("NON-COMMERCIAL"))
                #expect(text.localizedCaseInsensitiveContains("NON-COMMERCIAL"))
            } else {
                #expect(!confirmation.isNonCommercial)
                #expect(text.localizedCaseInsensitiveContains("Apache License"))
            }
        }
    }

    @Test func everyCatalogModelHasLicenseConfirmation() throws {
        let catalog = try #require(ModelCatalog.bundled(bundle: .main))
        for model in catalog.models {
            let confirmation = try #require(model.licenseConfirmation(bundle: .main))
            if model.license.localizedCaseInsensitiveContains("non-commercial") {
                #expect(confirmation.isNonCommercial)
                #expect(confirmation.body.hasPrefix("NON-COMMERCIAL LICENSE\n\n"))
            }
        }
    }

    @Test func validationRejectsUnsafeEntries() throws {
        let good = testModel(body: Data("x".utf8))
        #expect(throws: Never.self) { try ModelCatalog(models: [good]).validate() }
        var m = good; m.url = URL(string: "https://example.com/x/y/resolve/\(m.revision)/\(m.fileName)")!
        #expect(throws: ModelCatalogError.self) { try ModelCatalog(models: [m]).validate() }
        m = good; m.url = URL(string: "http://huggingface.co/x/y/resolve/\(m.revision)/\(m.fileName)")!
        #expect(throws: ModelCatalogError.self) { try ModelCatalog(models: [m]).validate() }
        m = good; m.url = URL(string: "https://huggingface.co/x/y/resolve/main/\(m.fileName)")!
        #expect(throws: ModelCatalogError.self) { try ModelCatalog(models: [m]).validate() }
        m = good; m.sha256 = "ABC"
        #expect(throws: ModelCatalogError.self) { try ModelCatalog(models: [m]).validate() }
        m = good; m.isDefault = false
        #expect(throws: ModelCatalogError.self) { try ModelCatalog(models: [m]).validate() }
        #expect(throws: ModelCatalogError.self) { try ModelCatalog(models: [good, good]).validate() }
        #expect(throws: ModelCatalogError.self) { try ModelCatalog.decode(Data("{".utf8)) }
    }
}

// MARK: - Downloader

// `.timely`: these wait on a download's progress, and on CI they ran out
// of `eventually`'s window when the CPU-heavy tests went first (runs
// 44451577951, 44453003629).
@Suite(.timely) struct ModelDownloaderTests {
    func downloader(_ dir: URL, free: Int64? = nil, events: Box<[ModelDownloadState]>? = nil) -> ModelDownloader {
        ModelDownloader(store: ModelStore(directory: dir), configuration: BlobProtocol.configuration,
                        freeSpace: { _ in free }, observer: { _, s in events?.mutate { $0.append(s) } })
    }

    @Test func downloadsVerifiesAndInstallsWithProgress() async throws {
        let body = randomBlob(300_000)
        let model = testModel(body: body)
        BlobProtocol.serve(model.url.path, .init(data: body))
        let dir = tempDir()
        let events = Box<[ModelDownloadState]>([])
        let dl = downloader(dir, events: events)
        try await dl.start(model)
        #expect(await dl.waitUntilSettled(model) == .installed)
        let store = ModelStore(directory: dir)
        #expect(store.isInstalled(model))
        #expect(try Data(contentsOf: store.fileURL(for: model)) == body)
        #expect(!FileManager.default.fileExists(atPath: store.partialURL(for: model).path))
        let received = events.value.compactMap { s -> Int64? in if case .downloading(let r, _) = s { return r } else { return nil } }
        #expect(received.count >= 2)
        #expect(received == received.sorted())
        #expect(received.last == Int64(body.count))
        #expect(events.value.contains(.verifying))
        #expect(events.value.last == .installed)
        #expect(BlobProtocol.ranges(model.url.path) == [nil])
        #expect(await dl.state(of: model) == .installed)
        // Delete.
        try await dl.delete(model)
        #expect(!store.isInstalled(model))
        #expect(await dl.state(of: model) == .notDownloaded)
    }

    @Test func checksumMismatchDeletesAndFails() async throws {
        let body = randomBlob(50_000)
        let model = testModel(body: body, sha: String(repeating: "0", count: 64))
        BlobProtocol.serve(model.url.path, .init(data: body, delay: 0))
        let dir = tempDir()
        let dl = downloader(dir)
        try await dl.start(model)
        #expect(await dl.waitUntilSettled(model) == .failed(.checksumMismatch))
        let store = ModelStore(directory: dir)
        #expect(!store.isInstalled(model))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: model).path))
        #expect(!FileManager.default.fileExists(atPath: store.partialURL(for: model).path))
    }

    @Test func pauseKeepsThePartialAndResumeUsesRange() async throws {
        let body = randomBlob(400_000)
        let model = testModel(body: body)
        // Held at 40,960 bytes (ten chunks) until resumed below, so the
        // pause always lands mid-download however long the runner stalls.
        BlobProtocol.serve(model.url.path, .init(data: body, chunk: 4096, delay: 0, holdAfter: 40_960))
        let dir = tempDir()
        let store = ModelStore(directory: dir)
        let dl = downloader(dir)
        try await dl.start(model)
        // Can't overrun now, so a generous window: it returns once the held bytes are written.
        #expect(await eventually(seconds: 30) { store.partialBytes(model) >= 40_960 })
        await dl.pause(model)
        let paused = await dl.waitUntilSettled(model)
        guard case .paused(let got, let total) = paused else { Issue.record("not paused: \(paused)"); return }
        #expect(got > 0 && got < Int64(body.count) && total == Int64(body.count))
        #expect(store.partialBytes(model) == got)
        // A fresh downloader (as after a relaunch) sees the partial.
        let again = downloader(dir)
        #expect(await again.state(of: model) == .paused(received: got, total: Int64(body.count)))
        BlobProtocol.update(model.url.path) { $0.holdAfter = nil }
        try await again.start(model)
        #expect(await again.waitUntilSettled(model) == .installed)
        #expect(BlobProtocol.ranges(model.url.path) == [nil, "bytes=\(got)-"])
        #expect(try Data(contentsOf: store.fileURL(for: model)) == body)
    }

    @Test func resumeRestartsCleanlyWhenTheServerIgnoresRange() async throws {
        let body = randomBlob(120_000)
        let model = testModel(body: body)
        let dir = tempDir()
        let store = ModelStore(directory: dir)
        try FileManager.default.createDirectory(at: store.partialURL(for: model).deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.prefix(30_000).write(to: store.partialURL(for: model))
        BlobProtocol.serve(model.url.path, .init(data: body, delay: 0, ignoreRange: true))
        let dl = downloader(dir)
        try await dl.start(model)
        #expect(await dl.waitUntilSettled(model) == .installed)
        #expect(BlobProtocol.ranges(model.url.path) == ["bytes=30000-"])
        #expect(try Data(contentsOf: store.fileURL(for: model)) == body)
    }

    @Test func droppedConnectionKeepsPartialForResume() async throws {
        let body = randomBlob(100_000)
        let model = testModel(body: body)
        let dir = tempDir()
        let store = ModelStore(directory: dir)
        // The connection drops once the downloader has written some of what arrived.
        BlobProtocol.serve(model.url.path, .init(data: body, delay: 0, dropAfter: 40_960,
                                                 dropWhen: { store.partialBytes(model) > 0 }))
        let dl = downloader(dir)
        try await dl.start(model)
        let s = await dl.waitUntilSettled(model)
        guard case .failed(.transport) = s else { Issue.record("expected transport failure, got \(s)"); return }
        let kept = store.partialBytes(model)
        #expect(kept > 0 && kept <= 40_960)
        BlobProtocol.update(model.url.path) { $0.dropAfter = nil }
        try await dl.start(model)
        #expect(await dl.waitUntilSettled(model) == .installed)
        #expect(BlobProtocol.ranges(model.url.path).last == "bytes=\(kept)-")
        #expect(try Data(contentsOf: ModelStore(directory: dir).fileURL(for: model)) == body)
    }

    @Test func cancelDeletesThePartial() async throws {
        let body = randomBlob(400_000)
        let model = testModel(body: body)
        // Held at 20,480 bytes (five chunks): the cancel always lands mid-download.
        BlobProtocol.serve(model.url.path, .init(data: body, chunk: 4096, delay: 0, holdAfter: 20_480))
        let dir = tempDir()
        let store = ModelStore(directory: dir)
        let dl = downloader(dir)
        try await dl.start(model)
        #expect(await eventually(seconds: 30) { store.partialBytes(model) >= 20_480 })
        await dl.cancel(model)
        #expect(await dl.waitUntilSettled(model) == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: store.partialURL(for: model).path))
        #expect(!store.isInstalled(model))
    }

    @Test func diskFullPrecheckRefusesBeforeAnyRequest() async throws {
        let body = randomBlob(1000)
        let model = testModel(body: body, size: 2_000_000_000)
        let dir = tempDir()
        let dl = downloader(dir, free: 1_000_000_000)
        await #expect(throws: ModelDownloadError.notEnoughSpace(needed: 2_000_000_000 + ModelDownloader.headroom,
                                                                available: 1_000_000_000)) {
            try await dl.start(model)
        }
        #expect(BlobProtocol.ranges(model.url.path).isEmpty)
        if case .failed(.notEnoughSpace) = await dl.state(of: model) {} else { Issue.record("state not failed") }
    }

    @Test func refusesNonHuggingFaceURLs() async throws {
        var model = testModel(body: Data("x".utf8))
        model.url = URL(string: "https://example.com/m.gguf")!
        let dl = downloader(tempDir())
        await #expect(throws: ModelDownloadError.disallowedHost) { try await dl.start(model) }
    }

    @Test func oversizedResponseIsRejectedAndDeleted() async throws {
        let body = randomBlob(60_000)
        let model = testModel(body: body, size: 50_000)
        BlobProtocol.serve(model.url.path, .init(data: body, delay: 0))
        let dir = tempDir()
        let dl = downloader(dir)
        try await dl.start(model)
        let s = await dl.waitUntilSettled(model)
        guard case .failed(.sizeMismatch) = s else { Issue.record("expected sizeMismatch, got \(s)"); return }
        #expect(!FileManager.default.fileExists(atPath: ModelStore(directory: dir).partialURL(for: model).path))
    }

    /// The real default entry (its pinned URL and SHA-256), served a body
    /// of the right size but the wrong bytes: the hash check catches it,
    /// nothing is installed and the partial is gone.
    @Test func realDefaultShaIsVerified() async throws {
        let catalog = try #require(ModelCatalog.bundled())
        var model = try #require(catalog.defaultModel)
        #expect(model.sha256 == "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597")
        let body = randomBlob(64_000)
        model.sizeBytes = Int64(body.count)   // the real 2.5 GB is not served in a test
        BlobProtocol.serve(model.url.path, .init(data: body, delay: 0))
        let dir = tempDir()
        let dl = downloader(dir)
        try await dl.start(model)
        #expect(await dl.waitUntilSettled(model) == .failed(.checksumMismatch))
        let store = ModelStore(directory: dir)
        #expect(!store.isInstalled(model))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: model).path))
        #expect(!FileManager.default.fileExists(atPath: store.partialURL(for: model).path))
        #expect(BlobProtocol.ranges(model.url.path) == [nil])
    }

    @Test func httpErrorFails() async throws {
        let model = testModel(body: Data("x".utf8))
        BlobProtocol.serve(model.url.path, .init(data: Data(), status: 404))
        let dl = downloader(tempDir())
        try await dl.start(model)
        #expect(await dl.waitUntilSettled(model) == .failed(.http(404)))
    }
}

// MARK: - Engine, host and provider with a fake runtime

final class FakeRuntime: BuiltInRuntime, @unchecked Sendable {
    final class Model: LoadedModel, @unchecked Sendable {
        let path: URL
        let runtime: FakeRuntime
        init(path: URL, runtime: FakeRuntime) { self.path = path; self.runtime = runtime }
        func generate(_ request: GenerationRequest) async throws -> GenerationResult {
            runtime.requests.mutate { $0.append(request) }
            if runtime.hang.value {
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
                throw BuiltInError.cancelled
            }
            return GenerationResult(text: runtime.reply.value, promptTokens: 100, completionTokens: 40,
                                    promptSeconds: 0.1, generateSeconds: 0.4)
        }
        func unload() { runtime.unloaded.mutate { $0.append(path.lastPathComponent) } }
    }
    let loads = Box<[String]>([])
    let unloaded = Box<[String]>([])
    let requests = Box<[GenerationRequest]>([])
    let reply = Box(#"{"hints":[]}"#)
    let hang = Box(false)
    func load(modelAt url: URL) async throws -> any LoadedModel {
        loads.mutate { $0.append(url.lastPathComponent) }
        return Model(path: url, runtime: self)
    }
}

@Suite struct BuiltInEngineTests {
    let a = URL(fileURLWithPath: "/tmp/a.gguf"), b = URL(fileURLWithPath: "/tmp/b.gguf")

    @Test func loadsOnDemandReusesAndSwaps() async throws {
        let rt = FakeRuntime()
        let host = BuiltInModelHost(runtime: rt, clock: FakeClock())
        #expect(await host.loadedPath == nil)
        #expect(rt.loads.value.isEmpty)
        _ = try await host.generate(modelAt: a, GenerationRequest(system: "s", user: "u"))
        _ = try await host.generate(modelAt: a, GenerationRequest(system: "s", user: "u"))
        #expect(rt.loads.value == ["a.gguf"])
        _ = try await host.generate(modelAt: b, GenerationRequest(system: "s", user: "u"))
        #expect(rt.loads.value == ["a.gguf", "b.gguf"])
        #expect(rt.unloaded.value == ["a.gguf"])
        #expect(await host.loadedPath == b)
    }

    @Test func unloadsAfterIdleTimeout() async throws {
        let rt = FakeRuntime()
        let clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock, idleTimeout: 300)
        _ = try await host.generate(modelAt: a, GenerationRequest(system: "s", user: "u"))
        #expect(await eventually { clock.pendingSleepers == 1 })
        clock.advance(299)
        #expect(await host.loadedPath == a)
        #expect(await host.idleCheck() == false)   // re-arms for the remaining second
        #expect(await eventually { clock.pendingSleepers == 1 })
        clock.advance(2)
        #expect(await eventually { await host.loadedPath == nil })
        #expect(rt.unloaded.value == ["a.gguf"])
        // Loads again on the next request.
        _ = try await host.generate(modelAt: a, GenerationRequest(system: "s", user: "u"))
        #expect(rt.loads.value == ["a.gguf", "a.gguf"])
    }

    @Test func neverUnloadsDuringAGeneration() async throws {
        let rt = FakeRuntime()
        rt.hang.mutate { $0 = true }
        let clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock, idleTimeout: 1)
        let task = Task { try await host.generate(modelAt: a, GenerationRequest(system: "s", user: "u")) }
        #expect(await eventually { rt.requests.value.count == 1 })
        clock.advance(10)
        #expect(await host.idleCheck() == false)
        #expect(await host.loadedPath == a)
        task.cancel()
        _ = try? await task.value
        #expect(rt.unloaded.value.isEmpty)
    }

    func installedEngine(_ rt: FakeRuntime, family: String = "qwen2.5-coder") throws -> (BuiltInEngine, BuiltInModel) {
        let dir = tempDir()
        let store = ModelStore(directory: dir)
        let model = testModel(body: Data(), sha: String(repeating: "b", count: 64), size: 4096, family: family)
        try store.prepare()
        // A file of the right size plus its marker: "installed".
        FileManager.default.createFile(atPath: store.fileURL(for: model).path, contents: Data(count: 4096))
        try model.sha256.write(to: store.markerURL(for: model), atomically: true, encoding: .utf8)
        let engine = BuiltInEngine(catalog: ModelCatalog(models: [model]), store: store,
                                   host: BuiltInModelHost(runtime: rt, clock: FakeClock()))
        return (engine, model)
    }

    @Test func engineWithoutModelsHasNoProvider() async throws {
        let rt = FakeRuntime()
        let catalog = ModelCatalog(models: [testModel(body: Data("x".utf8))])
        let engine = BuiltInEngine(catalog: catalog, store: ModelStore(directory: tempDir()),
                                   host: BuiltInModelHost(runtime: rt))
        #expect(engine.isAvailable && !engine.needsAddress && engine.kind == .builtIn)
        #expect(try await engine.models().isEmpty)
        #expect(await engine.makeProvider(model: nil) == nil)
        let r = await engine.test()
        #expect(r.error != nil && r.suggested == nil)
        #expect(rt.loads.value.isEmpty)
        #expect(!BuiltInEngine(catalog: nil).isAvailable)
    }

    @Test func providerUsesOwlPromptsGrammarAndParser() async throws {
        let rt = FakeRuntime()
        let (engine, model) = try installedEngine(rt)
        #expect(try await engine.models().map(\.id) == [model.id])
        let provider = try #require(await engine.makeProvider(model: nil))
        #expect(provider.name == "local:\(model.id)")
        rt.reply.mutate { $0 = #"{"hints":[{"kind":"fix","title":"Off by one","detail":"0...n runs past the end.","find":"0...items.count","replacement":"0..<items.count","confidence":0.9}]}"# }
        let code = "for i in 0...items.count { sum += items[i] }"
        let hints = await provider.hints(for: context(code))
        #expect(hints.count == 1)
        #expect(hints.first?.replacement == "0..<items.count")
        #expect(hints.first?.source == "local:\(model.id)")
        let req = try #require(rt.requests.value.first)
        #expect(req.system == OwlPrompts.system(for: .codeHints))
        #expect(req.user.contains(code))
        #expect(!req.user.contains("/no_think"))
        #expect(req.grammar == HintGrammar.gbnf)
        // test(): loads and answers.
        #expect(await engine.test().error == nil)
    }

    /// Someone who downloaded the old default (Qwen2.5-Coder-3B) and left
    /// the model on Automatic keeps using it after the default changes;
    /// once the new default is downloaded too, Automatic picks it.
    @Test func oldDefaultKeepsWorkingAfterTheSwitch() async throws {
        let catalog = try #require(ModelCatalog.bundled())
        let old = try #require(catalog.model(id: "qwen2.5-coder-3b-instruct-q4_k_m"))
        let new = try #require(catalog.defaultModel)
        let store = ModelStore(directory: tempDir())
        try store.prepare()
        func install(_ m: BuiltInModel) throws {
            // A sparse file of the catalog size plus the marker: "installed".
            let url = store.fileURL(for: m)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: UInt64(m.sizeBytes))
            try h.close()
            try m.sha256.write(to: store.markerURL(for: m), atomically: true, encoding: .utf8)
        }
        try install(old)
        let rt = FakeRuntime()
        let engine = BuiltInEngine(catalog: catalog, store: store, host: BuiltInModelHost(runtime: rt, clock: FakeClock()))
        #expect(try await engine.models().map(\.id) == [old.id])
        #expect(engine.suggestedModel(in: try await engine.models())?.id == old.id)
        #expect(await engine.makeProvider(model: nil)?.name == "local:\(old.id)")
        #expect(await engine.makeProvider(model: old.id)?.name == "local:\(old.id)")
        try install(new)
        #expect(await engine.makeProvider(model: nil)?.name == "local:\(new.id)")
        #expect(await engine.makeProvider(model: old.id)?.name == "local:\(old.id)")
    }

    @Test func qwen3GetsNoThink() async throws {
        let rt = FakeRuntime()
        let (engine, _) = try installedEngine(rt, family: "qwen3")
        let provider = try #require(await engine.makeProvider(model: nil))
        _ = await provider.hints(for: context())
        #expect(rt.requests.value.first?.user.hasSuffix("/no_think") == true)
    }

    @Test func schedulerTimeoutCancelsTheGeneration() async throws {
        let rt = FakeRuntime()
        rt.hang.mutate { $0 = true }
        let (engine, _) = try installedEngine(rt)
        let provider = try #require(await engine.makeProvider(model: nil))
        let clock = FakeClock()
        let result = Task { await OwlScheduler.race(provider: provider, context: context(), clock: clock, timeout: 20) }
        #expect(await eventually { rt.requests.value.count == 1 && clock.pendingSleepers == 1 })
        clock.advance(21)
        #expect(await result.value == nil)
    }

    @Test func unknownOrMissingModelGivesNoProvider() async throws {
        let rt = FakeRuntime()
        let (engine, _) = try installedEngine(rt)
        #expect(await engine.makeProvider(model: "not-in-catalog") == nil)
    }
}

@Suite struct DefaultEngineTests {
    @Test func appleThenBuiltInThenAServer() {
        #expect(AIEngines.defaultBackend(appleAvailable: true, builtInAvailable: true) == .apple)
        #expect(AIEngines.defaultBackend(appleAvailable: false, builtInAvailable: true) == .builtIn)
        #expect(AIEngines.defaultBackend(appleAvailable: false, builtInAvailable: false) == .lmStudio)
        let (d, suite) = TestDefaults.make("cedric-default-")
        defer { TestDefaults.remove(suite) }
        let fresh = LocalAISettings.load(from: d, defaultBackend: .apple)
        #expect(fresh.backend == .apple && fresh.enabled == false)
        #expect(LocalAISettings.Backend.apple.title == "Apple Intelligence (on this Mac, private)")
        // A saved choice wins over the default.
        LocalAISettings(enabled: true, backend: .ollama).save(to: d)
        #expect(LocalAISettings.load(from: d, defaultBackend: .apple).backend == .ollama)
    }

    @Test func appleStatusMatchesAvailability() {
        let s = AppleFoundationModelsProvider.status
        #expect((s == .available) == AppleFoundationModelsProvider.isAvailable)
        #expect((s.message == nil) == (s == .available))
        #expect(AppleIntelligenceEngine().unavailableReason == s.message)
    }

    #if canImport(FoundationModels) && arch(arm64)
    @Test func appleSchemaBuilds() throws {
        if #available(macOS 26.0, iOS 26.0, *) { _ = try AppleFoundationModelsProvider.schema() }
    }
    #endif
}

/// Apple Intelligence for real, same three snippets. Skipped unless
/// CEDRIC_APPLE_LIVE=1 and Apple Intelligence is available.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CEDRIC_APPLE_LIVE"] == "1"))
struct LiveAppleTests {
    @Test func liveAppleHints() async throws {
        print("LIVE apple status=\(AppleFoundationModelsProvider.status)")
        try #require(AppleFoundationModelsProvider.isAvailable)
        #if canImport(FoundationModels) && arch(arm64)
        let p = AppleFoundationModelsProvider()
        for (lang, file, code) in LiveCheckTests.snippets {
            let ctx = OwlContext(fileName: file, language: lang, text: code, textStart: 0,
                                 visibleRange: NSRange(location: 0, length: (code as NSString).length),
                                 selection: nil, documentID: UUID(), editGeneration: 1)
            let (hints, raw, secs) = try await p.requestHints(for: ctx)
            print("LIVE [\(file)] \(Int(secs * 1000)) ms hints=\(hints.count)")
            print("LIVE   raw=\(raw.replacingOccurrences(of: "\n", with: " "))")
            for h in hints {
                let anchored = h.range.map { (code as NSString).substring(with: $0) } ?? "-"
                print("LIVE   \(h.kind.rawValue): \(h.title) | detail=\(h.detail ?? "-") | at=\(anchored) | replacement=\(h.replacement ?? "-")")
            }
            #expect(secs < 20)
        }
        #endif
    }
}

@Suite struct AIStatusLineTests {
    @Test func statusLineWording() {
        #expect(LocalAIOwlBridge.statusLine(engine: "Apple Intelligence", outcome: .delivered(count: 0), age: 12.4)
                == "Last checked 12 s ago · Apple Intelligence · no suggestions")
        #expect(LocalAIOwlBridge.statusLine(engine: "Built-in", outcome: .delivered(count: 1), age: 125)
                == "Last checked 2 min ago · Built-in · 1 suggestion")
        #expect(LocalAIOwlBridge.statusLine(engine: "LM Studio", outcome: .timedOut, age: 7200)
                == "Last checked 2 h ago · LM Studio · timed out")
    }

    @MainActor @Test func bridgeReportsChecks() async throws {
        let registry = OwlProviderRegistry()
        // Apple Intelligence injected as available: the runner's own state must not matter.
        let bridge = LocalAIOwlBridge(registry: registry, engine: { _ in AppleIntelligenceEngine(status: .available) },
                                      makeProvider: { _ in FakeProvider() })
        #expect(bridge.statusLine() == nil)
        var s = LocalAISettings(enabled: true, backend: .apple, pauseDelay: 0.05, minIdle: 0)
        s.minInterval = 0.1
        await bridge.apply(s)
        #expect(bridge.statusLine() == "Apple Intelligence · waiting for a pause in typing")
        let checked = Box(0)
        bridge.onCheck = { checked.mutate { $0 += 1 } }
        bridge.contextChanged(context())
        #expect(await eventually { checked.value == 1 })
        #expect(bridge.statusLine()?.hasPrefix("Last checked 0 s ago · Apple Intelligence · 1 suggestion") == true)
        var off = s; off.enabled = false
        await bridge.apply(off)
        #expect(bridge.statusLine() == nil)
    }

    /// The path Intel and older Macs (and Macs with Apple Intelligence off)
    /// take: choosing Apple Intelligence leaves the AI off with the reason
    /// the settings sheet shows, no status line, nothing registered and no
    /// provider asked for.
    @MainActor @Test func bridgeWithoutAppleIntelligence() async {
        #if os(iOS)
        let expected: [(AppleIntelligenceStatus, String)] = [
            (.unsupported, "Needs iOS 26 or later on a device that supports Apple Intelligence."),
            (.osTooOld, "Needs iOS 26 or later on a device that supports Apple Intelligence."),
            (.deviceNotEligible, "This device can’t run Apple Intelligence."),
            (.notEnabled, "Turn on Apple Intelligence in Settings to use it."),
            (.modelNotReady, "Apple Intelligence is still getting its model ready. Try again later."),
            (.unknown, "Apple Intelligence isn’t available right now."),
        ]
        #else
        let expected: [(AppleIntelligenceStatus, String)] = [
            (.unsupported, "Needs macOS 26 or later on Apple silicon."),
            (.osTooOld, "Needs macOS 26 or later on Apple silicon."),
            (.deviceNotEligible, "This Mac can’t run Apple Intelligence."),
            (.notEnabled, "Turn on Apple Intelligence in System Settings to use it."),
            (.modelNotReady, "Apple Intelligence is still getting its model ready. Try again later."),
            (.unknown, "Apple Intelligence isn’t available right now."),
        ]
        #endif
        for (status, message) in expected {
            let engine = AppleIntelligenceEngine(status: status)
            #expect(!engine.isAvailable && engine.unavailableReason == message)
            let provider = await engine.makeProvider(model: nil)
            let models = try? await engine.models()
            let report = await engine.test()
            #expect(provider == nil && models?.isEmpty == true && report.error != nil)
            let registry = OwlProviderRegistry()
            let asked = Box(0)
            let bridge = LocalAIOwlBridge(registry: registry, engine: { _ in engine },
                                          makeProvider: { _ in asked.mutate { $0 += 1 }; return FakeProvider() })
            await bridge.apply(LocalAISettings(enabled: true, backend: .apple, pauseDelay: 0.05, minIdle: 0))
            #expect(!bridge.isActive && bridge.statusLine() == nil && bridge.engineTitle == nil)
            #expect(bridge.lastProblem == message)
            #expect(!registry.hasAIProvider && asked.value == 0)
        }
    }

    /// The same path on this Mac's real state, no injection: active exactly
    /// when Apple Intelligence is available, else off with its reason. On a
    /// CI VM (or with CEDRIC_SIMULATE_NO_APPLE_INTELLIGENCE=1) it is the
    /// unavailable case.
    @MainActor @Test func bridgeOnThisMacsAppleIntelligence() async {
        let registry = OwlProviderRegistry()
        let bridge = LocalAIOwlBridge(registry: registry, makeProvider: { _ in FakeProvider() })
        await bridge.apply(LocalAISettings(enabled: true, backend: .apple, pauseDelay: 0.05, minIdle: 0))
        let status = AppleFoundationModelsProvider.status
        if status == .available {
            #expect(bridge.isActive && bridge.lastProblem == nil)
            #expect(bridge.statusLine() == "Apple Intelligence · waiting for a pause in typing")
        } else {
            #expect(!bridge.isActive && bridge.statusLine() == nil && !registry.hasAIProvider)
            #expect(bridge.lastProblem != nil && bridge.lastProblem == status.message)
        }
        await bridge.apply(.default)
    }
}
