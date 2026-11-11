import AppKit
import SwiftUI
import Carbon
import UniformTypeIdentifiers

@MainActor final class HintBubble {
    static let shared = HintBubble()
    private var pending: DispatchWorkItem?
    private var window: NSPanel?
    func hide() { pending?.cancel(); pending = nil; window?.orderOut(nil); window = nil }
    func schedule(_ text: String, from view: NSView) {
        hide()
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, let owner = view.window, owner.isVisible else { return }
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11); label.textColor = .labelColor; label.sizeToFit()
            let size = NSSize(width: min(360, label.frame.width + 20), height: 30)
            let anchor = owner.convertToScreen(view.convert(view.bounds, to: nil))
            let visible = owner.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            let x = min(max(visible.minX+6, anchor.midX-size.width/2), visible.maxX-size.width-6)
            let y = min(anchor.maxY+7, visible.maxY-size.height-6)
            let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x:x,y:y), size:size), styleMask:[.borderless,.nonactivatingPanel], backing:.buffered, defer:false)
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
            panel.ignoresMouseEvents = true; panel.level = NSWindow.Level(rawValue: owner.level.rawValue+1)
            panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            let content = NSView(frame:NSRect(origin:.zero,size:size)); content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; content.layer?.cornerRadius = 8
            label.frame.origin = NSPoint(x:10,y:8); content.addSubview(label)
            panel.contentView = content; self.window = panel; panel.orderFrontRegardless()
        }
        pending = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.35, execute:work)
    }
}

final class HoverButton: NSButton {
    var hint = ""
    private var area: NSTrackingArea?
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func mouseDown(with event:NSEvent) {
        guard let window else { return }
        HintBubble.shared.hide(); highlight(isEnabled)
        defer { highlight(false) }
        while let next = window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp],until:.distantFuture,inMode:.eventTracking,dequeue:true) {
            if next.type == .leftMouseDragged {
                let dx = next.locationInWindow.x-event.locationInWindow.x
                let dy = next.locationInWindow.y-event.locationInWindow.y
                if hypot(dx,dy) > 4 {
                    highlight(false); (window as? LensPanel)?.beginDragging(with:event,current:next); return
                }
            } else {
                if isEnabled && bounds.contains(convert(next.locationInWindow,from:nil)) { performClick(nil) }
                return
            }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect:bounds, options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect], owner:self)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event:NSEvent) {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.045).cgColor
        HintBubble.shared.schedule(hint, from:self)
    }
    override func mouseExited(with event:NSEvent) { layer?.backgroundColor = .clear; HintBubble.shared.hide() }
}

struct IconButton: NSViewRepresentable {
    let symbol: String
    let label: String
    let help: String
    var enabled = true
    var menu:(()->NSMenu)? = nil
    let action: () -> Void
    final class Coordinator:NSObject {
        var action: () -> Void
        var menu:(()->NSMenu)?
        init(_ action:@escaping()->Void,menu:(()->NSMenu)?) { self.action = action; self.menu = menu }
        @MainActor @objc func click(_ sender:NSButton) {
            HintBubble.shared.hide()
            if let menu = menu?() { menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.maxY+5),in:sender) }
            else { action() }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action,menu:menu) }
    func makeNSView(context:Context) -> HoverButton {
        let button = HoverButton(frame:.zero)
        button.isBordered = false; button.imagePosition = .imageOnly
        button.wantsLayer = true; button.layer?.cornerRadius = 10
        button.target = context.coordinator; button.action = #selector(Coordinator.click(_:))
        button.setContentHuggingPriority(.defaultLow,for:.horizontal)
        return button
    }
    func updateNSView(_ button:HoverButton,context:Context) {
        context.coordinator.action = action; context.coordinator.menu = menu
        button.image = NSImage(systemSymbolName:symbol,accessibilityDescription:label)?.withSymbolConfiguration(.init(pointSize:14,weight:.medium))
        button.contentTintColor = NSColor(calibratedRed:0.16,green:0.20,blue:0.22,alpha:1)
        button.hint = help; button.isEnabled = enabled
        button.setAccessibilityLabel(label); button.setAccessibilityHelp(help)
    }
    static func dismantleNSView(_ view:HoverButton,coordinator:Coordinator) { HintBubble.shared.hide() }
}

enum PanelPage { case solution, history, settings, queue }

@MainActor final class LensState:ObservableObject {
    @Published var answer:Answer?
    @Published var batchAnswer:BatchAnswer?
    @Published var mode:CaptureMode = CaptureMode(rawValue:UserDefaults.standard.string(forKey:"captureMode") ?? "") ?? .instant
    @Published var pending:[PendingShot] = []
    let queue:QueueStore
    var retryBatch = false
    @Published var history:[HistoryEntry] = []
    @Published var selectedID:UUID?
    @Published var busy = false
    @Published var expanded = false { didSet { if oldValue != expanded { resize(animated:true) } } }
    @Published var page:PanelPage = .solution
    @Published var message = ""
    @Published var historyIssue = ""
    @Published var elapsed = 0
    @Published var progress:SolverProgress = .preparing
    var retryImage:Data?
    @Published var thumbnail:NSImage?
    @Published var preferences = UserDefaults.standard.string(forKey:"preferences") ?? ""
    @Published var codexPath = UserDefaults.standard.string(forKey:"codexPath") ?? ""
    @Published var reveal:CGFloat = 0
    @Published var panelWidth:CGFloat = 88
    @Published var panelHeight:CGFloat = 44
    let store:HistoryStore
    var panel:NSPanel!
    var targetScreen:NSScreen?
    var solver:Solver?
    var timer:Timer?
    var request = UUID()
    var capturing = false
    var selection:SelectionCoordinator?
    var imageDialog:NSOpenPanel?
    var expandedWidth:CGFloat = 422
    var expandedHeight:CGFloat = 267
    var anchor:CGPoint?
    var frameTimer:Timer?
    var applyingFrame = false
    var activeEntry:HistoryEntry? { history.first { $0.id == selectedID } }

    init(store:HistoryStore = HistoryStore(),queue:QueueStore = QueueStore()) {
        self.store = store; self.queue = queue
        do { pending = try queue.load() }
        catch { historyIssue = "Не удалось прочитать очередь снимков. Существующие файлы сохранены." }
        if mode == .batch { page = .queue }
        if let point = UserDefaults.standard.array(forKey:"panelAnchor") as? [Double], point.count == 2,
           point.allSatisfy({ $0.isFinite }) { anchor = CGPoint(x:point[0],y:point[1]) }
        if let size = UserDefaults.standard.array(forKey:"expandedSize") as? [Double],size.count == 2,size.allSatisfy({ $0.isFinite }) {
            expandedWidth = max(320,size[0]); expandedHeight = max(220,size[1])
        }
        do { history = try store.load() }
        catch { historyIssue = "Не удалось прочитать историю. Существующий файл сохранён без изменений." }
    }

    func resize(animated:Bool = false) {
        guard let panel else { return }
        frameTimer?.invalidate(); frameTimer = nil
        let savedScreen = anchor.flatMap { point in NSScreen.screens.first { $0.frame.contains(CGPoint(x:point.x-1,y:point.y+1)) } }
        guard let screen = savedScreen ?? targetScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        targetScreen = screen
        let area = screen.visibleFrame
        if expanded {
            if !panel.styleMask.contains(.resizable) { panel.styleMask.insert(.resizable) }
            panel.minSize = NSSize(width:320,height:220)
            panel.maxSize = NSSize(width:area.width-16,height:area.height-16)
        } else {
            if panel.styleMask.contains(.resizable) { panel.styleMask.remove(.resizable) }
            panel.minSize = NSSize(width:1,height:1)
        }
        expandedWidth = min(max(320,expandedWidth),area.width-16)
        expandedHeight = min(max(220,expandedHeight),area.height-16)
        let point = anchor ?? CGPoint(x:area.maxX-10,y:area.minY+12)
        let text = mode == .batch && !pending.isEmpty ? "\(pending.count) сним." : batchAnswer.map { $0.answerCountText } ?? (answer?.status == "ok" ? answer!.answer : "")
        let answerWidth = (text as NSString).size(withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:21,weight:.medium)]).width
        let compactWidth:CGFloat = busy ? 206 : (text.isEmpty ? (message.isEmpty ? 88 : 126) : max(130,ceil(answerWidth)+104))
        let size = CGSize(width:expanded ? expandedWidth : min(compactWidth,area.width-16),height:expanded ? expandedHeight : 44)
        let destination = PanelPlacement.frame(size:size,anchor:point,visible:area)
        let targetReveal:CGFloat = expanded ? 1 : 0
        let start = panel.frame, startReveal = reveal
        guard animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            applyFrame(destination,reveal:targetReveal); return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let clock = Timer(timeInterval:1.0/60.0,repeats:true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1,(ProcessInfo.processInfo.systemUptime-started)/0.32)
                let eased = CGFloat(t*t*(3-2*t))
                self.applyFrame(PanelPlacement.interpolate(start,destination,progress:eased),reveal:startReveal+(targetReveal-startReveal)*eased)
                if t >= 1 { timer.invalidate(); self.frameTimer = nil }
            }
        }
        frameTimer = clock; RunLoop.main.add(clock,forMode:.common)
    }
    private func applyFrame(_ frame:CGRect,reveal:CGFloat) {
        applyingFrame = true
        panelWidth = frame.width; panelHeight = frame.height; self.reveal = reveal
        panel.setFrame(frame,display:true)
        panel.contentView?.setFrameSize(frame.size)
        applyingFrame = false
    }
    func rememberPosition() {
        guard !applyingFrame,let panel else { return }
        anchor = CGPoint(x:panel.frame.maxX,y:panel.frame.minY); targetScreen = panel.screen
        UserDefaults.standard.set([Double(panel.frame.maxX),Double(panel.frame.minY)],forKey:"panelAnchor")
    }
    func rememberSize() {
        guard expanded,let panel,!applyingFrame else { return }
        expandedWidth = panel.frame.width; expandedHeight = panel.frame.height
        panelWidth = expandedWidth; panelHeight = expandedHeight
        UserDefaults.standard.set([Double(expandedWidth),Double(expandedHeight)],forKey:"expandedSize")
    }
    func prepareForDrag() { HintBubble.shared.hide(); panel.makeFirstResponder(nil); resize(animated:false) }
    func finishDrag() { rememberPosition(); resize(animated:false); rememberPosition() }
    func resetPosition() { anchor = nil; targetScreen = NSScreen.main; UserDefaults.standard.removeObject(forKey:"panelAnchor"); resize(animated:true) }
    func show() {
        if let imageDialog { imageDialog.makeKeyAndOrderFront(nil); return }
        guard let panel else { return }
        if !panel.isVisible { resize(animated:false); panel.alphaValue = 1 }
        panel.orderFrontRegardless()
    }
    func toggleExpanded() { HintBubble.shared.hide(); expanded.toggle() }
    func hide() { HintBubble.shared.hide(); panel.orderOut(nil) }
    func openHistory() { page = .history; expanded = true; show() }
    func choose(_ entry:HistoryEntry) {
        selectedID = entry.id; answer = entry.answer; batchAnswer = entry.batch; thumbnail = nil; message = ""
        page = .solution; expanded = true; resize(animated:true)
    }
    func select() {
        guard !busy,!capturing,selection == nil,imageDialog == nil else { return }
        hide()
        selection = SelectionCoordinator { [weak self] rect,screen in
            guard let self else { return }; self.selection = nil
            if let rect { self.capture(rect:rect) }
            else { self.show() }
        }
        selection?.begin()
    }
    func fullScreen() {
        guard !busy,!capturing,selection == nil,imageDialog == nil else { return }
        guard let screen = NSScreen.screens.first(where:{ $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        capture(rect:CGRect(x:screen.frame.minX,y:top-screen.frame.maxY,width:screen.frame.width,height:screen.frame.height))
    }
    func capture(rect:CGRect) {
        guard !busy,!capturing,imageDialog == nil else { return }
        message = ""
        if mode == .instant { answer = nil; batchAnswer = nil; selectedID = nil; thumbnail = nil; page = .solution }
        else { page = .queue }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            message = "Разрешите запись экрана для Lens в настройках macOS, затем повторите захват."
            expanded = true; show(); return
        }
        capturing = true; hide()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Lens-capture-\(UUID().uuidString).png")
            let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
            p.arguments = ["-x","-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))",file.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do {
                try p.run(); p.waitUntilExit()
                guard p.terminationStatus == 0,FileManager.default.fileExists(atPath:file.path) else { throw LensError.message("Захват не удался. Проверьте разрешение записи экрана.") }
                self.capturing = false; self.receive(file:file,removeAfter:true)
            } catch {
                self.capturing = false; try? FileManager.default.removeItem(at:file)
                self.message = error.localizedDescription; self.expanded = true; self.show()
            }
        }
    }
    func openImage() {
        if let imageDialog { NSApp.activate(ignoringOtherApps:true); imageDialog.makeKeyAndOrderFront(nil); return }
        guard !busy,!capturing,selection == nil else { return }
        HintBubble.shared.hide()
        let dialog = NSOpenPanel(); dialog.allowedContentTypes = [.png,.jpeg,.webP,.tiff]
        dialog.allowsMultipleSelection = mode == .batch
        dialog.canChooseFiles = true; dialog.canChooseDirectories = false
        imageDialog = dialog
        // Release the nonactivating panel's keyboard focus, then leave button/menu tracking
        // before presenting the system file picker as an active application's window.
        panel.makeFirstResponder(nil); panel.orderOut(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self,self.imageDialog === dialog else { return }
            NSApp.activate(ignoringOtherApps:true)
            dialog.begin { [weak self] response in
                guard let self else { return }
                self.imageDialog = nil
                if response == .OK {
                    for file in dialog.urls { self.receive(file:file,removeAfter:false) }
                }
                self.show()
            }
            dialog.makeKeyAndOrderFront(nil)
        }
    }
    func setMode(_ value:CaptureMode) {
        guard !busy,!capturing else { return }
        mode = value; UserDefaults.standard.set(value.rawValue,forKey:"captureMode")
        page = value == .batch ? .queue : .solution
        message = ""; resize(animated:true)
    }
    func receive(file:URL,removeAfter:Bool) {
        if mode == .instant { solve(file:file,removeAfter:removeAfter); return }
        defer { if removeAfter { try? FileManager.default.removeItem(at:file) } }
        do {
            try queue.add(file); pending = queue.shots
            page = .queue; message = ""; resize(animated:true); show()
        } catch { message = error.localizedDescription; page = .queue; expanded = true; show() }
    }
    func removeShot(_ shot:PendingShot) {
        guard !busy else { return }
        do { try queue.remove([shot.id]); pending = queue.shots; message = ""; resize(animated:true) }
        catch { message = "Не удалось удалить снимок из очереди." }
    }
    func sendBatch() {
        guard !busy,!capturing,!pending.isEmpty else { return }
        let shots = pending
        let files = shots.map { queue.url(for:$0) }
        answer = nil; batchAnswer = nil; selectedID = nil; thumbnail = nil; retryImage = nil; retryBatch = true
        page = .solution; message = ""; busy = true; elapsed = 0; progress = .preparing
        expanded = true; resize(animated:true); show()
        let id = UUID(); request = id
        let worker = Solver(); solver = worker; let instructions = preferences; saveSettings()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in Task { @MainActor in self?.elapsed += 1 } }
        DispatchQueue.global(qos:.userInitiated).async {
            let result = Result { try worker.solveBatch(images:files,instructions:instructions) { status in
                DispatchQueue.main.async {
                    guard self.request == id,self.busy else { return }; self.progress = status
                }
            } }
            DispatchQueue.main.async {
                guard self.request == id else { return }
                self.timer?.invalidate(); self.busy = false; self.solver = nil
                switch result {
                case .success(let batch):
                    self.batchAnswer = batch; self.answer = batch.summary
                    do {
                        let entry = try self.store.append(batch.summary,batch:batch)
                        self.history = self.store.entries; self.selectedID = entry.id
                        do { try self.queue.remove(Set(shots.map(\.id))); self.pending = self.queue.shots; self.retryBatch = false }
                        catch { self.message = "Ответы сохранены, но очистить очередь не удалось." }
                    } catch { self.historyIssue = "Ответы получены, но сохранить историю не удалось. Снимки остались в очереди." }
                case .failure(let error): self.message = error.localizedDescription
                }
                self.resize(animated:true); self.show()
            }
        }
    }
    func solve(file:URL,removeAfter:Bool) {
        guard !busy else { return }
        answer = nil; batchAnswer = nil; retryBatch = false; selectedID = nil; expanded = false; page = .solution; message = ""
        thumbnail = NSImage(contentsOf:file); retryImage = try? Data(contentsOf:file)
        busy = true; elapsed = 0; progress = .preparing; resize(animated:true); show()
        let id = UUID(); request = id
        let worker = Solver(); solver = worker; let instructions = preferences; saveSettings()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in Task { @MainActor in self?.elapsed += 1 } }
        DispatchQueue.global(qos:.userInitiated).async {
            let result = Result { try worker.solve(image:file,instructions:instructions) { status in
                DispatchQueue.main.async {
                    guard self.request == id,self.busy else { return }
                    self.progress = status
                }
            } }
            if removeAfter { try? FileManager.default.removeItem(at:file) }
            DispatchQueue.main.async {
                guard self.request == id else { return }
                self.timer?.invalidate(); self.busy = false; self.solver = nil
                switch result {
                case .success(let answer):
                    self.answer = answer
                    do {
                        let entry = try self.store.append(answer)
                        self.history = self.store.entries; self.selectedID = entry.id
                    } catch { self.historyIssue = "Ответ получен, но сохранить историю не удалось. Проверьте доступ к папке приложения." }
                case .failure(let error): self.message = error.localizedDescription
                }
                self.resize(animated:true); self.show()
            }
        }
    }
    func retry() {
        guard !busy else { return }
        if retryBatch { sendBatch(); return }
        guard let data = retryImage else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Lens-retry-\(UUID()).png")
        do { try data.write(to:file); solve(file:file,removeAfter:true) }
        catch { message = "Не удалось подготовить сохранённый снимок." }
    }
    func cancel() { solver?.cancel() }
    func copy() {
        guard let answer,answer.status == "ok" else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(answer.answer,forType:.string)
    }
    func saveSettings() {
        UserDefaults.standard.set(preferences,forKey:"preferences")
        UserDefaults.standard.set(codexPath,forKey:"codexPath")
    }
    func openSettings() {
        if let imageDialog { imageDialog.makeKeyAndOrderFront(nil); return }
        page = .settings; expanded = true; show(); panel.makeKeyAndOrderFront(nil)
    }
    func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        let open = ClosureMenuItem("Открыть изображение…") { [weak self] in self?.openImage() }; open.isEnabled = !busy; menu.addItem(open)
        let queueItem = ClosureMenuItem("Снимки для отправки · \(pending.count)") { [weak self] in self?.page = .queue; self?.expanded = true; self?.show() }
        menu.addItem(queueItem)
        menu.addItem(ClosureMenuItem("Настройки") { [weak self] in self?.openSettings() })
        menu.addItem(ClosureMenuItem("Вернуть в правый нижний угол") { [weak self] in self?.resetPosition() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Свернуть в строку меню") { [weak self] in self?.hide() })
        menu.addItem(ClosureMenuItem("Завершить Lens") { [weak self] in self?.solver?.cancel(); NSApp.terminate(nil) })
        return menu
    }
}

@MainActor final class ClosureMenuItem:NSMenuItem {
    let handler:()->Void
    init(_ title:String,handler:@escaping()->Void) {
        self.handler = handler; super.init(title:title,action:#selector(run),keyEquivalent:""); target = self
    }
    required init(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    @objc func run() { handler() }
}

final class DragArea:NSView {
    override func acceptsFirstMouse(for event:NSEvent?)->Bool { true }
    override func mouseDown(with event:NSEvent) { (window as? LensPanel)?.beginDragging(with:event) }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.openHand) }
}
struct DragSurface:NSViewRepresentable {
    func makeNSView(context:Context)->DragArea { DragArea(frame:.zero) }
    func updateNSView(_ view:DragArea,context:Context) {}
}

struct LensView:View {
    @ObservedObject var state:LensState
    let ink = Color(red:0.14,green:0.18,blue:0.20)
    var body:some View {
        dock(width:state.panelWidth)
            .frame(width:state.panelWidth,height:state.panelHeight,alignment:.bottomTrailing)
            .background(alignment:.topTrailing) {
                details(height:max(0,state.panelHeight-52))
                    .frame(width:state.expandedWidth,height:max(0,state.panelHeight-44))
                    .opacity(max(0,(state.reveal-0.18)/0.82))
                    .allowsHitTesting(state.expanded && state.reveal > 0.9)
                    .accessibilityHidden(!state.expanded)
            }
            .foregroundStyle(ink)
            .background(Color(red:0.975,green:0.977,blue:0.97))
            .clipShape(RoundedRectangle(cornerRadius:22-state.reveal*2))
            .overlay(RoundedRectangle(cornerRadius:22-state.reveal*2).stroke(Color.black.opacity(0.075),lineWidth:1))
            .overlay(alignment:.top) {
                if state.expanded && state.page == .solution {
                    DragSurface().frame(height:8).padding(.horizontal,18)
                        .accessibilityLabel("Перетащить панель")
                }
            }
            .preferredColorScheme(.light)
            .contextMenu { actions }
    }
    func dock(width:CGFloat)->some View {
        HStack(spacing:4) {
            Color.clear.frame(width:max(0,width-88),height:36)
                .overlay(alignment:.leading) {
                    compactBadge.frame(width:max(0,width-88),height:36)
                        .opacity(max(0,1-state.reveal*3)).allowsHitTesting(!state.expanded)
                        .accessibilityHidden(state.expanded)
                }
                .overlay(alignment:.leading) {
                HStack(spacing:2) {
                    IconButton(symbol:"ellipsis",label:"Другие действия",help:"Открыть изображение, настройки и выход",menu:{ state.overflowMenu() }) {}.frame(width:36,height:36)
                    IconButton(symbol:"clock.arrow.circlepath",label:"История запросов",help:"Сохранённые запросы: \(state.history.count)") {
                        if state.page == .history { state.page = .solution } else { state.openHistory() }
                    }.frame(width:36,height:36)
                    IconButton(symbol:state.busy ? "stop.fill" : "doc.on.doc",label:state.busy ? "Отменить запрос" : "Копировать ответ",help:state.busy ? "Отменить запрос" : "Копировать краткий ответ",enabled:state.busy || state.answer?.status == "ok") {
                        if state.busy { state.cancel() } else { state.copy() }
                    }.frame(width:36,height:36)
                    Spacer(minLength:0)
                    ModeSwitch(mode:state.mode,enabled:!state.busy && !state.capturing) { state.setMode($0) }
                        .frame(width:62,height:28)
                    IconButton(symbol:"crop",label:"Выделить область",help:"Выделить область · ⌃⌥4",enabled:!state.busy) { state.select() }.frame(width:36,height:36)
                }
                .frame(width:max(0,width-88),height:36)
                .opacity(max(0,(state.reveal-0.35)/0.65)).allowsHitTesting(state.expanded && state.reveal > 0.9)
                .accessibilityHidden(!state.expanded)
            }
            .clipped().background(DragSurface())
            IconButton(symbol:"camera",label:"Скриншот всего экрана",help:"Скриншот всего экрана · ⌃⌥3",enabled:!state.busy) { state.fullScreen() }.frame(width:36,height:36)
            IconButton(symbol:"chevron.up",label:state.expanded ? "Свернуть панель" : "Раскрыть панель",help:state.expanded ? "Свернуть панель" : "Раскрыть решение и историю") { state.toggleExpanded() }
                .frame(width:36,height:36).rotationEffect(.degrees(Double(state.reveal)*180))
        }.padding(4).frame(width:width,height:44)
    }
    @ViewBuilder var compactBadge:some View {
        if state.busy {
            HStack(spacing:6) {
                ProgressView().controlSize(.small)
                VStack(spacing:1) {
                    Text(state.progress.compact).font(.system(size:10,weight:.medium))
                        .foregroundStyle(state.progress.isWarning ? Color.orange : ink)
                    Text("\(state.elapsed) с").font(.system(size:9)).monospacedDigit().foregroundStyle(.secondary)
                }
            }.frame(maxWidth:.infinity).help(state.progress.title)
        } else if state.mode == .batch && !state.pending.isEmpty {
            Button { state.page = .queue; state.expanded = true } label: {
                HStack(spacing:5) {
                    Image(systemName:"square.stack").font(.system(size:11))
                    Text("\(state.pending.count) сним.").font(.system(size:12,weight:.medium)).monospacedDigit()
                }.frame(maxWidth:.infinity,minHeight:36).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.leading,8).help("Открыть очередь и отправить все снимки")
        } else if let batch = state.batchAnswer {
            Button { state.page = .solution; state.expanded = true } label: {
                Text(batch.answerCountText).font(.system(size:12,weight:.medium))
                    .frame(maxWidth:.infinity,minHeight:36).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.leading,8)
        } else if let answer = state.answer,answer.status == "ok" {
            Button { state.page = .solution; state.expanded = true } label: {
                Text(answer.answer).font(.system(size:21,weight:.medium,design:.rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65).frame(maxWidth:.infinity,minHeight:36).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.leading,9).help("Раскрыть решение")
        } else if !state.message.isEmpty || state.answer?.status == "needs_input" {
            IconButton(symbol:"exclamationmark",label:"Показать сообщение",help:"Показать сообщение или уточнение") { state.page = .solution; state.expanded = true }.frame(width:28,height:36)
        }
    }
    func details(height:CGFloat)->some View {
        VStack(alignment:.leading,spacing:8) {
            if state.page != .solution {
                Text(state.page == .history ? "История" : state.page == .queue ? "Снимки" : "Настройки")
                    .font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)
                    .frame(maxWidth:.infinity,minHeight:22,alignment:.leading)
                    .overlay(DragSurface().accessibilityLabel("Перетащить панель"))
            }
            ScrollView {
                VStack(alignment:.leading,spacing:11) {
                    if !state.historyIssue.isEmpty { Text(state.historyIssue).font(.system(size:11)).foregroundStyle(.orange) }
                    if state.page == .history { historyView }
                    else if state.page == .settings { settingsView }
                    else if state.page == .queue { queueView }
                    else { solutionView }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(.trailing,4)
            }.scrollIndicators(.automatic).id("\(state.page)-\(state.selectedID?.uuidString ?? "none")")
        }.padding(.horizontal,16).padding(.top,12).padding(.bottom,4).frame(height:height).clipped()
    }
    @ViewBuilder var solutionView:some View {
        if let batch = state.batchAnswer {
            batchView(batch)
        } else if let answer = state.answer {
            if answer.status == "ok" {
                Text(answer.answer).font(.system(size:28,weight:.medium,design:.rounded)).monospacedDigit().textSelection(.enabled)
            }
            if !answer.warnings.isEmpty { Text(answer.warnings.joined(separator:"\n")).font(.system(size:11)).foregroundStyle(.orange) }
            Text(answer.task).font(.system(size:11,weight:.medium)).textSelection(.enabled)
            Text(answer.solution).font(.system(size:12)).lineSpacing(4).textSelection(.enabled)
            if let image = state.thumbnail { Image(nsImage:image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius:8)) }
            if !answer.format_note.isEmpty {
                Text(answer.format_note).font(.system(size:10)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } else if state.busy {
            Text(state.progress.title).font(.system(size:13,weight:.medium))
                .foregroundStyle(state.progress.isWarning ? Color.orange : ink)
            if state.progress == .offline {
                Text(state.retryBatch ? "Подборка сохранена. После восстановления сети все снимки будут отправлены автоматически." : "Снимок сохранён. После восстановления сети он будет отправлен автоматически.")
                    .font(.system(size:11)).foregroundStyle(.secondary)
            }
            Text("\(state.elapsed) с").font(.system(size:11)).foregroundStyle(.secondary)
        } else if !state.message.isEmpty {
            Text(state.message).font(.system(size:12)).textSelection(.enabled)
            if state.retryImage != nil || state.retryBatch { Button("Повторить") { state.retry() }.font(.system(size:11)) }
        } else {
            Text("⌃⌥3 — весь экран\n⌃⌥4 — выделить область").font(.system(size:12)).lineSpacing(7).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder var queueView:some View {
        if !state.message.isEmpty { Text(state.message).font(.system(size:11)).foregroundStyle(.orange) }
        if state.pending.isEmpty {
            Text("Добавляйте снимки камерой или выделением области. Затем отправьте всю подборку.")
                .font(.system(size:12)).foregroundStyle(.secondary)
            Button("Открыть изображения…") { state.openImage() }.disabled(state.busy)
            if state.mode != .batch { Button("Включить накопление") { state.setMode(.batch) } }
        } else {
            Button { state.sendBatch() } label: {
                Label("Отправить все · \(state.pending.count)",systemImage:"paperplane.fill")
                    .font(.system(size:12,weight:.medium)).frame(maxWidth:.infinity)
            }.buttonStyle(.borderedProminent).tint(ink).disabled(state.busy)
            ForEach(Array(state.pending.enumerated()),id:\.element.id) { index,shot in
                HStack(spacing:10) {
                    if let image = NSImage(contentsOf:state.queue.url(for:shot)) {
                        Image(nsImage:image).resizable().scaledToFit().frame(width:64,height:44)
                            .clipShape(RoundedRectangle(cornerRadius:5))
                    }
                    Text("Снимок \(index+1)").font(.system(size:12))
                    Spacer(minLength:0)
                    IconButton(symbol:"trash",label:"Удалить снимок \(index+1)",help:"Убрать этот снимок из подборки",enabled:!state.busy) {
                        state.removeShot(shot)
                    }.frame(width:30,height:30)
                }.padding(7).background(RoundedRectangle(cornerRadius:9).fill(Color.black.opacity(0.025)))
            }
        }
    }
    func batchView(_ batch:BatchAnswer)->some View {
        VStack(alignment:.leading,spacing:12) {
            ForEach(Array(batch.items.enumerated()),id:\.element.id) { index,item in
                HStack(alignment:.firstTextBaseline,spacing:10) {
                    Text("\(index+1).").font(.system(size:11)).foregroundStyle(.secondary).frame(width:23,alignment:.leading)
                    Text(item.result.status == "ok" ? item.result.answer : "Нужно уточнение")
                        .font(.system(size:21,weight:.medium,design:.rounded)).textSelection(.enabled)
                    Spacer(minLength:0)
                }
            }
            Divider().padding(.vertical,2)
            ForEach(Array(batch.items.enumerated()),id:\.element.id) { index,item in
                BatchSolutionRow(number:index+1,item:item)
            }
            if !state.message.isEmpty { Text(state.message).font(.system(size:11)).foregroundStyle(.orange) }
        }
    }
    @ViewBuilder var historyView:some View {
        if state.history.isEmpty {
            Text("Здесь появятся ответы и решения.").font(.system(size:12)).foregroundStyle(.secondary)
        } else {
            LazyVStack(spacing:6) {
                ForEach(state.history.reversed()) { entry in
                    Button { state.choose(entry) } label: {
                        VStack(alignment:.leading,spacing:5) {
                            HStack {
                                Text("Запрос \(entry.number)").font(.system(size:10,weight:.medium))
                                Spacer()
                                Text(entry.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier:"ru_RU"))))
                                    .font(.system(size:9)).foregroundStyle(.secondary)
                            }
                            Text(entry.title).font(.system(size:11)).lineLimit(2).multilineTextAlignment(.leading)
                            Text(entry.answer.status == "ok" ? entry.answer.answer : "Нужно уточнение").font(.system(size:16,weight:.medium,design:.rounded)).lineLimit(2)
                        }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                            .background(RoundedRectangle(cornerRadius:10).fill(Color.black.opacity(state.selectedID == entry.id ? 0.065 : 0.025)))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Запрос \(entry.number): \(entry.title). Ответ: \(entry.answer.answer)")
                }
            }
        }
    }
    var settingsView:some View {
        VStack(alignment:.leading,spacing:8) {
            Text("GPT‑6.1 Sol · High reasoning").font(.system(size:12,weight:.medium))
            Text("Пожелания к формату").font(.system(size:10)).foregroundStyle(.secondary)
            TextField("Например: только число, десятичная запятая",text:$state.preferences,axis:.vertical)
                .lineLimit(2...5).onChange(of:state.preferences) { _,_ in state.saveSettings() }
            Text("Путь к Codex CLI · необязательно").font(.system(size:10)).foregroundStyle(.secondary)
            TextField("Автоматический поиск",text:$state.codexPath)
                .onChange(of:state.codexPath) { _,_ in state.saveSettings() }
            Button("Сохранить") { state.panel.makeFirstResponder(nil); state.saveSettings(); state.page = .solution }
        }.textFieldStyle(.roundedBorder).font(.system(size:11))
    }
    @ViewBuilder var actions:some View {
        Button("Весь экран   ⌃⌥3") { state.fullScreen() }.disabled(state.busy)
        Button("Выделить область   ⌃⌥4") { state.select() }.disabled(state.busy)
        Button("Открыть изображение…") { state.openImage() }.disabled(state.busy)
        Divider()
        Button("История запросов") { state.openHistory() }
        Button("Снимки для отправки · \(state.pending.count)") { state.page = .queue; state.expanded = true }
        Button("Настройки") { state.openSettings() }
        Button("Свернуть в строку меню") { state.hide() }
        Button("Завершить Lens") { state.solver?.cancel(); NSApp.terminate(nil) }
    }
}

final class SelectionPanel:NSPanel { override var canBecomeKey:Bool { true } }
@MainActor final class RegionView:NSView {
    var start:NSPoint?
    var current:NSPoint?
    var done:((NSRect?)->Void)?
    override var acceptsFirstResponder:Bool { true }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill(); bounds.fill()
        if let start,let current {
            let rect = NSRect(x:min(start.x,current.x),y:min(start.y,current.y),width:abs(start.x-current.x),height:abs(start.y-current.y))
            NSColor.white.withAlphaComponent(0.18).setFill(); rect.fill()
            NSColor.systemTeal.setStroke(); let path = NSBezierPath(rect:rect); path.lineWidth = 2; path.stroke()
        }
        ("Выделите одну задачу целиком · Esc — отмена" as NSString).draw(at:NSPoint(x:35,y:bounds.height-65),withAttributes:[.font:NSFont.systemFont(ofSize:20,weight:.medium),.foregroundColor:NSColor.white])
    }
    override func mouseDown(with event:NSEvent) { window?.makeKey(); start = convert(event.locationInWindow,from:nil); current = start; needsDisplay = true }
    override func mouseDragged(with event:NSEvent) { current = convert(event.locationInWindow,from:nil); needsDisplay = true }
    override func mouseUp(with event:NSEvent) {
        guard let start,let window else { done?(nil); return }
        let end = convert(event.locationInWindow,from:nil)
        let local = NSRect(x:min(start.x,end.x),y:min(start.y,end.y),width:abs(start.x-end.x),height:abs(start.y-end.y)).intersection(bounds)
        guard local.width >= 30,local.height >= 30 else { done?(nil); return }
        let world = window.convertToScreen(convert(local,to:nil)); let top = NSScreen.screens.first?.frame.maxY ?? 0
        done?(CGRect(x:world.minX,y:top-world.maxY,width:world.width,height:world.height))
    }
    override func keyDown(with event:NSEvent) { if event.keyCode == 53 { done?(nil) } }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.crosshair) }
}
@MainActor final class SelectionCoordinator {
    var windows:[NSPanel] = []; var monitor:Any?
    let completion:(CGRect?,NSScreen?)->Void
    init(completion:@escaping(CGRect?,NSScreen?)->Void) { self.completion = completion }
    func begin() {
        NSApp.activate(ignoringOtherApps:true)
        for screen in NSScreen.screens {
            let window = SelectionPanel(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false)
            window.level = .screenSaver; window.backgroundColor = .clear; window.isOpaque = false
            window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            let view = RegionView(frame:NSRect(origin:.zero,size:screen.frame.size))
            view.done = { [weak self] rect in self?.finish(rect,screen:screen) }
            window.contentView = view; window.makeFirstResponder(view); window.makeKeyAndOrderFront(nil); windows.append(window)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.finish(nil,screen:nil); return nil }; return event
        }
    }
    func finish(_ rect:CGRect?,screen:NSScreen?) {
        guard !windows.isEmpty else { return }
        windows.forEach { $0.orderOut(nil) }; windows.removeAll()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }; completion(rect,screen)
    }
}
final class LensPanel:NSPanel {
    var dragBegan:(()->Void)?
    var dragEnded:(()->Void)?
    override var canBecomeKey:Bool { true }
    static func screenPoint(_ event:NSEvent)->CGPoint {
        if let location = event.cgEvent?.location {
            return CGPoint(x:location.x,y:(NSScreen.screens.first?.frame.maxY ?? 0)-location.y)
        }
        if let window = event.window { return window.convertPoint(toScreen:event.locationInWindow) }
        return event.locationInWindow
    }
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           let action = ["v":"paste:","c":"copy:","x":"cut:","a":"selectAll:","z":"undo:"][key] {
            if NSApp.sendAction(NSSelectorFromString(action),to:nil,from:self) { return true }
        }
        return super.performKeyEquivalent(with:event)
    }
    override func sendEvent(_ event:NSEvent) {
        if event.type == .leftMouseDown,let contentView {
            var target = contentView.hitTest(contentView.convert(event.locationInWindow,from:nil))
            var editing = false
            while let view = target {
                if view is NSTextField || view is NSTextView { editing = true; break }
                target = view.superview
            }
            if !editing { makeFirstResponder(nil) }
        }
        super.sendEvent(event)
    }
    func beginDragging(with event:NSEvent,current:NSEvent? = nil) {
        dragBegan?()
        makeFirstResponder(nil)
        let start = Self.screenPoint(event)
        let origin = frame.origin
        func move(_ next:NSEvent) {
            let point = Self.screenPoint(next)
            setFrameOrigin(NSPoint(x:origin.x+point.x-start.x,y:origin.y+point.y-start.y))
        }
        if let current { move(current) }
        while let next = nextEvent(matching:[.leftMouseDragged,.leftMouseUp],until:.distantFuture,inMode:.eventTracking,dequeue:true) {
            if next.type == .leftMouseUp { break }
            move(next)
        }
        dragEnded?()
    }
}
final class LensHostingView<Content:View>:NSHostingView<Content> {
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    let state = LensState()
    var status:NSStatusItem!
    var keys:[EventHotKeyRef?] = [nil,nil,nil]
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
        let main = NSMenu()
        let application = NSMenu(title:"Lens")
        let quitItem = application.addItem(withTitle:"Завершить Lens",action:#selector(quit),keyEquivalent:"q"); quitItem.target = self
        let appItem = NSMenuItem(title:"Lens",action:nil,keyEquivalent:""); appItem.submenu = application; main.addItem(appItem)
        let edit = NSMenu(title:"Правка")
        for (title,action,key) in [("Отменить","undo:","z"),("Вырезать","cut:","x"),("Копировать","copy:","c"),("Вставить","paste:","v"),("Выделить всё","selectAll:","a")] {
            edit.addItem(withTitle:title,action:NSSelectorFromString(action),keyEquivalent:key)
        }
        let editItem = NSMenuItem(title:"Правка",action:nil,keyEquivalent:""); editItem.submenu = edit; main.addItem(editItem)
        NSApp.mainMenu = main
        let panel = LensPanel(contentRect:NSRect(x:0,y:0,width:88,height:44),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false; panel.delegate = self
        panel.dragBegan = { [weak self] in self?.state.prepareForDrag() }
        panel.dragEnded = { [weak self] in self?.state.finishDrag() }
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let hosting = LensHostingView(rootView:LensView(state:state))
        hosting.sizingOptions = []; hosting.autoresizingMask = [.width,.height]
        panel.contentView = hosting; state.panel = panel; state.targetScreen = NSScreen.main
        state.show()
        status = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName:"camera.viewfinder",accessibilityDescription:"Lens")
        status.button?.toolTip = "Lens · снимки и история ответов"
        let menu = NSMenu()
        menu.addItem(withTitle:"Показать / свернуть",action:#selector(toggle),keyEquivalent:"")
        menu.addItem(withTitle:"Весь экран   ⌃⌥3",action:#selector(full),keyEquivalent:"")
        menu.addItem(withTitle:"Выделить область   ⌃⌥4",action:#selector(select),keyEquivalent:"")
        menu.addItem(withTitle:"История запросов",action:#selector(history),keyEquivalent:"")
        menu.addItem(withTitle:"Открыть изображение…",action:#selector(openImage),keyEquivalent:"")
        menu.addItem(withTitle:"Настройки",action:#selector(settings),keyEquivalent:"")
        menu.addItem(.separator()); menu.addItem(withTitle:"Завершить Lens",action:#selector(quit),keyEquivalent:"q")
        for item in menu.items { item.target = self }; status.menu = menu
        var spec = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),{ _,event,context in
            guard let event,let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue(); let key = id.id
            DispatchQueue.main.async {
                if key == 1 { delegate.state.fullScreen() } else if key == 2 { delegate.state.select() } else { delegate.toggle() }
            }
            return noErr
        },1,&spec,Unmanaged.passUnretained(self).toOpaque(),nil)
        for (index,code) in [UInt32(kVK_ANSI_3),UInt32(kVK_ANSI_4),UInt32(kVK_ANSI_L)].enumerated() {
            let result = RegisterEventHotKey(code,UInt32(controlKey|optionKey),EventHotKeyID(signature:0x45434f4e,id:UInt32(index+1)),GetApplicationEventTarget(),0,&keys[index])
            if result != noErr { state.message = "Горячая клавиша занята. Используйте меню приложения." }
        }
        NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.state.targetScreen = NSScreen.main; self?.state.resize() }
        }
    }
    func windowDidMove(_ notification:Notification) { state.rememberPosition() }
    func windowWillStartLiveResize(_ notification:Notification) { state.frameTimer?.invalidate(); state.frameTimer = nil; HintBubble.shared.hide() }
    func windowDidResize(_ notification:Notification) { state.rememberSize() }
    func windowDidEndLiveResize(_ notification:Notification) { state.rememberSize(); state.rememberPosition() }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool { state.show(); return true }
    @objc func toggle() { if state.panel.isVisible { state.hide() } else if !state.capturing { state.show() } }
    @objc func full() { state.fullScreen() }
    @objc func select() { state.select() }
    @objc func history() { state.openHistory() }
    @objc func openImage() { state.openImage() }
    @objc func settings() { state.openSettings() }
    @objc func quit() { state.solver?.cancel(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification:Notification) { HintBubble.shared.hide(); state.solver?.cancel(); state.timer?.invalidate(); state.frameTimer?.invalidate() }
}



struct ModeSwitch:NSViewRepresentable {
    let mode:CaptureMode
    let enabled:Bool
    let changed:(CaptureMode)->Void
    final class Coordinator:NSObject {
        var changed:(CaptureMode)->Void
        init(_ changed:@escaping(CaptureMode)->Void) { self.changed = changed }
        @objc func select(_ sender:NSSegmentedControl) { changed(sender.selectedSegment == 1 ? .batch : .instant) }
    }
    func makeCoordinator()->Coordinator { Coordinator(changed) }
    func makeNSView(context:Context)->NSSegmentedControl {
        let view = NSSegmentedControl(images:[NSImage(systemSymbolName:"bolt",accessibilityDescription:"Решать сразу")!,NSImage(systemSymbolName:"square.stack",accessibilityDescription:"Накапливать снимки")!],trackingMode:.selectOne,target:context.coordinator,action:#selector(Coordinator.select(_:)))
        view.segmentStyle = .rounded; view.controlSize = .small
        view.setToolTip("Решать каждый снимок сразу",forSegment:0)
        view.setToolTip("Накапливать снимки и отправлять вместе",forSegment:1)
        view.setAccessibilityLabel("Режим: сразу или накопление")
        return view
    }
    func updateNSView(_ view:NSSegmentedControl,context:Context) {
        context.coordinator.changed = changed; view.selectedSegment = mode == .batch ? 1 : 0; view.isEnabled = enabled
    }
}


struct BatchSolutionRow:View {
    let number:Int
    let item:BatchItem
    @State private var expanded = false
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            Button {
                withAnimation(.easeInOut(duration:0.18)) { expanded.toggle() }
            } label: {
                HStack(alignment:.top,spacing:7) {
                    Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width:11,height:15)
                    Text("\(number). \(item.result.task)").font(.system(size:11,weight:.medium))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength:0)
                }.padding(.vertical,6).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Решение \(number): \(item.result.task)")
                .accessibilityValue(expanded ? "Раскрыто" : "Свёрнуто")
                .help(expanded ? "Свернуть решение" : "Раскрыть решение")
            if expanded {
                VStack(alignment:.leading,spacing:10) {
                    if item.result.status == "ok" {
                        Text(item.result.answer).font(.system(size:24,weight:.medium,design:.rounded)).textSelection(.enabled)
                    }
                    if !item.result.warnings.isEmpty {
                        Text(item.result.warnings.joined(separator:"\n")).font(.system(size:11)).foregroundStyle(.orange)
                    }
                    Text(item.result.task).font(.system(size:11,weight:.medium)).textSelection(.enabled)
                    Text(item.result.solution).font(.system(size:12)).lineSpacing(4).textSelection(.enabled)
                    if !item.result.format_note.isEmpty {
                        Text(item.result.format_note).font(.system(size:10)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(.top,8)
            }
        }
    }
}
