import AppKit
import AVFoundation
import QuartzCore

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class MovieLayerView: NSView {
    let videoLayer = AVPlayerLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

@MainActor
final class DesktopSession {
    let window: DesktopWindow
    let player = AVQueuePlayer()
    let looper: AVPlayerLooper
    let view = MovieLayerView(frame: .zero)
    private var observation: NSKeyValueObservation?
    private var currentItemObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var closed = false

    init(screen: NSScreen, url: URL, fill: Bool, onFailure: @escaping (String) -> Void) {
        let item = AVPlayerItem(url: url)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: item)
        window = DesktopWindow(contentRect: screen.frame, styleMask: .borderless,
                               backing: .buffered, defer: false, screen: screen)
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.contentView = view
        view.videoLayer.player = player
        view.videoLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        observation = looper.observe(\.status, options: [.initial, .new]) { looper, _ in
            if looper.status == .failed {
                let message = looper.error?.localizedDescription ?? "Ошибка воспроизведения видео."
                DispatchQueue.main.async { onFailure(message) }
            }
        }
        currentItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            let item = player.currentItem
            DispatchQueue.main.async {
                guard let self = self, !self.closed else { return }
                self.itemObservation = item?.observe(\.status, options: [.initial, .new]) { item, _ in
                    if item.status == .failed {
                        let message = item.error?.localizedDescription ?? "Не удалось декодировать видео."
                        DispatchQueue.main.async { onFailure(message) }
                    }
                }
            }
        }
        window.orderFrontRegardless()
    }

    func setPaused(_ paused: Bool) { paused ? player.pause() : player.play() }
    func close() {
        closed = true
        observation = nil
        currentItemObservation = nil
        itemObservation = nil
        player.pause()
        looper.disableLooping()
        player.removeAllItems()
        view.videoLayer.player = nil
        window.orderOut(nil)
        window.close()
    }
}

@MainActor
final class DesktopController {
    private var sessions: [DesktopSession] = []
    private var generation = UUID()
    func install(url: URL, preferences: Preferences, paused: Bool, onFailure: @escaping (String) -> Void) {
        remove()
        let currentGeneration = generation
        let screens = preferences.allScreens ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        sessions = screens.map { screen in
            DesktopSession(screen: screen, url: url, fill: preferences.fill) { [weak self] message in
                guard self?.generation == currentGeneration else { return }
                onFailure(message)
            }
        }
        setPaused(paused)
    }
    func setPaused(_ paused: Bool) { sessions.forEach { $0.setPaused(paused) } }
    func setFill(_ fill: Bool) { sessions.forEach { $0.view.videoLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect } }
    func reorder() { sessions.forEach { $0.window.orderFrontRegardless() } }
    func remove() { generation = UUID(); sessions.forEach { $0.close() }; sessions.removeAll() }
}
