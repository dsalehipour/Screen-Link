import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Security

final class Application: ScreenCapturerDelegate {
    private var config: Config
    private let capturer = ScreenCapturer()
    private let encoder = H264Encoder()
    private let server: Server
    private var injector: InputInjector?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private let statsLock = NSLock()
    private var framesCaptured = 0
    private var framesEncoded = 0
    private var encodeMillisTotal = 0.0
    // Stream metadata is read on the websocket and HTTP queues and written on the capture queue.
    // A separate lock for the switching flag keeps switchDisplay from re-entering stateLock.
    private let stateLock = NSLock()
    private var _codec = "avc1.640028"
    private var _displays: [DisplayInfo] = []
    private var _captureReady = false
    private let switchLock = NSLock()
    private var switching = false
    private var _maxWidth = 0
    // The most recent frame, kept so a still screen can still be shown to someone who just arrived.
    private let frameLock = NSLock()
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastPixelBufferAt: CMTime = .zero
    private var nudgeCount: Int64 = 0
    private(set) var certificateFingerprint: String?

    /// The address to hand to another device, as opposed to the loopback one used locally.
    ///
    /// The token rides in the fragment, which browsers never put on the wire. It stays out of
    /// request lines, out of any proxy or access log, and out of the Referer header, so the only
    /// place it exists is the address bar of the device that scanned the code.
    func publicURL() -> String {
        if case .running(let base) = tunnel.state {
            return "\(base)/#t=\(config.token)"
        }
        let scheme = config.useTLS ? "https" : "http"
        return "\(scheme)://\(config.bindHost):\(config.port)/#t=\(config.token)"
    }

    private var codec: String {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _codec }
        set { stateLock.lock(); _codec = newValue; stateLock.unlock() }
    }

    private var displays: [DisplayInfo] {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _displays }
        set { stateLock.lock(); _displays = newValue; stateLock.unlock() }
    }

    private var captureReady: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _captureReady }
        set { stateLock.lock(); _captureReady = newValue; stateLock.unlock() }
    }

    private var maxWidth: Int {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _maxWidth }
        set { stateLock.lock(); _maxWidth = newValue; stateLock.unlock() }
    }

    let devices: DeviceStore
    let tunnel = TunnelController()
    /// Raised when a device is waiting on a decision, so the menu bar can put it in front of someone.
    var onPairingRequest: ((PairingRequest) -> Void)?
    var onPairingWithdrawn: ((String) -> Void)?

    init(config: Config) {
        self.config = config
        self.devices = DeviceStore(directory: Config.supportDirectory())
        self.server = Server(token: config.token, devices: devices)
    }

    func resolvePairing(requestId: String, approved: Bool) {
        server.resolvePairing(requestId: requestId, approved: approved)
    }

    func revoke(deviceId: String) {
        devices.revoke(deviceId: deviceId)
        server.disconnectDevice(deviceId)
    }

    func revokeAllDevices() {
        let all = devices.approved
        devices.revokeAll()
        for device in all { server.disconnectDevice(device.id) }
    }

    /// Servers come up before capture so a denied screen recording permission still leaves a
    /// reachable surface that can explain what is wrong, rather than an app that exits silently.
    func start() async throws {
        server.streamInfo = { [weak self] in self?.currentInfo() }
        server.statusMessage = { [weak self] in
            guard let self else { return "starting up" }
            return self.captureReady
                ? "capture running"
                : "screen recording permission not granted — approve screenlink in System Settings > Privacy & Security > Screen & System Audio Recording, then rerun scripts/run.sh"
        }
        server.onClientReady = { [weak self] in self?.nudge() }
        server.onPairingRequest = { [weak self] request in self?.onPairingRequest?(request) }
        server.onPairingWithdrawn = { [weak self] requestId in self?.onPairingWithdrawn?(requestId) }
        server.onCommand = { [weak self] command in
            guard let self else { return }
            // Choosing which display to watch is a view change, not input, so it stays available
            // even when input injection is disabled.
            if command.type == .display {
                Task { await self.switchDisplay(to: command.display) }
                return
            }
            if command.type == .quality {
                guard let requested = command.maxWidth else { return }
                Task { await self.setMaxWidth(requested) }
                return
            }
            guard self.config.allowInput else { return }
            self.injector?.handle(command)
        }
        server.httpHandler = { [weak self] request, respond in
            self?.route(request, respond) ?? respond(.text("unavailable", status: 503))
        }
        try startServer()
        startStatsTimer()

        // Detached so the retry loop never delays the server coming up.
        Task { await self.startCapture() }

        tunnel.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .running:
                Log.info("internet link open: \(publicURL())")
            case .failed(let reason):
                Log.error("internet link failed: \(reason)")
            case .starting:
                Log.info("opening internet link…")
            case .off:
                Log.info("internet link closed")
            }
        }
        if config.tunnel { menuBarSetTunnel(true) }

        Log.info("")
        Log.info("  open  \(publicURL())")
        if let fingerprint = certificateFingerprint {
            Log.info("  certificate SHA-256: \(fingerprint)")
        }
        Log.info("")
    }

    private func startServer() throws {
        var identity: SecIdentity?
        if config.useTLS {
            // Cover loopback as well as the bind address, so one certificate serves local testing
            // and the phone without being regenerated on every toggle.
            var names = Set(["localhost", "127.0.0.1", config.bindHost])
            names.formUnion(NetworkInterfaces.localIPv4().map(\.address))
            let source = SelfSignedCertificateSource(directory: SelfSignedCertificateSource.defaultDirectory())
            identity = try source.identity(covering: Array(names))
            certificateFingerprint = source.fingerprint()
        } else {
            certificateFingerprint = nil
        }
        try server.start(host: .init(config.bindHost), port: config.port, identity: identity)
    }

    /// Moving between loopback and the network changes the certificate and the origin, so the
    /// listener is rebuilt rather than adjusted. Existing viewers are dropped deliberately: their
    /// link points at an address that is about to stop answering.
    private func rebind(host: String, tls: Bool) {
        guard host != config.bindHost || tls != config.useTLS else { return }
        server.stop()
        config.bindHost = host
        config.useTLS = tls
        do {
            try startServer()
            Log.info("now reachable at \(publicURL())")
        } catch {
            Log.error("could not rebind to \(host): \(error)")
            config.bindHost = "127.0.0.1"
            config.useTLS = false
            try? startServer()
        }
    }

    /// CGPreflightScreenCaptureAccess predates ScreenCaptureKit and does not reliably track its
    /// permission state, so attempting SCShareableContent is the only trustworthy check.
    private func startCapture() async {
        var attempt = 0
        while !captureReady {
            attempt += 1
            do {
                try await capturer.start(displayID: config.displayID,
                                         maxWidth: config.maxWidth, fps: config.fps)
                maxWidth = config.maxWidth
                capturer.delegate = self
                injector = InputInjector(displayID: capturer.displayID)
                displays = (try? await ScreenCapturer.availableDisplays()) ?? []
                for display in displays {
                    Log.info("display \(display.index): \(display.name) \(display.width)x\(display.height) "
                        + "at (\(display.x),\(display.y)) id=\(display.id)\(display.isMain ? " [main]" : "")")
                }

                try encoder.start(width: capturer.width, height: capturer.height,
                                  fps: config.fps,
                                  bitrate: bitrate(for: capturer.width, capturer.height))
                encoder.onCodecString = { [weak self] value in
                    guard let self else { return }
                    self.codec = value
                    Log.info("stream codec: \(value)")
                    // The real profile is only known once the encoder emits its first SPS. Clients
                    // configured from the placeholder need the correction pushed to them.
                    self.broadcastInfo()
                }
                encoder.onFrame = { [weak self] frame in
                    guard let self else { return }
                    self.statsLock.lock()
                    self.framesEncoded += 1
                    self.encodeMillisTotal += epochMillis() - frame.captureEpochMs
                    self.statsLock.unlock()
                    self.server.broadcast(frame)
                }
                captureReady = true
                watchDisplayChanges()
                Log.info("capture is live")
            } catch {
                if attempt == 1 {
                    Log.error("capture failed to start: \(error)")
                    Log.warn("grant Screen & System Audio Recording to screenlink, then this will pick it up automatically")
                    Permissions.requestScreenRecording()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Displays

    private func currentInfo() -> StreamInfo? {
        guard captureReady else { return nil }
        return StreamInfo(width: capturer.width, height: capturer.height,
                          fps: config.fps, codec: codec,
                          displayID: capturer.displayID, displays: displays,
                          maxWidth: maxWidth, bitrate: bitrate(for: capturer.width, capturer.height))
    }

    /// Bitrate follows pixel count, because a fixed budget that looks clean at 1920 wide turns a
    /// full-resolution stream to mush the moment anything on screen moves. The floor keeps small
    /// pictures from being starved; the ceiling keeps a 5K panel from saturating the link.
    private func bitrate(for width: Int, _ height: Int) -> Int {
        let scale = Double(width * height) / Double(1920 * 1080)
        let scaled = Int((Double(config.bitrate) * scale).rounded())
        return min(max(scaled, config.bitrate / 2), config.bitrate * 4)
    }

    private func broadcastInfo() {
        guard let info = currentInfo(), let json = try? JSONEncoder().encode(info) else { return }
        server.broadcastJSON(json)
    }

    /// Locking lives in synchronous helpers because NSLock is not usable from an async context,
    /// and holding one across an await would be a deadlock waiting to happen anyway.
    private func beginSwitch() -> Bool {
        switchLock.lock()
        defer { switchLock.unlock() }
        if switching { return false }
        switching = true
        return true
    }

    private func endSwitch() {
        switchLock.lock()
        switching = false
        switchLock.unlock()
    }

    func switchDisplay(to id: CGDirectDisplayID?) async {
        guard let id, captureReady else { return }
        guard id != capturer.displayID else {
            // Already here. Still answer, so a client waiting on confirmation is not left hanging.
            broadcastInfo()
            return
        }

        guard beginSwitch() else { return }
        defer { endSwitch() }

        do {
            // The encoder is torn down first so no frame at the new resolution is ever handed to a
            // session configured for the old one. Frames arriving mid-switch are simply dropped.
            encoder.stop()
            discardLastFrame()
            try await capturer.switchTo(displayID: id)
            try encoder.start(width: capturer.width, height: capturer.height,
                              fps: config.fps, bitrate: bitrate(for: capturer.width, capturer.height))
            injector?.displayID = capturer.displayID
            // Sent immediately so clients learn the new resolution before frames at that size
            // start arriving. The codec string follows separately once the new SPS exists.
            broadcastInfo()
            // A display showing nothing in motion produces no frames, which would leave viewers
            // looking at the display they just switched away from.
            try? await Task.sleep(for: .milliseconds(400))
            nudge()
        } catch {
            Log.error("display switch failed: \(error)")
        }
    }

    /// Changes how much of the panel's detail is actually sent.
    ///
    /// The default trades pixels for latency, which is the right call over a phone link, but it is
    /// the wrong call when the point is to read something. Zero means the panel's own resolution.
    func setMaxWidth(_ requested: Int) async {
        guard captureReady else { return }
        let value = requested <= 0 ? 0 : max(320, requested)
        guard value != maxWidth else {
            broadcastInfo()
            return
        }

        guard beginSwitch() else { return }
        defer { endSwitch() }

        do {
            encoder.stop()
            discardLastFrame()
            try await capturer.setMaxWidth(value)
            try encoder.start(width: capturer.width, height: capturer.height,
                              fps: config.fps, bitrate: bitrate(for: capturer.width, capturer.height))
            maxWidth = value
            broadcastInfo()
            try? await Task.sleep(for: .milliseconds(400))
            nudge()
        } catch {
            Log.error("resolution change failed: \(error)")
            // Put the encoder back at whatever the capturer actually settled on, or the stream is
            // left dead rather than merely at the wrong size.
            try? encoder.start(width: capturer.width, height: capturer.height,
                               fps: config.fps, bitrate: bitrate(for: capturer.width, capturer.height))
            broadcastInfo()
        }
    }

    /// Keeps the display list current when monitors are plugged in or removed, and rescues the
    /// stream if the display being captured goes away.
    private func watchDisplayChanges() {
        let callback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
            guard let userInfo else { return }
            guard flags.contains(.addFlag) || flags.contains(.removeFlag)
                || flags.contains(.desktopShapeChangedFlag) else { return }
            let app = Unmanaged<Application>.fromOpaque(userInfo).takeUnretainedValue()
            Task { await app.refreshDisplays() }
        }
        CGDisplayRegisterReconfigurationCallback(callback, Unmanaged.passUnretained(self).toOpaque())
    }

    func refreshDisplays() async {
        guard captureReady else { return }
        guard let list = try? await ScreenCapturer.availableDisplays(), !list.isEmpty else { return }
        displays = list
        Log.info("display configuration changed: \(list.count) attached")

        if !list.contains(where: { $0.id == capturer.displayID }) {
            let fallback = list.first { $0.isMain } ?? list[0]
            Log.warn("captured display went away; falling back to \(fallback.name)")
            await switchDisplay(to: fallback.id)
            return
        }
        broadcastInfo()
    }

    // MARK: - Capture

    func capturer(_ capturer: ScreenCapturer, didCapture pixelBuffer: CVPixelBuffer, pts: CMTime) {
        statsLock.lock()
        framesCaptured += 1
        statsLock.unlock()

        frameLock.lock()
        lastPixelBuffer = pixelBuffer
        lastPixelBufferAt = pts
        frameLock.unlock()

        // Skip the encode entirely when nobody is watching; the capture stream stays warm so a
        // reconnecting client gets frames immediately instead of paying stream startup again.
        guard server.clientCount > 0 else { return }
        encoder.encode(pixelBuffer, pts: pts, captureEpochMs: epochMillis())
    }

    /// Encodes the screen as it stands, without waiting for it to change.
    ///
    /// ScreenCaptureKit only delivers a frame when something moves, which is what keeps an idle
    /// desktop from costing anything. The cost is that a client arriving at a still screen has
    /// nothing to decode and sits on a blank canvas — or worse, on the last picture of a display it
    /// is no longer watching. Re-sending the frame already in hand covers both.
    /// Drops the retained frame when it no longer matches the encoder's geometry.
    private func discardLastFrame() {
        frameLock.lock()
        lastPixelBuffer = nil
        frameLock.unlock()
    }

    private func nudge() {
        encoder.requestKeyframe()

        frameLock.lock()
        let buffer = lastPixelBuffer
        let pts = lastPixelBufferAt
        frameLock.unlock()

        guard let buffer, server.clientCount > 0 else { return }
        // Presentation timestamps have to keep climbing or the encoder rejects the frame.
        nudgeCount += 1
        let stamp = CMTimeAdd(pts, CMTime(value: CMTimeValue(nudgeCount), timescale: 600))
        encoder.encode(buffer, pts: stamp, captureEpochMs: epochMillis())
    }

    // MARK: - HTTP routes

    private func route(_ request: HTTPRequest, _ respond: @escaping (HTTPResponse) -> Void) {
        switch request.path {
        case "/":
            respond(clientPage())

        // Artwork and the manifest are unauthenticated for the same reason the page itself is:
        // they carry nothing, and the browser fetches the manifest without ever seeing the
        // fragment the token lives in.
        case "/manifest.webmanifest":
            respond(HTTPResponse(status: 200, contentType: "application/manifest+json",
                                 body: (try? JSONSerialization.data(withJSONObject: AppIcon.manifest()))
                                     ?? Data("{}".utf8),
                                 extraHeaders: ["Cache-Control": "public, max-age=3600"]))

        case "/icon.svg":
            respond(HTTPResponse(status: 200, contentType: "image/svg+xml",
                                 body: Data(AppIcon.svg.utf8),
                                 extraHeaders: ["Cache-Control": "public, max-age=86400"]))

        case let path where path.hasPrefix("/icon-") && path.hasSuffix(".png"):
            let digits = path.dropFirst("/icon-".count).dropLast(".png".count)
            guard let size = Int(digits), let png = AppIcon.png(size: size) else {
                return respond(.text("not found", status: 404))
            }
            respond(HTTPResponse(status: 200, contentType: "image/png", body: png,
                                 extraHeaders: ["Cache-Control": "public, max-age=86400"]))

        case "/health":
            respond(.json([
                "ok": true,
                "capturing": captureReady,
                "accessibility": Permissions.hasAccessibility(prompt: false),
                "width": capturer.width,
                "height": capturer.height,
                "fps": config.fps,
                "clients": server.clientCount,
                "inputEnabled": config.allowInput,
                "displayID": capturer.displayID,
                "displayCount": displays.count,
            ]))

        case "/displays":
            guard authorized(request) else { return respond(.text("unauthorized", status: 401)) }
            Task {
                let list = (try? await ScreenCapturer.availableDisplays()) ?? self.displays
                self.displays = list
                let encoded = (try? JSONEncoder().encode(list)) ?? Data("[]".utf8)
                respond(HTTPResponse(status: 200, contentType: "application/json", body: encoded))
            }

        case "/screenshot":
            guard authorized(request) else { return respond(.text("unauthorized", status: 401)) }
            guard captureReady else { return respond(.text("capture unavailable", status: 503)) }
            // Agents can grab any display without disturbing what a human viewer is watching.
            let target = request.query["display"].flatMap { UInt32($0) }
            Task {
                do {
                    guard let buffer = try await self.capturer.screenshot(displayID: target),
                          let jpeg = self.jpegData(from: buffer) else {
                        return respond(.text("capture failed", status: 500))
                    }
                    respond(HTTPResponse(status: 200, contentType: "image/jpeg", body: jpeg))
                } catch {
                    respond(.text("capture failed: \(error)", status: 500))
                }
            }

        case "/command":
            guard authorized(request) else { return respond(.text("unauthorized", status: 401)) }
            guard config.allowInput else { return respond(.text("input disabled", status: 403)) }
            guard let command = try? JSONDecoder().decode(InputCommand.self, from: request.body) else {
                return respond(.json(["ok": false, "error": "bad command"], status: 400))
            }
            injector?.handle(command)
            respond(.json(["ok": true]))

        default:
            respond(.text("not found", status: 404))
        }
    }

    private func authorized(_ request: HTTPRequest) -> Bool {
        request.query["token"] == config.token
    }

    private func clientPage() -> HTTPResponse {
        guard let url = clientURL(), let template = try? String(contentsOf: url, encoding: .utf8) else {
            return .text("client/index.html not found", status: 500)
        }
        // The token is deliberately not substituted in. The page is an empty shell that reads the
        // token from the fragment, so the secret never appears in a response body or a cache.
        return HTTPResponse(status: 200, contentType: "text/html; charset=utf-8",
                            body: Data(template.utf8))
    }

    /// Read from disk on every request so the browser client can be edited and reloaded without
    /// rebuilding, which matters because rebuilding changes the cdhash and resets TCC approval.
    private func clientURL() -> URL? {
        if let override = config.clientPath {
            return URL(fileURLWithPath: override)
        }
        if let resources = Bundle.main.resourceURL {
            let candidate = resources.appendingPathComponent("client/index.html")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func jpegData(from pixelBuffer: CVPixelBuffer, quality: Double = 0.8) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ciContext.jpegRepresentation(of: image, colorSpace: space, options: [key: quality])
    }

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.statsLock.lock()
            let captured = self.framesCaptured
            let encoded = self.framesEncoded
            let avg = self.framesEncoded > 0 ? self.encodeMillisTotal / Double(self.framesEncoded) : 0
            self.framesCaptured = 0
            self.framesEncoded = 0
            self.encodeMillisTotal = 0
            self.statsLock.unlock()
            guard captured > 0 || encoded > 0 else { return }
            Log.info(String(format: "captured %d/s  encoded %d/s  capture→encoded %.1fms  clients %d",
                            captured / 5, encoded / 5, avg, self.server.clientCount))
        }
        timer.resume()
        statsTimer = timer
    }

    private var statsTimer: DispatchSourceTimer?
}

extension Application: MenuBarDelegate {
    func menuBarState() -> MenuBarState {
        let active = displays.first { $0.id == capturer.displayID }
        return MenuBarState(url: publicURL(),
                            networkEnabled: config.bindHost != "127.0.0.1",
                            capturing: captureReady,
                            accessibility: Permissions.hasAccessibility(prompt: false),
                            viewers: server.clientCount,
                            fingerprint: certificateFingerprint,
                            displayName: active?.name ?? "your screen",
                            devices: devices.approved,
                            tunnel: tunnel.state,
                            tunnelInstalled: TunnelController.isInstalled)
    }

    func menuBarResolvePairing(requestId: String, approved: Bool) {
        resolvePairing(requestId: requestId, approved: approved)
    }

    func menuBarRevokeDevice(_ deviceId: String) {
        revoke(deviceId: deviceId)
    }

    func menuBarRevokeAllDevices() {
        revokeAllDevices()
    }

    /// Turning the tunnel on pulls the server back to loopback.
    ///
    /// cloudflared connects locally, so nothing needs to be listening on the network, and a socket
    /// that is not there cannot be reached by anything on the same wifi. It also means no
    /// certificate: Cloudflare presents a real one at their edge, which is what removes the warning
    /// screen the self-signed certificate causes.
    func menuBarSetTunnel(_ enabled: Bool) {
        guard enabled else {
            tunnel.stop()
            return
        }
        rebind(host: "127.0.0.1", tls: false)
        tunnel.start(localPort: config.port)
    }

    func menuBarSetNetworkAccess(_ enabled: Bool) {
        // The two are alternatives, and leaving a LAN socket open behind a tunnel would widen the
        // exposure for nothing.
        if enabled, tunnel.isActive { tunnel.stop() }
        guard enabled else { return rebind(host: "127.0.0.1", tls: false) }
        guard let address = NetworkInterfaces.primaryIPv4() else {
            Log.warn("no local network address available; staying on this Mac only")
            return
        }
        // TLS is not optional off loopback. Everything this app carries is sensitive.
        rebind(host: address, tls: true)
    }

    /// Resets the link only. Devices already approved stay approved, because rotating is for a
    /// link that got out, not for the devices you meant to let in; revoking those is separate and
    /// deliberate.
    func menuBarRotateToken() {
        config.token = Config.randomToken()
        server.rotateToken(to: config.token)
        Log.info("link reset; previously shared URLs no longer work")
    }
}
