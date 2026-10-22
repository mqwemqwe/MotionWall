import AppKit
import SwiftUI
import AVKit
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var preferences = Preferences()
    @Published var selected: Movie?
    @Published var importing = false
    @Published var restoring = false
    @Published var progress = ""
    @Published var errorMessage: String?
    @Published var preview: AVPlayer?
    @Published var loginEnabled = false
    @Published var loginNeedsApproval = false
    @Published var sleeping = false
    @Published var sessionInactive = false
    @Published var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    let desktop = DesktopController()
    private var job: ConversionJob?
    private var importTask: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var previewVisible = true

    var busy: Bool { importing || restoring }
    var effectivePaused: Bool {
        preferences.paused || sleeping || sessionInactive || (preferences.respectLowPower && lowPower)
    }
    var status: String {
        if importing { return progress }
        if restoring { return "Восстанавливаю обои…" }
        if !preferences.enabled { return "Обои выключены" }
        if preferences.paused { return "Анимация на паузе" }
        if effectivePaused { return "Пауза для экономии энергии" }
        return "Обои воспроизводятся"
    }

    func start() {
        do { try Storage.prepare(); preferences = try Storage.read() }
        catch { errorMessage = "Не удалось прочитать настройки: \(error.localizedDescription)" }
        selected = preferences.movie
        refreshLoginStatus()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.sleeping = true; $0.updatePlayback() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.sleeping = false; $0.updatePlayback(); $0.desktop.reorder() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true; $0.updatePlayback() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false; $0.updatePlayback() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.desktop.reorder() }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.refreshDesktop() }
        observe(.default, NSNotification.Name.NSProcessInfoPowerStateDidChange) {
            $0.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled; $0.updatePlayback()
        }
        observe(.default, NSApplication.didBecomeActiveNotification) { $0.refreshLoginStatus() }
        guard let movie = preferences.movie else { return }
        restoring = true
        Task { [weak self] in
            guard let self = self else { return }
            defer { self.restoring = false }
            do {
                _ = try await validateMovie(at: Storage.url(for: movie))
                self.updatePreview()
                self.refreshDesktop()
            } catch {
                self.preferences.enabled = false
                self.errorMessage = "Сохранённое видео недоступно. Выбери его заново.\n\(error.localizedDescription)"
            }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping (AppModel) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self = self { action(self) } }
        }
        observers.append((center, token))
    }

    func chooseMovie() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Выбери видео для рабочего стола"
        panel.prompt = "Подготовить видео"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // No extension filter: the decoder inspects the content, including unusual containers.
        if panel.runModal() == .OK, let url = panel.url { importMovie(url) }
    }

    func importMovie(_ source: URL) {
        guard !busy, source.isFileURL else { return }
        let converter = ConversionJob()
        job = converter
        importing = true
        progress = "Подготавливаю видео…"
        errorMessage = nil
        importTask = Task { [weak self] in
            guard let self = self else { return }
            let scoped = source.startAccessingSecurityScopedResource()
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("MotionWall-\(UUID().uuidString)")
            let output = work.appendingPathComponent("converted.mp4")
            defer {
                if scoped { source.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: work)
                self.importing = false
                self.job = nil
                self.importTask = nil
            }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                try await converter.convert(source: source, destination: output) { [weak self] time in
                    Task { @MainActor in
                        guard let self = self, self.importing, !Task.isCancelled else { return }
                        self.progress = "Обработано видео: \(time)"
                    }
                }
                try Task.checkCancellation()
                self.progress = "Проверяю готовое видео…"
                let duration = try await validateMovie(at: output)
                try Task.checkCancellation()
                let movie = Movie(filename: "\(UUID().uuidString).mp4", title: source.lastPathComponent, seconds: duration)
                try Storage.prepare()
                try FileManager.default.moveItem(at: output, to: Storage.url(for: movie))
                self.selected = movie
                self.updatePreview()
                self.cleanUnusedMedia()
            } catch is CancellationError {
                // The currently installed wallpaper and previous selection are intentionally preserved.
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    func cancelImport() { importTask?.cancel(); job?.cancel(); progress = "Отменяю…" }

    func install() {
        guard let selected = selected, !busy else { return }
        var next = preferences
        next.movie = selected
        next.enabled = true
        next.paused = false
        guard persist(next) else { return }
        refreshDesktop()
        cleanUnusedMedia()
    }

    func removeWallpaper() {
        var next = preferences; next.enabled = false; next.paused = false
        guard persist(next) else { return }
        desktop.remove()
    }

    func togglePause() {
        guard preferences.enabled else { return }
        var next = preferences; next.paused.toggle()
        guard persist(next) else { return }
        updatePlayback()
    }

    func setFill(_ value: Bool) {
        var next = preferences; next.fill = value
        if persist(next) { desktop.setFill(value) }
    }
    func setAllScreens(_ value: Bool) {
        var next = preferences; next.allScreens = value
        if persist(next) { refreshDesktop() }
    }
    func setLowPower(_ value: Bool) {
        var next = preferences; next.respectLowPower = value
        if persist(next) { updatePlayback() }
    }
    @discardableResult private func persist(_ next: Preferences) -> Bool {
        do { try Storage.write(next); preferences = next; return true }
        catch { errorMessage = "Не удалось сохранить настройки: \(error.localizedDescription)"; return false }
    }

    func refreshDesktop() {
        guard !restoring || preferences.movie != nil else { return }
        guard preferences.enabled, let movie = preferences.movie else { desktop.remove(); return }
        desktop.install(url: Storage.url(for: movie), preferences: preferences, paused: effectivePaused) { [weak self] message in
            guard let self = self else { return }
            self.desktop.remove()
            var next = self.preferences; next.enabled = false
            _ = self.persist(next)
            self.errorMessage = "Не удалось воспроизвести обои: \(message)"
        }
    }

    private func updatePlayback() {
        desktop.setPaused(effectivePaused)
        if sleeping || sessionInactive || (preferences.respectLowPower && lowPower) { preview?.pause() }
        else if previewVisible { preview?.play() }
    }
    func setPreviewVisible(_ visible: Bool) {
        previewVisible = visible
        if visible { updatePlayback() } else { preview?.pause() }
    }
    private func updatePreview() {
        preview?.pause()
        guard let movie = selected else { preview = nil; return }
        let player = AVPlayer(url: Storage.url(for: movie))
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        preview = player
        updatePlayback()
    }

    private func cleanUnusedMedia() {
        let keep = Set([selected?.filename, preferences.movie?.filename].compactMap { $0 })
        guard let files = try? FileManager.default.contentsOfDirectory(at: Storage.media, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "mp4" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil && !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        loginNeedsApproval = status == .requiresApproval
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { errorMessage = "Не удалось изменить автозапуск: \(error.localizedDescription)" }
        refreshLoginStatus()
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func shutdown() {
        cancelImport()
        preview?.pause()
        desktop.remove()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }
}
