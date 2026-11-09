// main.swift — iKnowViewer, a one-window launch shell for server.py.
//
// macOS grants Full Disk Access per program, not per folder. The viewer server
// needs the live stores (~/Library/IntelligencePlatform, ~/Library/Biome,
// ~/Library/Messages/chat.db), so the grant goes to this app; the Python
// process it launches inherits it. Granting the same access to a terminal
// would hand it to every command run from that terminal instead.
//
// The app does nothing clever: it starts `uv run python server.py` in the repo
// baked into Info.plist, pipes both output streams into a scroll view, and
// mirrors them to ~/Library/Logs/iKnowViewer.log so a run can be checked with
// no screen. Closing the window quits the app and stops the server.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let linkPattern = "http://127\\.0\\.0\\.1:[0-9]+/\\?token=[A-Za-z0-9_-]+"

    private var window: NSWindow!
    private var textView: NSTextView!
    private var copyButton: NSButton!
    private var statusLabel: NSTextField!

    private var server: Process?
    private var output = ""
    private var currentLink: String?
    private var logHandle: FileHandle?
    private let linkRegex = try? NSRegularExpression(pattern: AppDelegate.linkPattern)

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        prepareLog()
        openWindow()
        startServer()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopServer()
        logHandle?.closeFile()
        logHandle = nil
    }

    // MARK: - UI

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit iKnow Viewer",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "iKnow"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 280)

        let content = window.contentView!

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 400))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true

        let copy = NSButton(title: "Copy Link", target: self, action: #selector(copyLink(_:)))
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.bezelStyle = .rounded
        copy.isEnabled = false

        let status = NSTextField(labelWithString: "starting…")
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        content.addSubview(scroll)
        content.addSubview(bar)
        bar.addSubview(copy)
        bar.addSubview(status)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),

            copy.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            copy.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            status.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        self.window = window
        self.textView = text
        self.copyButton = copy
        self.statusLabel = status
    }

    private func openWindow() {
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Log

    private func prepareLog() {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        let file = logs.appendingPathComponent("iKnowViewer.log", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            // Truncate the previous run so the file always describes this start.
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw NSError(domain: "iKnowViewer", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "cannot create \(file.path)",
                ])
            }
            logHandle = try FileHandle(forWritingTo: file)
        } catch {
            append("  cannot write \(file.path) — \(error.localizedDescription)\n")
            return
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        append("  iKnowViewer started \(stamp)\n")
        append("  repo: \(bakedInfo("IKRepoPath") ?? "missing from Info.plist")\n")
        append("  uv:   \(bakedInfo("IKUVPath") ?? "missing from Info.plist")\n")
    }

    private func writeLog(_ text: String) {
        guard let handle = logHandle, let data = text.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // Losing the log is worth one line in the window, not a crash.
            logHandle = nil
            append("  (log write failed: \(error.localizedDescription))\n")
        }
    }

    // MARK: - Server

    private func bakedInfo(_ key: String) -> String? {
        return Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    private func startServer() {
        guard let repoPath = bakedInfo("IKRepoPath"), !repoPath.isEmpty else {
            append("\n  IKRepoPath is missing from the app's Info.plist.\n" +
                   "  Rebuild with scripts/build-app.sh.\n")
            statusLabel.stringValue = "not started: no baked repo path"
            return
        }
        guard let uvPath = bakedInfo("IKUVPath"), !uvPath.isEmpty else {
            append("\n  IKUVPath is missing from the app's Info.plist.\n" +
                   "  Rebuild with scripts/build-app.sh.\n")
            statusLabel.stringValue = "not started: no baked uv path"
            return
        }
        guard FileManager.default.isExecutableFile(atPath: uvPath) else {
            append("\n  cannot start the server: uv is not executable at\n  \(uvPath)\n" +
                   "  Install uv or rebuild with scripts/build-app.sh.\n")
            statusLabel.stringValue = "not started: uv missing"
            return
        }
        let serverScript = (repoPath as NSString).appendingPathComponent("server.py")
        guard FileManager.default.fileExists(atPath: serverScript) else {
            append("\n  cannot start the server: no server.py in\n  \(repoPath)\n" +
                   "  The app was built against a directory that has since moved.\n" +
                   "  Rebuild with scripts/build-app.sh.\n")
            statusLabel.stringValue = "not started: server.py missing"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", "python", "server.py"]
        process.currentDirectoryURL = URL(fileURLWithPath: repoPath)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/Users/cristos/.local/bin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        attach(outPipe.fileHandleForReading)
        attach(errPipe.fileHandleForReading)

        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                self?.append("\n  [server exited with status \(finished.terminationStatus)]\n")
                self?.statusLabel.stringValue = "server exited (\(finished.terminationStatus))"
            }
        }

        do {
            try process.run()
        } catch {
            append("\n  cannot start \(uvPath): \(error.localizedDescription)\n")
            statusLabel.stringValue = "not started: launch failed"
            return
        }

        server = process
        statusLabel.stringValue = "server starting…"
    }

    private func attach(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] source in
            let data = source.availableData
            if data.isEmpty {
                source.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async {
                self?.append(String(decoding: data, as: UTF8.self))
            }
        }
    }

    private func stopServer() {
        guard let process = server, process.isRunning else { return }
        process.terminate() // SIGTERM; server.py turns it into a clean exit

        var waited = 0.0
        while process.isRunning && waited < 3.0 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 0.1
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    // MARK: - Output

    private func append(_ text: String) {
        output += text

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        textView.textStorage?.append(NSAttributedString(string: text, attributes: attributes))
        writeLog(text)
        textView.scrollToEndOfDocument(nil)
        updateCopyButton()
    }

    private func updateCopyButton() {
        guard let regex = linkRegex else {
            statusLabel.stringValue = "link pattern failed to compile"
            copyButton.isEnabled = false
            return
        }
        let text = output as NSString
        let matches = regex.matches(in: output, options: [],
                                    range: NSRange(location: 0, length: text.length))
        guard let last = matches.last else { return }
        let link = text.substring(with: last.range)
        guard link != currentLink else { return }
        currentLink = link
        copyButton.isEnabled = true
        statusLabel.stringValue = "link ready — Copy Link, then open it in a browser"
    }

    @objc private func copyLink(_ sender: Any?) {
        guard let link = currentLink else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        statusLabel.stringValue = "link copied"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
