import AppKit
import Foundation

/// Runs a Cloudflare quick tunnel in front of the local server, and keeps one alive.
///
/// This is how the phone reaches the Mac from outside the house. cloudflared dials out to
/// Cloudflare and traffic comes back down that connection, so no port is opened on the router and
/// nothing is exposed on the local network either — the server can stay on loopback.
///
/// It is worth being clear about the cost. The hostname is public, so the approval gate at the Mac
/// is the thing standing between a stranger who guesses the link and the desktop. Cloudflare also
/// terminates TLS at their edge, which means the screen and the keystrokes are visible to them in a
/// way they are not on the local network.
///
/// Keeping it alive is as much of the job as starting it. A quick tunnel is not durable: the Mac
/// sleeps, the wifi changes, and Cloudflare eventually discards a registration nobody is using.
/// cloudflared answers by retrying the tunnel it was given — which is hopeless once that tunnel is
/// gone from their side, and it will retry for as long as you let it. The process never exits, so
/// from in here nothing looks broken at all. That is how this came to offer a QR code for a hostname
/// that had answered nothing for twelve hours.
///
/// So the link is checked rather than assumed. Nothing is shown as reachable until a request has
/// actually come back through it, and a link that stops answering is torn down and replaced rather
/// than waited on. The only thing that stops that is the person at the Mac switching it off.
final class TunnelController {
    enum State: Equatable {
        case off
        /// No link worth handing out yet. The text says why, in words the menu can show.
        case connecting(String)
        /// A public base URL that answered a request from here within the last interval.
        case running(String)
        /// Needs a person before anything else can happen: cloudflared is not there to run.
        case failed(String)
    }

    /// Searched by hand because the app is started by launchd, which does not carry a login shell's
    /// PATH, so a bare `cloudflared` would not be found.
    private static let searchPaths = [
        "/opt/homebrew/bin/cloudflared",
        "/usr/local/bin/cloudflared",
        "/usr/bin/cloudflared",
    ]

    static var executable: String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { executable != nil }

    /// How often the link is asked whether it still works.
    private static let checkInterval: TimeInterval = 15
    /// How long a link that has been working is given to recover on its own before it is replaced.
    /// Long enough to ride out a wifi hiccup, short enough that a Mac woken up is reachable again by
    /// the time anybody thinks to open the menu.
    private static let graceInterval: TimeInterval = 45
    /// How long a link that has never answered is given to start — much longer, because it is a
    /// different situation. cloudflared's own banner says a fresh hostname may take some time to be
    /// reachable, and on a network where QUIC is blocked it has taken over a minute to register and
    /// most of another to route. Replacing one before it has had its chance builds a loop that
    /// produces nothing but tunnels, none of which ever gets far enough to work.
    private static let startupGrace: TimeInterval = 150
    /// cloudflared prints the address within seconds of starting. Much past this it never will.
    private static let addressTimeout: TimeInterval = 40
    /// Floor between checks, so a burst of retry lines out of cloudflared cannot become a burst of
    /// requests through a tunnel that is already struggling.
    private static let checkFloor: TimeInterval = 5
    /// How long to leave a newly assigned address alone before asking it anything.
    ///
    /// This is not politeness, it is the difference between working and not. cloudflared prints the
    /// hostname before it exists in DNS, and asking too early does lasting damage: the resolver on
    /// this machine caches the NXDOMAIN it gets back and keeps serving it long after the name is
    /// real. Measured — a name queried a second after it was printed stayed unresolvable here for
    /// over eighty seconds while 1.1.1.1 had been answering for sixty of them; the same name left
    /// alone for twenty-five seconds answered on the first request. An eager first check was
    /// therefore poisoning every link it was meant to be verifying.
    private static let firstCheckDelay: TimeInterval = 20

    /// What to try carrying the tunnel over, in order.
    ///
    /// Left alone, cloudflared reaches for QUIC and keeps reaching for it. That is the right instinct
    /// until the network in front of it will not carry QUIC, and then it is a trap: on the network
    /// this was written on, a tunnel registered and dropped every six seconds for as long as it was
    /// allowed to, while the identical tunnel over HTTP/2 held without a single retry. No amount of
    /// cloudflared's own retrying escapes that, because retrying is not the thing that is wrong. So
    /// the transport is part of what gets replaced, not a setting decided once at the start.
    private static let transports = ["auto", "http2"]

    /// Every mutation happens here, which is what lets the process, the parse buffer and the
    /// bookkeeping below be plain properties rather than a lock apiece.
    private let queue = DispatchQueue(label: "screenlink.tunnel")
    /// Covers only what is read from outside: the state the menu draws, and the intent it ticks.
    private let lock = NSLock()
    private var _state: State = .off
    private var _wantsRunning = false

    private var process: Process?
    private var pipe: Pipe?
    /// cloudflared's output arrives in whatever sized pieces the pipe hands over, so a line can be
    /// split across two of them — including the one line that carries the address.
    private var partialLine = ""
    /// The address cloudflared handed back. Not trusted until something comes back through it.
    private var address: String?
    private var localPort: UInt16 = 0
    private var launchedAt: Date?
    private var relaunchPending = false
    private var unreachableSince: Date?
    /// Whether *this* link has ever answered — reset for each one, not remembered across them. A
    /// replacement is a brand new quick tunnel with a brand new hostname, and it needs the same
    /// runway the first one got. Carrying the flag over meant the second tunnel was given the
    /// forty-five seconds meant for a link that had been working, and was killed at seventy.
    private var linkAnswered = false
    /// Consecutive replacements with no working link in between, which is the thing worth backing
    /// off on: a Mac with no internet would otherwise start a cloudflared every fifteen seconds.
    private var replacements = 0
    private var transportIndex = 0
    private var currentTransport = TunnelController.transports[0]
    /// Set aside for the next launch when something has been learned that outranks the rotation.
    private var nextTransport: String?
    /// The transport that last carried a working link. Kept, because whatever the network objects to
    /// it will go on objecting to, and dropped again the moment it stops working — a network that
    /// changed under us has no reason to keep the answer that suited the old one.
    private var provenTransport: String?
    private var timer: DispatchSourceTimer?
    private var checking = false
    private var checkArmed = false
    private var lastCheckAt = Date.distantPast
    private var checkNotBefore = Date.distantPast
    private var lastCheckReason = ""
    private var wakeObservers: [NSObjectProtocol] = []

    /// Repeats are counted rather than written. cloudflared put 26,203 identical retry lines into
    /// one log while failing to notice its tunnel was gone, and they buried everything else in it.
    private var lastLoggedLine = ""
    private var suppressedLines = 0

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    var onStateChange: ((State) -> Void)?

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    /// What the person at the Mac asked for, as opposed to what is currently true. Everything the
    /// supervisor does is in service of making the second match the first, so the menu checkmark
    /// follows this — otherwise it would blink off every time a link was being replaced.
    private(set) var wantsRunning: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _wantsRunning }
        set { lock.lock(); _wantsRunning = newValue; lock.unlock() }
    }

    var isActive: Bool { wantsRunning }

    init() {
        watchForWake()
    }

    // MARK: - What the person at the Mac asked for

    func start(localPort: UInt16) {
        // Set outside the hop, so the menu reflects the decision the moment it is made rather than
        // whenever the queue gets round to it.
        wantsRunning = true
        queue.async {
            guard self.wantsRunning else { return }
            self.localPort = localPort
            self.replacements = 0
            self.kill()
            self.launch()
            self.startTimer()
        }
    }

    func stop() {
        wantsRunning = false
        queue.async {
            self.stopTimer()
            self.kill()
            self.address = nil
            self.unreachableSince = nil
            self.transition(.off)
        }
    }

    // MARK: - Supervision

    private func startTimer() {
        stopTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard wantsRunning, !relaunchPending else { return }

        guard let process, process.isRunning else {
            // The termination handler normally gets here first. This covers a process that went away
            // without it, which is the version of this failure that leaves the menu offering a link
            // with no cloudflared behind it at all.
            return replace(because: "cloudflared is not running")
        }

        guard address != nil else {
            guard let launchedAt, Date().timeIntervalSince(launchedAt) > Self.addressTimeout else { return }
            return replace(because: "Cloudflare never handed back an address")
        }

        requestCheck()
    }

    /// One check at a time, and never more often than the floor.
    ///
    /// A request that arrives at a bad moment is deferred rather than dropped, because the one that
    /// gets dropped is invariably the interesting one: cloudflared announcing that it has this
    /// second reconnected, which is exactly when the answer is about to change.
    private func requestCheck() {
        guard wantsRunning, address != nil, !checkArmed else { return }
        checkArmed = true
        let sinceLast = checking ? Self.checkFloor
                                 : max(0, Self.checkFloor - Date().timeIntervalSince(lastCheckAt))
        let wait = max(sinceLast, checkNotBefore.timeIntervalSinceNow)
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            checkArmed = false
            guard wantsRunning, let address else { return }
            guard !checking else { return requestCheck() }
            check(address)
        }
    }

    /// Asks the public address, from here, whether it still reaches this Mac.
    ///
    /// Going out through Cloudflare and back is the only question worth asking. cloudflared's own
    /// account of itself is what was believed before, and it was wrong for half a day: it reported a
    /// tunnel it was busy reconnecting to, which Cloudflare had already thrown away.
    private func check(_ base: String) {
        guard let url = URL(string: base + "/health") else { return }
        checking = true
        lastCheckAt = Date()

        session.dataTask(with: URLRequest(url: url)) { [weak self] data, response, error in
            guard let self else { return }
            // A 200 carrying this server's own health JSON, and nothing less. Cloudflare answers for
            // a tunnel it has lost with a perfectly well-formed error page of its own.
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let status = (response as? HTTPURLResponse)?.statusCode
            let reachable = status == 200 && body?["ok"] as? Bool == true

            let why: String
            if reachable { why = "ok" }
            else if let error { why = (error as NSError).localizedDescription }
            else if let status { why = "answered HTTP \(status)" }
            else { why = "no response" }

            queue.async {
                self.checking = false
                self.noteCheck(why)
                self.settle(reachable: reachable, base: base)
            }
        }.resume()
    }

    /// Says why the link is not answering, once per distinct reason.
    ///
    /// A link that will not come up is the hardest thing here to explain after the fact, and the
    /// difference between a name that does not resolve, a timeout, and Cloudflare's own error page
    /// is the whole diagnosis. Repeating it every fifteen seconds would bury it, so it is written
    /// when it changes and not otherwise.
    private func noteCheck(_ why: String) {
        guard why != lastCheckReason else { return }
        lastCheckReason = why
        guard why != "ok" else { return }
        Log.info("internet link not answering yet: \(why)")
    }

    private func settle(reachable: Bool, base: String) {
        // An answer about a link that has since been replaced says nothing about the one in hand.
        guard wantsRunning, address == base else { return }

        if reachable {
            if !linkAnswered { Log.info("internet link answering over \(currentTransport): \(base)") }
            linkAnswered = true
            provenTransport = currentTransport
            unreachableSince = nil
            replacements = 0
            transition(.running(base))
            return
        }

        let since = unreachableSince ?? Date()
        unreachableSince = since
        // The code comes down the moment the link stops answering. A QR that leads nowhere is worse
        // than no QR at all: it gets scanned, it fails, and nothing on screen explains why.
        transition(.connecting(linkAnswered
            ? "The link stopped answering. Rebuilding it — the address will change."
            : "Waiting for Cloudflare to start routing the new address."))

        let allowance = linkAnswered ? Self.graceInterval : Self.startupGrace
        guard Date().timeIntervalSince(since) >= allowance else { return }
        replace(because: "no answer through the link for \(Int(allowance))s")
    }

    /// Throws the tunnel away and asks for a new one.
    ///
    /// Restarting cloudflared against the same quick tunnel is not on offer, because there is no
    /// handle on a quick tunnel to restart against — Cloudflare allocates one per process. That is
    /// also why waiting does not work: once the registration is gone, no amount of retrying can
    /// bring it back, and every recovery that ever worked here was a fresh process. The cost is a
    /// new hostname, so a link somebody saved stops working — but it had already stopped working,
    /// which is the whole reason for being here.
    private func replace(because reason: String) {
        guard wantsRunning else { return }
        kill()
        address = nil
        unreachableSince = nil
        replacements += 1

        // One bad link is not evidence against the transport that built it — anything can drop once.
        // Two in a row is, so the transport goes back into the rotation and gets tried afresh.
        if replacements >= 2 { provenTransport = nil }
        if provenTransport == nil, nextTransport == nil { transportIndex += 1 }

        let delay = min(Double(replacements - 1) * 10, 60)
        let when = delay > 0 ? "in \(Int(delay))s" : "now"
        Log.warn("internet link: \(reason); building a new one \(when)")
        transition(.connecting(linkAnswered
            ? "The link stopped answering. Building a new one — the address will change."
            : "That address never started working. Trying another."))

        // Always deferred, even by nothing, so a cloudflared that cannot start at all unwinds
        // between attempts instead of recursing.
        relaunchPending = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            relaunchPending = false
            guard wantsRunning, process == nil else { return }
            launch()
        }
    }

    private func launch() {
        guard let executable = Self.executable else {
            // The one failure retrying cannot fix, so the supervision stops here rather than
            // spending the rest of the session announcing it every fifteen seconds.
            wantsRunning = false
            stopTimer()
            return transition(.failed("cloudflared is not installed"))
        }

        currentTransport = nextTransport ?? provenTransport
            ?? Self.transports[transportIndex % Self.transports.count]
        nextTransport = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // A quick tunnel needs no account and no domain: Cloudflare allocates a hostname and a
        // certificate for the life of the process. The address changes every time it starts, which
        // is a limitation worth knowing but also means a stale link stops working on its own.
        process.arguments = ["tunnel", "--no-autoupdate",
                             "--protocol", currentTransport,
                             "--url", "http://127.0.0.1:\(localPort)"]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            self?.queue.async { self?.absorb(text) }
        }

        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            queue.async {
                // Only the process still in hand is worth reacting to. One this class killed on
                // purpose has already been accounted for.
                guard self.process === finished, self.wantsRunning else { return }
                self.replace(because: "cloudflared exited with status \(finished.terminationStatus)")
            }
        }

        launchedAt = Date()
        partialLine = ""
        linkAnswered = false
        lastCheckReason = ""
        checkNotBefore = .distantPast
        transition(.connecting(replacements == 0
            ? "Waiting for Cloudflare to assign an address."
            : "Building a new link. The address will change."))

        do {
            try process.run()
            self.process = process
            self.pipe = pipe
            Log.info("internet link: cloudflared started over \(currentTransport)")
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            replace(because: "could not start cloudflared: \(error.localizedDescription)")
        }
    }

    /// Ends the current cloudflared, without letting it report anything on the way out.
    private func kill() {
        let running = process
        process = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        launchedAt = nil
        // Clearing these is not optional. Handlers left attached read a dead process's farewell
        // into the state of the live one that replaced it.
        running?.terminationHandler = nil
        running?.terminate()
    }

    // MARK: - Reading cloudflared

    private func absorb(_ text: String) {
        partialLine += text
        // Whatever follows the last newline is the beginning of a line that has not arrived yet.
        var lines = partialLine.components(separatedBy: "\n")
        partialLine = lines.removeLast()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            note(trimmed)
            interpret(trimmed)
        }
    }

    private func interpret(_ line: String) {
        guard address != nil else {
            guard let range = line.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#,
                                         options: .regularExpression) else { return }
            let assigned = String(line[range])
            self.address = assigned
            Log.info("internet link assigned: \(assigned)")
            // Not announced as running yet. Cloudflare takes a moment to start routing a hostname it
            // has only just allocated — it says so itself — and the check is what decides when it
            // has. That first check waits, for the resolver's sake as much as Cloudflare's.
            unreachableSince = Date()
            checkNotBefore = Date().addingTimeInterval(Self.firstCheckDelay)
            requestCheck()
            return
        }

        // cloudflared tests what the network can carry before it connects, and says so. In this
        // version it then goes ahead on QUIC regardless of its own finding, which is how a tunnel
        // ends up registering and dropping every six seconds. Taking the advice it gave itself turns
        // a two-and-a-half minute wait for the grace to expire into a few seconds. Only ever an
        // escalation, and never against a link that is already answering.
        if !linkAnswered, currentTransport != "http2", line.contains("suggested_protocol=http2") {
            nextTransport = "http2"
            provenTransport = nil
            return replace(because: "cloudflared's own pre-check says this network needs HTTP/2")
        }

        // It also knows about its own connections long before a check would notice, so its account
        // is worth having — as a reason to look, never as the answer. Losing one connection of
        // several is not the link going down, and only a request through it tells the difference.
        let worthLooking = ["Registered tunnel connection", "Retrying connection",
                            "Unregistered tunnel connection", "Serve tunnel error",
                            "failed to serve tunnel connection"]
        guard worthLooking.contains(where: line.contains) else { return }
        requestCheck()
    }

    /// Writes a cloudflared line, unless it is the same one again.
    private func note(_ line: String) {
        let normalized = line.replacingOccurrences(
            of: #"\d{4}-\d{2}-\d{2}T\S+|ip=\S+|connIndex=\S+|connection=\S+|in up to \S+"#,
            with: "", options: .regularExpression)
        guard normalized != lastLoggedLine else {
            suppressedLines += 1
            return
        }
        if suppressedLines > 0 {
            Log.info("cloudflared: (previous line repeated \(suppressedLines) more times)")
        }
        lastLoggedLine = normalized
        suppressedLines = 0
        Log.info("cloudflared: \(line)")
    }

    // MARK: - Sleep

    /// Waking is when a tunnel is most likely to be dead and least likely to know it, so it is worth
    /// asking straight away rather than waiting out an interval to find out.
    private func watchForWake() {
        let names: [NSNotification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ]
        let center = NSWorkspace.shared.notificationCenter
        for name in names {
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                queue.async {
                    guard self.wantsRunning, self.address != nil else { return }
                    // The floor is there to damp retry storms, and waking is not one.
                    self.lastCheckAt = .distantPast
                    self.requestCheck()
                }
            })
        }
    }

    private func transition(_ next: State) {
        lock.lock()
        let changed = _state != next
        _state = next
        lock.unlock()
        guard changed else { return }
        onStateChange?(next)
    }
}
