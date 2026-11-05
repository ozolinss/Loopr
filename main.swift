import Cocoa
import ApplicationServices

let kMarker: Int64 = 0x7454_6173 // tags events we post so we don't record them

struct Step { let t: Double; let ev: CGEvent }

final class Recorder: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var recBtn: NSButton!, playBtn: NSButton!, loopBtn: NSButton!
    var speedPop: NSPopUpButton!
    var status: NSTextField!
    var tap: CFMachPort?
    var steps: [Step] = []
    var recording = false, playing = false
    var recStart: Double = 0
    var playThread: Thread?

    func applicationDidFinishLaunching(_ n: Notification) {
        buildUI()
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            setStatus("Allow in System Settings → Privacy → Accessibility, then reopen")
        }
        startTap()
    }

    // MARK: UI
    func button(_ symbol: String, _ tip: String, _ sel: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
        let b = NSButton(image: img, target: self, action: sel)
        b.bezelStyle = .texturedRounded
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 38).isActive = true
        return b
    }

    func buildUI() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 74),
                        styleMask: [.titled, .closable, .miniaturizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "Loopr"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        let open = button("folder", "Open macro", #selector(openMacro))
        let save = button("square.and.arrow.down", "Save macro", #selector(saveMacro))
        recBtn = button("record.circle", "Record / Stop (F8)", #selector(toggleRecord))
        recBtn.contentTintColor = .systemRed
        playBtn = button("play.fill", "Play / Stop (F10)", #selector(togglePlay))
        loopBtn = button("repeat", "Loop playback", #selector(noop))
        loopBtn.setButtonType(.pushOnPushOff)
        speedPop = NSPopUpButton(frame: .zero, pullsDown: false)
        speedPop.addItems(withTitles: ["0.5×", "1×", "2×", "4×", "10×"])
        speedPop.selectItem(at: 1)
        speedPop.toolTip = "Playback speed"

        let row = NSStackView(views: [open, save, recBtn, playBtn, loopBtn, speedPop])
        row.spacing = 6
        status = NSTextField(labelWithString: "Ready — F8 record, F10 play")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let col = NSStackView(views: [row, status])
        col.orientation = .vertical
        col.alignment = .leading
        col.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        panel.contentView = col
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func noop() {}
    func setStatus(_ s: String) { DispatchQueue.main.async { self.status.stringValue = s } }

    // MARK: Event tap
    func startTap() {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
                                    .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        var mask: CGEventMask = 0
        for t in types { mask |= 1 << t.rawValue }
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: { _, type, ev, info in
            let r = Unmanaged<Recorder>.fromOpaque(info!).takeUnretainedValue()
            r.handle(type, ev)
            return Unmanaged.passUnretained(ev)
        }, userInfo: me)
        guard let tap else {
            setStatus("No permission — enable Accessibility & Input Monitoring, reopen")
            return
        }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func handle(_ type: CGEventType, _ ev: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return
        }
        if ev.getIntegerValueField(.eventSourceUserData) == kMarker { return }
        if type == .keyDown {
            let code = ev.getIntegerValueField(.keyboardEventKeycode)
            if code == 100 { DispatchQueue.main.async { self.toggleRecord() }; return } // F8
            if code == 109 { DispatchQueue.main.async { self.togglePlay() }; return }   // F10
            if code == 53 && playing { DispatchQueue.main.async { self.stopPlay() }; return } // Esc
        }
        if (type == .keyUp) {
            let code = ev.getIntegerValueField(.keyboardEventKeycode)
            if code == 100 || code == 109 { return }
        }
        guard recording else { return }
        // skip clicks on our own window
        if type != .keyDown && type != .keyUp && type != .flagsChanged && type != .mouseMoved {
            let p = ev.location
            let h = NSScreen.screens.first?.frame.height ?? 0
            if panel.frame.contains(NSPoint(x: p.x, y: h - p.y)) { return }
        }
        if let copy = ev.copy() {
            steps.append(Step(t: ProcessInfo.processInfo.systemUptime - recStart, ev: copy))
        }
    }

    // MARK: Record / Play
    @objc func toggleRecord() {
        if playing { return }
        if recording {
            recording = false
            recBtn.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
            setStatus(String(format: "Recorded %d events (%.1fs)", steps.count, steps.last?.t ?? 0))
        } else {
            steps = []
            recStart = ProcessInfo.processInfo.systemUptime
            recording = true
            recBtn.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
            setStatus("● Recording… press F8 or click to stop")
        }
    }

    @objc func togglePlay() {
        if recording { return }
        if playing { stopPlay(); return }
        guard !steps.isEmpty else { setStatus("Nothing recorded yet"); return }
        guard AXIsProcessTrusted() else { setStatus("Can't play: turn on Accessibility for Loopr, reopen"); return }
        playing = true
        panel.ignoresMouseEvents = true
        playBtn.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        let speeds = [0.5, 1, 2, 4, 10]
        let speed = speeds[max(0, speedPop.indexOfSelectedItem)]
        let loop = loopBtn.state == .on
        let seq = steps
        setStatus("▶ Playing… F10 or Esc to stop")
        playThread = Thread { [weak self] in
            var round = 1
            repeat {
                let start = ProcessInfo.processInfo.systemUptime
                for s in seq {
                    guard let self, self.playing else { return }
                    let wait = s.t / speed - (ProcessInfo.processInfo.systemUptime - start)
                    Thread.sleep(forTimeInterval: max(wait, 0.002))
                    guard self.playing, let e = s.ev.copy() else { return }
                    e.setIntegerValueField(.eventSourceUserData, value: kMarker)
                    e.post(tap: .cghidEventTap)
                }
                round += 1
                if loop { self?.setStatus("▶ Loop \(round)… F10 or Esc to stop") }
            } while loop && (self?.playing ?? false)
            DispatchQueue.main.async { self?.stopPlay() }
        }
        playThread?.start()
    }

    func stopPlay() {
        playing = false
        panel.ignoresMouseEvents = false
        playBtn.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        setStatus("Stopped — \(steps.count) events loaded")
    }

    // MARK: Save / Open
    @objc func saveMacro() {
        guard !steps.isEmpty else { setStatus("Nothing to save"); return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "macro.loopr"
        guard p.runModal() == .OK, let url = p.url else { return }
        let arr: [[String: Any]] = steps.compactMap { s in
            guard let d = s.ev.data as Data? else { return nil }
            return ["t": s.t, "e": d.base64EncodedString()]
        }
        do { try JSONSerialization.data(withJSONObject: arr).write(to: url); setStatus("Saved \(url.lastPathComponent)") }
        catch { setStatus("Save failed: \(error.localizedDescription)") }
    }

    @objc func openMacro() {
        let p = NSOpenPanel()
        guard p.runModal() == .OK, let url = p.url,
              let d = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return }
        steps = arr.compactMap { o in
            guard let t = o["t"] as? Double, let b = o["e"] as? String, let raw = Data(base64Encoded: b),
                  let ev = CGEvent(withDataAllocator: nil, data: raw as CFData) else { return nil }
            return Step(t: t, ev: ev)
        }
        setStatus("Loaded \(steps.count) events from \(url.lastPathComponent)")
    }

    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply { playing ? .terminateCancel : .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool { panel.makeKeyAndOrderFront(nil); return true }
}

let app = NSApplication.shared
let delegate = Recorder()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
