import AppKit
import CedricCore
import ImageIO
import UniformTypeIdentifiers

/// Keeps a document smaller than the window in the middle of it.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        let f = doc.frame
        if r.width > f.width { r.origin.x = (f.width - r.width) / 2 }
        if r.height > f.height { r.origin.y = (f.height - r.height) / 2 }
        return r
    }
}

/// The scroll view round the image: reports resizes (fit follows the
/// window) and file drops (they open, as on the editor's text).
final class ImageScrollView: NSScrollView {
    var onResize: (() -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    private var lastSize = NSSize.zero

    override func layout() {
        super.layout()
        if frame.size != lastSize {
            lastSize = frame.size
            onResize?()
        }
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { fileURLs(sender).isEmpty ? [] : .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { fileURLs(sender).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}

/// The image, on a checkerboard (so transparency shows), at the image's
/// pixel size in points; the scroll view's magnification is the zoom.
/// Draws only what is asked, clipped to its own bounds.
final class ImageCanvas: NSView {
    /// The image as decoded for display (maybe smaller than the file's).
    var image: CGImage? { didSet { needsDisplay = true } }
    var checkerLight = NSColor.white, checkerDark = NSColor(white: 0.9, alpha: 1)
    /// The scroll view's magnification, for screen-sized checker squares
    /// and crisp pixels when zoomed in.
    var magnification: CGFloat = 1 { didSet { if oldValue != magnification { needsDisplay = true } } }
    var onSpace: (() -> Void)?
    /// Rotate Left / Right (view only), clockwise degrees: 0, 90, 180, 270.
    /// The view's size is the rotated image's.
    var rotation = 0 { didSet { if oldValue != rotation { needsDisplay = true } } }
    /// The right-click menu (the tab's).
    var contextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() ?? super.menu(for: event) }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", let onSpace { onSpace(); return }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = dirtyRect.intersection(bounds)
        guard !r.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: r)
        // 8-point squares on screen, whatever the zoom.
        let sq = max(8 / max(magnification, 0.001), 0.5)
        ctx.setFillColor(checkerLight.cgColor)
        ctx.fill(r)
        ctx.setFillColor(checkerDark.cgColor)
        let c0 = Int((r.minX / sq).rounded(.down)), c1 = Int((r.maxX / sq).rounded(.up))
        let r0 = Int((r.minY / sq).rounded(.down)), r1 = Int((r.maxY / sq).rounded(.up))
        if (c1 - c0) * (r1 - r0) < 40_000 {
            var rects: [CGRect] = []
            for row in r0..<r1 {
                for col in c0..<c1 where (row + col) & 1 == 1 {
                    rects.append(CGRect(x: CGFloat(col) * sq, y: CGFloat(row) * sq, width: sq, height: sq))
                }
            }
            ctx.fill(rects)
        }
        if let image {
            // Pixel art stays crisp when zoomed in; photos are smoothed when shrunk.
            let turned = rotation % 180 != 0
            let size = turned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
            let px = magnification * CGFloat(image.width) / max(size.width, 1)
            ctx.interpolationQuality = px >= 2 ? .none : .high
            // Flipped view: draw the image the right way up, turned about the middle.
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: bounds.width / 2, y: bounds.height / 2)
            ctx.rotate(by: -CGFloat(rotation) * .pi / 180)
            ctx.draw(image, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }
        ctx.restoreGState()
    }
}

/// What an image file is, read off the main thread.
struct ImageFileInfo: @unchecked Sendable {
    var width: Int
    var height: Int
    var fileBytes: Int64?
    var format: String
    var colorSpace: String?
    var frames: Int
    var animated: Bool
    var display: CGImage?
    var decodeSeconds: Double

    /// Reads the header and decodes for display (downsampled when big:
    /// ImageZoom.displayMaxPixelSize), turned by its EXIF orientation.
    /// Nil if ImageIO can't read it.
    static func load(_ url: URL, decode: Bool = true) -> ImageFileInfo? {
        let t0 = Date()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation >= 5 && orientation <= 8 { swap(&w, &h) }
        var prefix: [UInt8] = []
        if let fh = try? FileHandle(forReadingFrom: url) {
            prefix = Array((try? fh.read(upToCount: 32)) ?? Data())
            try? fh.close()
        }
        let uti = CGImageSourceGetType(src) as String?
        let format = ImageFormat.detect(prefix)?.displayName
            ?? uti.flatMap { UTType($0)?.preferredFilenameExtension?.uppercased() }
            ?? ImageFormat.forExtension(url.lastPathComponent)?.displayName ?? ""
        let space = ImageInfoText.colorSpaceName(profile: props[kCGImagePropertyProfileName] as? String,
                                                 model: props[kCGImagePropertyColorModel] as? String)
        let count = CGImageSourceGetCount(src)
        let kind = ImageFormat.detect(prefix)
        let animated = count > 1 && (kind == .gif || kind == .png || kind == .webp)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        var display: CGImage?
        if decode, w > 0, h > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: ImageZoom.displayMaxPixelSize(width: w, height: h),
            ]
            display = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        if w == 0 || h == 0, let d = display { w = d.width; h = d.height }
        return ImageFileInfo(width: w, height: h, fileBytes: bytes, format: format, colorSpace: space, frames: count,
                             animated: animated, display: display, decodeSeconds: Date().timeIntervalSince(t0))
    }
}

/// One image tab: a read-only view of an image file, in a window tabbed
/// with the editor's. Fit to the window, zoom (⌘= ⌘- ⌘0 ⌘9, pinch), pan,
/// a checkerboard behind transparency, animated GIFs play (Pause), Copy,
/// Open in Default App, Print. Never writes to the file: there is no save path.
///
/// Launch speed: the window is cheap; the image is read and decoded (off
/// the main thread, downsampled when big) only when the tab is first shown.
@MainActor
final class ImageTabController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, ViewerTab {
    let id: UUID
    var fileURL: URL
    private var state: ImageTabState
    private(set) var isLoaded = false
    /// Decoding (off the main thread).
    private(set) var loading = false
    private(set) var info: ImageFileInfo?
    /// A message instead of the image (damaged, gone).
    private(set) var message: String?
    private var fileModified: Date?
    let scrollView = ImageScrollView()
    private let clip = CenteringClipView()
    let canvas = ImageCanvas()
    let statusBar = StatusBar()
    let playButton = NSButton(title: "", target: nil, action: nil)
    private var messageLabel: NSTextField?
    private var observers: [NSObjectProtocol] = []
    private var appearanceObserver: NSObjectProtocol?
    /// Fitted to the window (⌘9, how an image opens).
    private(set) var fitted = true
    /// Animation: playing, and the frame shown.
    private(set) var playing = false
    private(set) var frameIndex = 0
    /// Bumped to stop the running animation's callbacks.
    private var animationGeneration = 0
    /// Frames shown since the animation (re)started (the checks).
    private(set) var framesShown = 0

    var onChange: ((ImageTabController) -> Void)?
    var onClose: ((ImageTabController) -> Void)?

    init(fileURL: URL, id: UUID = UUID(), state: ImageTabState = ImageTabState()) {
        self.id = id
        self.fileURL = fileURL
        self.state = state
        fitted = state.scale == nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "CedricEditor"
        window.minSize = NSSize(width: 420, height: 240)
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        buildViews()
        window.title = fileURL.lastPathComponent
        window.representedURL = fileURL
        window.tab.toolTip = fileURL.path
        statusBar.position.stringValue = String(localized: "Image")
        applyAppearance()
        appearanceObserver = NotificationCenter.default.addObserver(forName: .cedricAppearanceChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var displayName: String { fileURL.lastPathComponent }

    // MARK: Views

    private func buildViews() {
        guard let window else { return }
        clip.drawsBackground = true
        scrollView.contentView = clip
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.allowsMagnification = true
        scrollView.minMagnification = ImageZoom.minScale
        scrollView.maxMagnification = ImageZoom.maxScale
        scrollView.documentView = canvas
        canvas.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        canvas.onSpace = { [weak self] in self?.togglePlaying(nil) }
        canvas.contextMenu = { [weak self] in self?.makeContextMenu() }
        scrollView.onResize = { [weak self] in self?.windowResized() }
        scrollView.onDropFiles = { urls in FileDrop.open(urls) }
        scrollView.registerForDraggedTypes([.fileURL])
        for b in [statusBar.languageButton, statusBar.encodingButton, statusBar.lineEndingButton] { b.isHidden = true }
        // Pause / Play for an animation, over the image's bottom-left corner.
        playButton.bezelStyle = .accessoryBarAction
        playButton.controlSize = .small
        playButton.target = self
        playButton.action = #selector(togglePlaying(_:))
        playButton.isHidden = true
        playButton.translatesAutoresizingMaskIntoConstraints = false
        let body = NSView()
        scrollView.frame = body.bounds
        scrollView.autoresizingMask = [.width, .height]
        body.addSubview(scrollView)
        body.addSubview(playButton)
        NSLayoutConstraint.activate([
            playButton.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 10),
            playButton.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -10),
        ])
        let stack = NSStackView(views: [body, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.detachesHiddenViews = true
        body.setContentHuggingPriority(.init(1), for: .vertical)
        window.contentView = stack
        let nc = NotificationCenter.default
        clip.postsBoundsChangedNotifications = true
        observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewMoved() }
        })
        // Pinch: no longer fitted.
        observers.append(nc.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fitted = false
                self.zoomChanged()
            }
        })
    }

    var palette: EditorPalette { Settings.shared.palette(for: window?.effectiveAppearance) }

    /// The chrome follows the theme; the checkerboard is light or dark to match.
    func applyAppearance() {
        window?.appearance = Settings.shared.windowAppearance
        let p = palette
        statusBar.background = NSColor(hex: p.statusBar)
        let bg = NSColor(hex: p.gutterBackground)
        clip.backgroundColor = bg
        scrollView.backgroundColor = bg
        let dark = (bg.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.45
        canvas.checkerLight = dark ? NSColor(white: 0.24, alpha: 1) : .white
        canvas.checkerDark = dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.88, alpha: 1)
        canvas.needsDisplay = true
        messageLabel?.textColor = .secondaryLabelColor
    }

    // MARK: Loading

    /// Reads and decodes the image the first time the tab is shown, off
    /// the main thread.
    func ensureLoaded() {
        guard !isLoaded else { return }
        isLoaded = true
        loading = true
        fileModified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        statusBar.counts.stringValue = String(localized: "Loading…")
        let url = fileURL
        DispatchQueue.global(qos: .userInitiated).async {
            let info = ImageFileInfo.load(url)
            Task { @MainActor [weak self] in self?.loaded(info, from: url) }
        }
    }

    /// How long the last `loaded` took on the main thread (the checks).
    private(set) var loadedMs = 0.0

    private func loaded(_ info: ImageFileInfo?, from url: URL) {
        let t0 = Date()
        defer { loadedMs = Date().timeIntervalSince(t0) * 1000 }
        loading = false
        statusBar.counts.stringValue = ""
        if info == nil, url != fileURL {
            isLoaded = false
            ensureLoaded()
            return
        }
        guard let info, info.width > 0, info.height > 0, info.display != nil else {
            self.info = nil
            showMessage(Self.damagedMessage(fileURL))
            return
        }
        clearMessage()
        self.info = info
        canvas.rotation = 0
        canvas.frame = NSRect(x: 0, y: 0, width: info.width, height: info.height)
        canvas.image = info.display
        if let s = state.scale {
            fitted = false
            setScale(s, center: NSPoint(x: (state.centerX ?? 0.5) * Double(info.width), y: (state.centerY ?? 0.5) * Double(info.height)))
        } else {
            fit()
        }
        if info.animated {
            playButton.isHidden = false
            startAnimation(at: 0)
        }
        window?.makeFirstResponder(canvas)
        updateStatus()
    }

    static func damagedMessage(_ url: URL) -> String {
        FileManager.default.fileExists(atPath: url.path)
            ? String(localized: "“\(url.lastPathComponent)” couldn’t be opened. It isn’t an image Owlink can show, or it is damaged.")
            : String(localized: "“\(url.lastPathComponent)” couldn’t be opened: the file has gone.")
    }

    private func showMessage(_ text: String) {
        message = text
        messageLabel?.removeFromSuperview()
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 15)
        label.translatesAutoresizingMaskIntoConstraints = false
        guard let body = scrollView.superview else { return }
        body.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
        ])
        messageLabel = label
        scrollView.isHidden = true
        statusBar.position.stringValue = String(localized: "Image")
        statusBar.zoom.stringValue = ""
    }

    private func clearMessage() {
        message = nil
        messageLabel?.removeFromSuperview()
        messageLabel = nil
        scrollView.isHidden = false
    }

    /// The file changed on disk (applicationDidBecomeActive): read it again, at the same zoom.
    func reloadIfChangedOnDisk() {
        guard isLoaded, !loading, let known = fileModified,
              let mod = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, mod > known else { return }
        state = sessionState
        stopAnimation()
        isLoaded = false
        ensureLoaded()
    }

    // MARK: Zoom

    var scale: CGFloat { scrollView.magnification }

    /// The image's size as shown: turned by Rotate Left / Right.
    private var shownSize: (width: Int, height: Int) {
        guard let info else { return (0, 0) }
        return canvas.rotation % 180 == 0 ? (info.width, info.height) : (info.height, info.width)
    }

    private var visibleCenter: NSPoint {
        let r = clip.bounds
        return NSPoint(x: r.midX, y: r.midY)
    }

    /// ⌘9 and how an image opens: all of it in the window, never enlarged.
    func fit() {
        guard info != nil else { return }
        fitted = true
        // The whole frame: once fitted, no scrollers are needed.
        let size = scrollView.frame.size, shown = shownSize
        let s = ImageZoom.fitScale(imageWidth: Double(shown.width), imageHeight: Double(shown.height),
                                   viewWidth: Double(size.width), viewHeight: Double(size.height))
        zoom(to: s, center: NSPoint(x: Double(shown.width) / 2, y: Double(shown.height) / 2))
        zoomChanged()
    }

    /// Magnifies, then scrolls `center` (image points) to the middle.
    private func zoom(to s: Double, center: NSPoint) {
        scrollView.magnification = CGFloat(s)
        let b = clip.bounds
        clip.scroll(to: clip.constrainBoundsRect(NSRect(x: center.x - b.width / 2, y: center.y - b.height / 2, width: b.width, height: b.height)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func setScale(_ s: Double, center: NSPoint? = nil) {
        guard info != nil else { return }
        fitted = false
        zoom(to: ImageZoom.clamp(s), center: center ?? visibleCenter)
        zoomChanged()
    }

    private func windowResized() {
        if fitted, info != nil { fit() }
    }

    private func zoomChanged() {
        canvas.magnification = scrollView.magnification
        updateStatus()
        onChange?(self)
    }

    private func viewMoved() {
        if canvas.magnification != scrollView.magnification {
            canvas.magnification = scrollView.magnification
            updateStatus()
        }
        onChange?(self)
    }

    @objc func zoomIn(_ sender: Any?) { setScale(Double(scale) * ImageZoom.step) }
    @objc func zoomOut(_ sender: Any?) { setScale(Double(scale) / ImageZoom.step) }
    /// ⌘0, Actual Size: one image pixel per point.
    @objc func zoomReset(_ sender: Any?) { setScale(1) }
    /// The status bar's 75–200 %.
    @objc func zoomToPercent(_ sender: Any?) {
        guard let p = (sender as? NSMenuItem)?.tag, p > 0 else { return }
        setScale(Double(p) / 100)
    }
    /// ⌘9: fit the image to the window.
    @objc func zoomToFit(_ sender: Any?) { fit() }

    /// Rotate Left / Right: the view only (the file is never changed, as
    /// in a PDF tab); a fitted image is fitted again.
    @objc func rotateImageLeft(_ sender: Any?) { rotateView(by: -90) }
    @objc func rotateImageRight(_ sender: Any?) { rotateView(by: 90) }

    func rotateView(by delta: Int) {
        guard info != nil else { return }
        let middle = visibleCenter, old = shownSize
        let fraction = (x: Double(middle.x) / Double(max(old.width, 1)), y: Double(middle.y) / Double(max(old.height, 1)))
        canvas.rotation = ((canvas.rotation + delta) % 360 + 360) % 360
        let shown = shownSize
        canvas.frame = NSRect(x: 0, y: 0, width: shown.width, height: shown.height)
        if fitted { fit() } else {
            // The same spot of the picture stays in the middle.
            let (fx, fy) = delta > 0 ? (1 - fraction.y, fraction.x) : (fraction.y, 1 - fraction.x)
            setScale(Double(scale), center: NSPoint(x: fx * Double(shown.width), y: fy * Double(shown.height)))
        }
    }

    @objc func copyImagePath(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(fileURL.path, forType: .string)
    }

    @objc func revealImageInFinder(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }

    /// Show Info: what the status bar shows, in a sheet (already read; nothing is decoded again).
    @objc func showImageInfo(_ sender: Any?) {
        guard let info, let window else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = fileURL.lastPathComponent
        var lines = [String(localized: "Dimensions: \(String(info.width)) × \(String(info.height)) pixels")]
        if let b = info.fileBytes { lines.append(String(localized: "Size: \(ByteCountFormatter.string(fromByteCount: b, countStyle: .file))")) }
        if !info.format.isEmpty { lines.append(String(localized: "Format: \(info.format)")) }
        if let cs = info.colorSpace { lines.append(String(localized: "Colour space: \(cs)")) }
        if info.animated { lines.append(String(localized: "Frames: \(info.frames)")) }
        lines.append(fileURL.path)
        a.informativeText = lines.joined(separator: "\n")
        a.beginSheetModal(for: window)
    }

    /// The right-click menu on the image (0.2.1): the View menu's zoom
    /// items, rotate (view only), Copy Image, Copy Path, Reveal in Finder,
    /// Open in Default App and Show Info. Validated like the menu bar.
    func makeContextMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "") {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = key.isEmpty ? [] : .command
            i.target = self
            m.addItem(i)
        }
        add(String(localized: "Zoom In"), #selector(zoomIn(_:)), "=")
        add(String(localized: "Zoom Out"), #selector(zoomOut(_:)), "-")
        add(String(localized: "Actual Size"), #selector(zoomReset(_:)), "0")
        add(String(localized: "Zoom to Fit"), #selector(zoomToFit(_:)), "9")
        m.addItem(.separator())
        add(String(localized: "Rotate Left"), #selector(rotateImageLeft(_:)))
        add(String(localized: "Rotate Right"), #selector(rotateImageRight(_:)))
        m.addItem(.separator())
        add(String(localized: "Copy Image"), #selector(copy(_:)))
        add(String(localized: "Copy Path"), #selector(copyImagePath(_:)))
        add(String(localized: "Reveal in Finder"), #selector(revealImageInFinder(_:)))
        add(String(localized: "Open in Default App"), #selector(openInDefaultApp(_:)))
        m.addItem(.separator())
        add(String(localized: "Show Info"), #selector(showImageInfo(_:)))
        return m
    }

    // MARK: Status

    var statusText: String { statusBar.position.stringValue }

    func updateStatus() {
        guard let info else { return }
        statusBar.position.stringValue = ImageInfoText.status(width: info.width, height: info.height, fileBytes: info.fileBytes,
                                                              format: info.format, colorSpace: info.colorSpace, frames: info.animated ? info.frames : 1)
        statusBar.zoom.stringValue = ImageZoom.percent(Double(scale))
    }

    /// What the session keeps: the zoom (nil when fitted) and the middle
    /// of what is shown, or what is still to show for a tab not loaded yet.
    var sessionState: ImageTabState {
        guard let info, isLoaded, !loading else { return state }
        if fitted { return ImageTabState() }
        let c = visibleCenter
        return ImageTabState(scale: Double(scale), centerX: min(max(Double(c.x) / Double(info.width), 0), 1),
                             centerY: min(max(Double(c.y) / Double(info.height), 0), 1))
    }

    var sessionTab: SessionTab { SessionTab(id: id, path: fileURL.path, untitledName: nil, image: sessionState) }

    // MARK: Animation

    private func startAnimation(at index: Int) {
        animationGeneration += 1
        let gen = animationGeneration
        playing = true
        framesShown = 0
        updatePlayButton()
        let opts = [kCGImageAnimationStartIndex: index] as CFDictionary
        // ImageIO times the frames and calls back on the main queue.
        let status = CGAnimateImageAtURLWithBlock(fileURL as CFURL, opts) { [weak self] i, image, stop in
            MainActor.assumeIsolated {
                guard let self, self.animationGeneration == gen, self.playing else { stop.pointee = true; return }
                self.frameIndex = i
                self.framesShown += 1
                self.canvas.image = image
            }
        }
        if status != noErr { playing = false; updatePlayButton() }
    }

    private func stopAnimation() {
        animationGeneration += 1
        playing = false
        updatePlayButton()
    }

    private func updatePlayButton() {
        playButton.title = playing ? String(localized: "Pause") : String(localized: "Play")
    }

    /// The Pause / Play button, or Space.
    @objc func togglePlaying(_ sender: Any?) {
        guard info?.animated == true else { return }
        if playing { stopAnimation() } else { startAnimation(at: frameIndex + 1 < (info?.frames ?? 1) ? frameIndex + 1 : 0) }
    }

    // MARK: Copy, Open With, Print

    /// Edit › Copy: the image itself (the file's own bytes for its type,
    /// and TIFF made only when something pastes it).
    @objc func copy(_ sender: Any?) {
        guard info != nil else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        let uti = (CGImageSourceCreateWithURL(fileURL as CFURL, nil)).flatMap { CGImageSourceGetType($0) as String? }
        // The file's own bytes as its own type (JPEG stays JPEG, nothing re-encoded).
        if let uti, let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
            item.setData(data, forType: NSPasteboard.PasteboardType(uti))
        }
        let provider = ImagePasteProvider(url: fileURL)
        ImagePasteProvider.current = provider
        let promised = [NSPasteboard.PasteboardType.tiff, .png].filter { !item.types.contains($0) }
        if !promised.isEmpty { item.setDataProvider(provider, forTypes: promised) }
        pb.writeObjects([item])
    }

    @objc func openInDefaultApp(_ sender: Any?) { AppDelegate.openInDefaultApp(fileURL) }

    /// File › Print…: the image fitted to the page.
    @objc func printDocument(_ sender: Any?) {
        guard let window, let op = makePrintOperation() else { NSSound.beep(); return }
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func makePrintOperation(_ printInfo: NSPrintInfo = NSPrintInfo.shared) -> NSPrintOperation? {
        guard let info, let cg = canvas.image ?? info.display else { return nil }
        let pi = printInfo.copy() as! NSPrintInfo
        pi.horizontalPagination = .fit
        pi.verticalPagination = .fit
        pi.isHorizontallyCentered = true
        pi.isVerticallyCentered = true
        if info.width > info.height { pi.orientation = .landscape }
        let page = pi.imageablePageBounds.size
        let s = min(page.width / CGFloat(info.width), page.height / CGFloat(info.height))
        let size = NSSize(width: max(1, CGFloat(info.width) * s), height: max(1, CGFloat(info.height) * s))
        let v = NSImageView(frame: NSRect(origin: .zero, size: size))
        v.imageScaling = .scaleProportionallyUpOrDown
        v.image = NSImage(cgImage: cg, size: size)
        let op = NSPrintOperation(view: v, printInfo: pi)
        op.jobTitle = displayName
        return op
    }

    /// File › Close Window (⇧⌘W): every tab in this window.
    @objc func closeWindow(_ sender: Any?) {
        guard let w = window else { return }
        (NSApp.delegate as? AppDelegate)?.closeDocumentWindows(in: w)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        (NSApp.delegate as? AppDelegate)?.shouldCloseDocumentWindow(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        stopAnimation()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        appearanceObserver.map { NotificationCenter.default.removeObserver($0) }
        appearanceObserver = nil
        onClose?(self)
        // AppKit may keep the window a while: cut its views' paths back here.
        scrollView.onResize = nil
        scrollView.onDropFiles = nil
        canvas.onSpace = nil
        canvas.image = nil
        playButton.target = nil
        window?.delegate = nil
        window?.contentView = NSView()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        loadIfShown()
        (NSApp.delegate as? AppDelegate)?.folderSidebarFollow(self)
    }
    func windowDidBecomeMain(_ notification: Notification) { loadIfShown() }
    func windowDidChangeOcclusionState(_ notification: Notification) { loadIfShown() }

    /// Loads once the tab is really the one shown (as PDFTabController).
    private func loadIfShown() {
        guard !isLoaded else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isLoaded, let w = self.window, w.isVisible,
                  w.tabGroup.map({ $0.selectedWindow === w }) ?? true else { return }
            self.ensureLoaded()
        }
    }

    // MARK: Menus

    /// Editor-only commands AppDelegate would otherwise leave enabled: here, nothing.
    @objc func pickLanguageMenu(_ sender: Any?) {}
    @objc func pickEncodingMenu(_ sender: Any?) {}
    @objc func pickLineEndingMenu(_ sender: Any?) {}
    @objc func togglePreview(_ sender: Any?) {}
    @objc func showReplace(_ sender: Any?) {}
    @objc func saveDocument(_ sender: Any?) {}
    @objc func saveDocumentAs(_ sender: Any?) {}
    @objc func findInFilesMenu(_ sender: Any?) {}

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        if PDFTabController.disabledHere.contains(action) { item.state = .off; return false }
        let ready = info != nil
        switch action {
        case #selector(zoomToFit(_:)):
            item.state = fitted && ready ? .on : .off
            return ready
        case #selector(openInDefaultApp(_:)):
            item.title = AppDelegate.openInTitle(fileURL)
            return AppDelegate.defaultApp(for: fileURL) != nil
        case #selector(togglePlaying(_:)): return info?.animated == true
        case #selector(closeWindow(_:)), #selector(copyImagePath(_:)), #selector(revealImageInFinder(_:)): return true
        default: return ready
        }
    }
}

/// Makes the TIFF / PNG of a copied image only when it is pasted (a
/// 100-megapixel photo isn't converted on every ⌘C).
final class ImagePasteProvider: NSObject, NSPasteboardItemDataProvider {
    /// The pasteboard doesn't keep its provider: the last one stays here.
    @MainActor static var current: ImagePasteProvider?
    let url: URL
    init(url: URL) { self.url = url }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
        let data = NSMutableData()
        let uti = (type == .png ? UTType.png : UTType.tiff).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(data, uti, 1, nil) else { return }
        // Turned the way it is shown.
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        var add: [CFString: Any] = [:]
        if let o = props?[kCGImagePropertyOrientation] { add[kCGImagePropertyOrientation] = o }
        CGImageDestinationAddImage(dest, img, add as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        item.setData(data as Data, forType: type)
    }
}

// MARK: - App: opening image tabs

extension AppDelegate {
    func imageTab(for url: URL) -> ImageTabController? {
        let std = url.standardizedFileURL
        return imageTabs.first { $0.fileURL.standardizedFileURL == std }
    }

    var currentImageTab: ImageTabController? { currentViewerTab as? ImageTabController }

    /// Opens an image in a viewer tab (every route goes through `open`),
    /// or focuses the tab that has it. One ImageIO can't read is an
    /// alert, not a tab. Only the header is read here; the pixels are
    /// decoded off the main thread.
    @discardableResult
    func openImage(_ url: URL) -> ImageTabController? {
        let std = url.standardizedFileURL
        if let existing = imageTab(for: std) {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        guard let src = CGImageSourceCreateWithURL(std as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0, CGImageSourceGetType(src) != nil else {
            viewerAlert(ImageTabController.damagedMessage(std))
            return nil
        }
        let blank = replaceableBlankTab
        let tab = makeImageTab(ImageTabController(fileURL: std))
        tab.ensureLoaded()
        blank?.window?.close()
        noteRecent(std)
        return tab
    }

    @discardableResult
    func makeImageTab(_ tab: ImageTabController, in group: NSWindow? = nil, newWindow: Bool = false, show: Bool = true,
                      tabIndex: Int? = nil) -> ImageTabController {
        tab.onChange = { [weak self] _ in self?.scheduleSessionSave() }
        tab.onClose = { [weak self] t in
            self?.releaseWaiters(for: t.id)
            guard let self, !self.terminating else { return }
            let last = self.isClosingLastDocument(t.window)
            self.imageTabs.removeAll { $0 === t }
            self.rememberClosedViewer(t)
            if last { self.quitAfterLastClose() }
        }
        imageTabs.append(tab)
        if let window = tab.window { placeViewerWindow(window, in: group, newWindow: newWindow, show: show, tabIndex: tabIndex) }
        return tab
    }
}
