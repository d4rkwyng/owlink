import Foundation

/// The user-facing settings for the owl's local-AI hints.
///
/// Privacy defaults: `enabled` is **false**. When enabled, requests go only
/// to `baseURL`, which must be a loopback, `.local`, or private-network
/// (RFC 1918 / CGNAT / link-local) host — see `LocalEndpointPolicy`. There is
/// no cloud backend and no API-key field.
public struct LocalAISettings: Codable, Sendable, Equatable {
    /// Where the AI runs ("engine"), in Settings › Cedric's order.
    /// `custom` is another Mac on the network (raw value kept for saved
    /// settings). `builtIn` is Cedric's own engine (llama.cpp, models
    /// downloaded in the app); `apple` is Apple Intelligence's on-device model.
    public enum Backend: String, Codable, Sendable, CaseIterable {
        case builtIn, lmStudio, ollama, custom, apple

        public var defaultBaseURL: URL {
            switch self {
            case .ollama: return URL(string: "http://localhost:11434/v1")!
            default: return URL(string: "http://localhost:1234/v1")!
            }
        }

        /// Talks to an OpenAI-compatible server at `baseURL`.
        public var usesServer: Bool { self == .lmStudio || self == .ollama || self == .custom }
    }

    public var enabled: Bool
    public var backend: Backend
    /// The OpenAI-compatible root, ending in `/v1`.
    public var baseURL: URL
    /// The model id as `/v1/models` lists it; nil = auto-pick a small Qwen.
    public var model: String?
    /// Minimum seconds between two requests for the same document.
    public var minInterval: TimeInterval
    /// Typing must pause this long before a check is considered.
    public var pauseDelay: TimeInterval
    /// Hard cap on one request, cancelled sooner by a new edit.
    public var timeout: TimeInterval
    /// A document must have been open and idle this long before the AI
    /// looks at it (any engine). Not shown in Settings; tests shorten it.
    public var minIdle: TimeInterval
    /// Ask the model on its own after typing pauses. Off by default for
    /// servers and on Intel Macs; "Ask AI Now" remains available.
    public var automaticChecks: Bool
    /// Built-in engine only: load the model when Owlink starts (and when
    /// this is turned on), off the main thread and under the watchdog.
    /// Off by default: then the built-in model is loaded only when the user
    /// asks (Ask Cedric, Review, Ask AI Now, Check Grammar with Cedric…),
    /// and automatic hints use it only after that. Settings saved before
    /// this existed load with it off.
    public var loadModelAtLaunch: Bool

    /// True on Apple silicon for on-device engines; false on Intel, where
    /// a model on the CPU would compete with typing.
    public static var defaultAutomaticChecks: Bool {
        #if arch(x86_64)
        return false
        #else
        return true
        #endif
    }

    public static func defaultAutomaticChecks(for backend: Backend) -> Bool {
        backend.usesServer ? false : defaultAutomaticChecks
    }

    public static func shouldShowAutomaticServerNotice(backend: Backend, automaticChecks: Bool,
                                                       acknowledged: Bool) -> Bool {
        backend.usesServer && automaticChecks && !acknowledged
    }

    public init(enabled: Bool = false,
                backend: Backend = .builtIn,
                baseURL: URL? = nil,
                model: String? = nil,
                minInterval: TimeInterval = 90,
                pauseDelay: TimeInterval = 5,
                timeout: TimeInterval = 20,
                minIdle: TimeInterval = 10,
                automaticChecks: Bool? = nil,
                loadModelAtLaunch: Bool = false) {
        self.enabled = enabled
        self.backend = backend
        self.baseURL = baseURL ?? backend.defaultBaseURL
        self.model = model
        self.minInterval = minInterval
        self.pauseDelay = pauseDelay
        self.timeout = timeout
        self.minIdle = minIdle
        self.automaticChecks = automaticChecks ?? Self.defaultAutomaticChecks(for: backend)
        self.loadModelAtLaunch = loadModelAtLaunch
    }

    enum CodingKeys: String, CodingKey {
        case enabled, backend, baseURL, model, minInterval, pauseDelay, timeout, minIdle, automaticChecks, loadModelAtLaunch
    }

    /// Settings saved before `minIdle` or `automaticChecks` existed still
    /// load (with this Mac's defaults).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        backend = try c.decode(Backend.self, forKey: .backend)
        baseURL = try c.decode(URL.self, forKey: .baseURL)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        minInterval = try c.decode(TimeInterval.self, forKey: .minInterval)
        pauseDelay = try c.decode(TimeInterval.self, forKey: .pauseDelay)
        timeout = try c.decode(TimeInterval.self, forKey: .timeout)
        minIdle = try c.decodeIfPresent(TimeInterval.self, forKey: .minIdle) ?? 10
        automaticChecks = try c.decodeIfPresent(Bool.self, forKey: .automaticChecks) ?? Self.defaultAutomaticChecks(for: backend)
        loadModelAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .loadModelAtLaunch) ?? false
    }

    /// Settings › Cedric, under "Load model at launch": the one line shown
    /// (the full note below is its tooltip).
    public static let loadModelAtLaunchShortNote = "Off: automatic hints wait until you first ask Cedric."
    /// Settings › Cedric's tooltip for "Load model at launch", word for word.
    public static let loadModelAtLaunchNote = "Off: automatic hints use the built-in model only after you have asked Cedric something since Owlink started. On: Owlink loads it in the background when it starts."

    public static let `default` = LocalAISettings()

    static let defaultsKey = "CedricLocalAISettings"

    /// The saved settings; with nothing saved, the defaults with the best
    /// engine this Mac has (`AIEngines.defaultBackend`). Still off.
    public static func load(from defaults: UserDefaults = .standard,
                            defaultBackend: @autoclosure () -> Backend = AIEngines.defaultBackend()) -> LocalAISettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(LocalAISettings.self, from: data) else {
            return LocalAISettings(backend: defaultBackend())
        }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Keeps the provider on-device or on the LAN. Anything that resolves to a
/// public hostname or address is refused before a request is built.
public enum LocalEndpointPolicy {
    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        if !host.contains(".") && !host.contains(":") { return true }   // bare LAN name, e.g. "studio"
        // Tailnet MagicDNS. A Funnel host is public; the client also
        // requires every resolved address to be private (resolvesPrivately).
        if host.hasSuffix(".ts.net") { return true }
        if host.contains(":") {
            // IPv6: loopback, unique-local fc00::/7, link-local fe80::/10
            // (with or without a zone, "fe80::1%en0").
            return isPrivateAddress(host)
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return false   // a dotted public hostname
        }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true   // CGNAT / Tailscale
        default: return false
        }
    }
}

extension LocalEndpointPolicy {
    /// A redirect stays on the same scheme-allowed host (and port).
    public static func allowsRedirect(from: URL, to: URL) -> Bool {
        guard isAllowed(to), let a = from.host?.lowercased(), let b = to.host?.lowercased(), a == b else { return false }
        return from.port == to.port
    }

    /// An address split from its IPv6 zone: "fe80::1%en0" → ("fe80::1", "en0").
    /// The zone is the decoded form (as `URL.host` and getnameinfo give
    /// it, not "%25en0"), an interface name or number. nil when there is a
    /// "%" but the zone is empty or has other characters. The address part
    /// is not checked here.
    static func splitZone(_ ip: String) -> (address: String, zone: String?)? {
        guard let pct = ip.firstIndex(of: "%") else { return (ip, nil) }
        let zone = ip[ip.index(after: pct)...]
        guard !zone.isEmpty, zone.count <= 32,
              zone.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) })
        else { return nil }
        return (String(ip[..<pct]), String(zone))
    }

    /// An IPv6 link-local address (fe80::/10), with or without a zone.
    static func isLinkLocalV6(_ ip: String) -> Bool {
        var a6 = in6_addr()
        guard let (addr, _) = splitZone(ip), inet_pton(AF_INET6, addr, &a6) == 1 else { return false }
        let b = withUnsafeBytes(of: a6) { Array($0) }
        return b[0] == 0xfe && b[1] & 0xc0 == 0x80
    }

    /// An IPv4 or IPv6 address (an IPv6 one may carry a zone), not a name.
    static func isAddress(_ s: String) -> Bool {
        guard let (addr, zone) = splitZone(s) else { return false }
        var a = in_addr(), a6 = in6_addr()
        if zone == nil, inet_pton(AF_INET, addr, &a) == 1 { return true }
        return inet_pton(AF_INET6, addr, &a6) == 1
    }

    /// Loopback, RFC 1918, CGNAT (Tailscale), link-local, IPv6 unique-local.
    /// An IPv6 address may carry a zone ("fe80::1%en0", as a link-local
    /// address from a name lookup or a connection's peer has); an IPv4 one
    /// may not.
    public static func isPrivateAddress(_ ip: String) -> Bool {
        guard let (bare, zone) = splitZone(ip) else { return false }
        var a = in_addr(), a6 = in6_addr()
        if zone != nil {
            // Only IPv6 has zones.
            guard inet_pton(AF_INET6, bare, &a6) == 1 else { return false }
            return isPrivateAddress(bare)
        }
        let ip = bare
        if inet_pton(AF_INET, ip, &a) == 1 {
            let v = UInt32(bigEndian: a.s_addr)
            let b0 = v >> 24, b1 = (v >> 16) & 0xff
            switch (b0, b1) {
            case (127, _), (10, _), (192, 168), (169, 254), (172, 16...31), (100, 64...127): return true
            default: return false
            }
        }
        if inet_pton(AF_INET6, ip, &a6) == 1 {
            let b = withUnsafeBytes(of: a6) { Array($0) }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }          // ::1
            if b[0] & 0xfe == 0xfc { return true }                                     // fc00::/7
            if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true }                     // fe80::/10
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {    // ::ffff:a.b.c.d
                return isPrivateAddress("\(b[12]).\(b[13]).\(b[14]).\(b[15])")
            }
            return false
        }
        return false
    }

    /// Every address `host` resolves to (off the caller's thread).
    public static func resolve(_ host: String) async -> [String] {
        let h = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        return await withCheckedContinuation { (c: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(h, nil, &hints, &res) == 0 else { c.resume(returning: []); return }
                defer { freeaddrinfo(res) }
                var out: [String] = []
                var p = res
                while let ai = p {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        // A link-local IPv6 address keeps its zone ("fe80::1%en0"):
                        // without it the address can't be connected to.
                        out.append(String(cString: buf))
                    }
                    p = ai.pointee.ai_next
                }
                c.resume(returning: out)
            }
        }
    }

    /// The host resolves, and only to private addresses.
    public static func resolvesPrivately(_ host: String) async -> Bool {
        let addrs = await resolve(host)
        return !addrs.isEmpty && addrs.allSatisfy(isPrivateAddress)
    }
}

// MARK: - Settings › Cedric's model

extension LocalAISettings.Backend {
    /// The endpoint preset's name in Settings › Cedric.
    public var title: String {
        switch self {
        case .builtIn: return "Built-in (on this Mac)"
        case .lmStudio: return "LM Studio on this Mac"
        case .ollama: return "Ollama on this Mac"
        case .custom: return "Another Mac on your network (URL)"
        case .apple: return "Apple Intelligence (on this Mac, private)"
        }
    }
}

extension LocalAISettings {
    /// Shown under the endpoint in Settings › Cedric, word for word.
    public static let privacyNote = "Sends only the visible text (up to 8 KB) to the address above. Never the cloud."
    /// The same promise for engines without an address.
    public static let privacyNoteOnDevice = "Uses only the visible text (up to 8 KB), on this Mac. Never the cloud."
    /// Shown when the chosen (or only available) model is ≤ 2B.
    public static let weakModelNote = "Small models give weaker hints."
    /// The interval menu, in seconds (default 90).
    public static let intervalChoices: [TimeInterval] = [30, 60, 90, 120, 300]

    /// Picks an endpoint preset. LM Studio and Ollama set their localhost
    /// URL; Custom keeps the current URL for the user to edit. A different
    /// server means a different model list, so the model goes back to auto.
    public mutating func selectBackend(_ b: Backend) {
        guard b != backend else { return }
        backend = b
        if b != .custom { baseURL = b.defaultBaseURL }
        model = nil
        if b.usesServer { automaticChecks = false }
    }

    /// Parses what the user typed in the Custom URL field: adds `http://`
    /// when there is no scheme and `/v1` when there is no path. nil when it
    /// isn't a URL or the host isn't local/LAN (`LocalEndpointPolicy`).
    public static func parseEndpoint(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard var c = URLComponents(string: s), c.host?.isEmpty == false else { return nil }
        // An IPv6 zone typed as "%en0": written "%25en0" in the URL (RFC 6874).
        if let h = c.host, h.hasPrefix("["), h.hasSuffix("]"),
           let (addr, zone) = LocalEndpointPolicy.splitZone(String(h.dropFirst().dropLast())), let zone {
            c.percentEncodedHost = "[\(addr)%25\(zone)]"
        }
        if c.path.isEmpty || c.path == "/" { c.path = "/v1" }
        while c.path.count > 1 && c.path.hasSuffix("/") { c.path.removeLast() }
        guard let url = c.url, LocalEndpointPolicy.isAllowed(url) else { return nil }
        return url
    }

    /// Ready to register: on, with a local/LAN endpoint.
    public var isUsable: Bool { enabled && (!backend.usesServer || LocalEndpointPolicy.isAllowed(baseURL)) }

    /// The Cedric settings controls, as they stand when one of them changes.
    public struct ControlDraft: Sendable, Equatable {
        public var enabled: Bool
        public var backend: Backend
        /// The Address field. Read only when `backend` is `.custom`.
        public var addressText: String
        public var model: String?
        public var minInterval: TimeInterval
        public var automaticChecks: Bool
        /// nil: unchanged.
        public var loadModelAtLaunch: Bool?

        public init(enabled: Bool, backend: Backend, addressText: String, model: String?,
                    minInterval: TimeInterval, automaticChecks: Bool, loadModelAtLaunch: Bool? = nil) {
            self.enabled = enabled
            self.backend = backend
            self.addressText = addressText
            self.model = model
            self.minInterval = minInterval
            self.automaticChecks = automaticChecks
            self.loadModelAtLaunch = loadModelAtLaunch
        }
    }

    /// What `readControls` decided. An address that isn't on this Mac or the
    /// LAN never changes the saved settings, except turning AI off: that
    /// always applies, so a bad address can't leave the engine running.
    public enum ControlRead: Sendable, Equatable {
        /// Address is local, or this engine has none. Apply `settings`.
        case apply(LocalAISettings)
        /// Address is not local, and the user turned AI off. Apply this
        /// (enabled false; backend, address, model and schedule unchanged).
        case disable(LocalAISettings)
        /// Address is not local and this is not turning AI off. Apply nothing.
        case invalidAddress
    }

    /// Validates the address before changing anything.
    public func readControls(_ draft: ControlDraft) -> ControlRead {
        if draft.backend == .custom, Self.parseEndpoint(draft.addressText) == nil {
            if enabled, !draft.enabled {
                var off = self
                off.enabled = false
                return .disable(off)
            }
            return .invalidAddress
        }
        let switchedToServer = draft.backend != backend && draft.backend.usesServer
        var next = self
        next.enabled = draft.enabled
        if draft.backend != next.backend { next.selectBackend(draft.backend) }
        if draft.backend == .custom, let url = Self.parseEndpoint(draft.addressText), url != next.baseURL {
            next.baseURL = url
        }
        next.model = draft.model
        next.minInterval = draft.minInterval
        next.automaticChecks = switchedToServer ? false : draft.automaticChecks
        if let v = draft.loadModelAtLaunch { next.loadModelAtLaunch = v }
        return .apply(next)
    }
}
