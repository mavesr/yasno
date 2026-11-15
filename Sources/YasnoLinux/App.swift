import Foundation
import SwitchCore
import CYasnoLinux

/// The running application: the input devices, the engine, the settings window and the tray,
/// tied together the way AppDelegate and AppModel tie them on the Mac.
public final class App {
    public static var shared: App?

    let settings = Settings()
    let hub: InputHub
    let sink: UinputSink?
    let devices: InputDevices?
    let engine: Engine
    let updater: Updater
    private var timer: DispatchSourceTimer?
    private var stalls: [TimeInterval] = []
    private var accessOK = false
    private var lastPosted: String?
    private var setupBusy = false
    private var setupMessage = ""
    private var extensionNote = ""

    private let x11Rules: [String]

    public init() {
        x11Rules = X11Backend.rawRules()
        let sink = UinputSink()
        self.sink = sink
        let target: KeySink = sink ?? NullSink()
        hub = InputHub(sink: target)
        let typist = SinkTypist(sink: target, hub: hub)
        engine = Engine(hub: hub, typist: typist, settings: settings, backend: nil)
        let hub = self.hub
        devices = sink.map { InputDevices(hub: hub, sink: $0) }
        updater = Updater(settings: settings)
        engine.onChange = { [weak self] in self?.post() }
        updater.onChange = { [weak self] in self?.post() }
        updater.onInstalled = { [weak self] directory in self?.restart(into: directory) }
        let engineStall = hub.onStall
        hub.onStall = { [weak self] in engineStall?(); self?.stalled() }
    }

    // MARK: Start

    /// Called on the main thread once GTK has started (the window exists or is hidden).
    func started(background: Bool) {
        accessOK = sink != nil && InputDevices.accessible
        if Backends.isGnome, !Setup.gnomeExtensionInstalled { Setup.installGnomeExtension(resources: Setup.resources) }
        engine.loadDetector { [weak self] in self?.post() }
        engine.queue.async { [self] in
            if !x11Rules.isEmpty {
                // Xorg picks up the virtual keyboard within a moment and may reset the layouts.
                usleep(700_000)
                X11Backend.restore(x11Rules)
            }
            engine.backend = Backends.detect()
            engine.reloadLayouts()
            engine.adoptCurrentCyrillic()
            refresh()
        }
        devices?.start()
        let timer = DispatchSource.makeTimerSource(queue: engine.queue)
        timer.schedule(deadline: .now() + 1, repeating: .milliseconds(700), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
        updater.schedule()
        post()
    }

    /// Engine queue. Follows the desktop: which layouts it has, which one is on, which
    /// application has the keys and whether a password is being typed.
    private func refresh() {
        if engine.backend == nil { engine.backend = Backends.detect() }
        engine.reloadLayouts()
        engine.sourceChanged()
        engine.refreshApp()
        engine.secureInput = engine.backend?.secure() ?? false
        engine.apply(allowed: accessOK && engine.detectorLoaded)
        devices?.setGrab(accessOK && settings.values.enabled && engine.layouts.count >= 2 && !hub.isFaulted)
        post()
    }

    /// Three stalls within a minute mean the engine cannot keep up: correcting stops (the keys
    /// go straight through) until the user turns it on again, so typing is never held up.
    private func stalled() {
        engine.queue.async { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            stalls = stalls.filter { now - $0 < 60 } + [now]
            if stalls.count >= 3 {
                stalls = []
                settings.update { $0.enabled = false }
                engine.apply(allowed: false)
                devices?.setGrab(false)
                setupMessage = "Ясно приостановлено: ввод несколько раз задерживался. Включите его снова, когда будет удобно."
            }
            post()
        }
    }

    // MARK: State for the window and the tray

    private var statusText: (String, String) {
        if !accessOK { return ("Нужен доступ к клавиатуре", "Ясно ещё не может читать клавиатуру.") }
        if engine.backend == nil {
            return ("Рабочий стол не поддерживается", "Не удалось узнать раскладки: поддерживаются GNOME, KDE Plasma, Sway, Hyprland и X11.")
        }
        if engine.layouts.count < 2 { return ("Добавьте вторую раскладку", "Ясно переключает раскладки, а в системе включена одна.") }
        if !settings.values.enabled { return ("Приостановлено", "Ясно ничего не меняет, пока вы его не включите.") }
        if let report = devices?.report, report.grabbed.isEmpty, let problem = Self.keyboardProblem(report) { return problem }
        if !engine.detectorLoaded { return ("Загрузка словарей…", "") }
        if engine.secureInput { return ("Пауза: ввод пароля", "Во время ввода пароля Ясно не смотрит на клавиатуру.") }
        if settings.isExcluded(engine.currentAppID) {
            let name = engine.currentAppName.isEmpty ? engine.currentAppID : engine.currentAppName
            return ("Пауза в «\(name)»", "Это приложение в исключениях.")
        }
        return ("Работает", "")
    }

    /// Why no keyboard reaches Ясно although it may read keyboards: a key remapper is in the way.
    static func keyboardProblem(_ report: InputDevices.Report) -> (String, String)? {
        let remapper = report.remappers.first ?? "другая программа"
        if report.selfCaptured || report.looped {
            return ("Мешает \(remapper)",
                    "\(remapper) перехватывает и клавиатуру Ясно. Добавьте в её запуск --ignore \"Yasno virtual keyboard\" и перезапустите её.")
        }
        guard !report.busy.isEmpty else { return nil }
        let names = report.busy.joined(separator: ", ")
        if !report.unreadable.isEmpty {
            return ("Нужен доступ к клавиатуре", "Клавиатуру «\(names)» перехватывает \(remapper). Ясно будет читать то, что выдаёт \(remapper), когда вы дадите доступ.")
        }
        return ("Клавиатура занята", "Клавиатуру «\(names)» перехватывает другая программа, поэтому Ясно её не видит.")
    }

    private var setupHint: (String, String) {
        if setupBusy { return ("Настройка доступа…", "") }
        if let report = devices?.report, report.grabbed.isEmpty, !report.busy.isEmpty, !report.unreadable.isEmpty {
            return ("Чтобы работать вместе с \(report.remappers.first ?? "программой, которая перехватывает клавиатуру"), Ясно нужен доступ к её клавиатуре. Система спросит пароль администратора один раз.", "Дать доступ")
        }
        if !accessOK {
            if sink == nil, !FileManager.default.fileExists(atPath: "/dev/uinput") {
                return ("В системе нет /dev/uinput. Ясно не сможет печатать исправления.", "")
            }
            return ("Чтобы видеть нажатия и печатать исправления, Ясно нужен доступ к клавиатуре. Система спросит пароль администратора один раз.", "Дать доступ")
        }
        if Backends.isGnome, engine.backend == nil || engine.backend?.name != "GNOME" {
            return ("Расширение Ясно для GNOME установлено. Выйдите из системы и войдите снова, чтобы оно заработало.", "")
        }
        return ("", "")
    }

    func post() {
        let (status, statusDetail) = statusText
        let (hint, button) = setupHint
        let values = settings.values
        let apps = values.excludedApps.sorted { $0.value.localizedCompare($1.value) == .orderedAscending }
            .map { "\($0.key)\t\($0.value)\n" }.joined()
        let detail = !setupMessage.isEmpty ? setupMessage : (!engine.detail.isEmpty ? engine.detail : statusDetail)
        let updateMessage = updater.available ? updater.message : "Обновления работают в установленной копии."
        let appID = engine.currentAppID
        let monitoring = engine.monitor.enabled
        let key = [status, detail, engine.layoutNames, updateMessage, values.ignoredWords, apps, hint, button,
                   "\(values.enabled)\(monitoring)\(values.correctSpelling)\(Setup.loginEnabled)\(values.automaticUpdates)\(updater.available)\(updater.busy)\(engine.corrections)\(appID)"]
            .joined(separator: "\u{1}")
        guard key != lastPosted else { return }
        lastPosted = key
        let canExclude = !appID.isEmpty && !settings.isExcluded(appID)
        status.withCString { s in detail.withCString { d in engine.layoutNames.withCString { l in
            updateMessage.withCString { u in values.ignoredWords.withCString { w in apps.withCString { a in
                hint.withCString { h in button.withCString { b in
                    var state = yl_ui_state(status: s, detail: d, layouts: l, update_message: u, ignored_words: w,
                                            excluded_apps: a, setup_hint: h, setup_button: b,
                                            enabled: values.enabled ? 1 : 0, monitoring: monitoring ? 1 : 0,
                                            spelling: values.correctSpelling ? 1 : 0, login: Setup.loginEnabled ? 1 : 0,
                                            automatic_updates: values.automaticUpdates ? 1 : 0,
                                            update_available: updater.available ? 1 : 0, update_busy: updater.busy ? 1 : 0,
                                            corrections: Int32(engine.corrections), can_exclude: canExclude ? 1 : 0)
                    yl_ui_post_state(&state)
                } }
            } } }
        } } }
    }

    // MARK: Actions from the window and the tray

    func toggle(_ which: Int32, _ on: Bool) {
        engine.queue.async { [self] in
            switch which {
            case 0:
                settings.update { $0.enabled = on }
                if on { setupMessage = "" }
            case 1: settings.update { $0.correctSpelling = on }
            case 2: Setup.setLogin(on)
            case 3:
                settings.update { $0.automaticUpdates = on }
                updater.schedule()
            default: break
            }
            refresh()
        }
    }

    func action(_ which: Int32) {
        switch Int(which) {
        case Int(YL_ACTION_CHECK_UPDATES): updater.check()
        case Int(YL_ACTION_SETUP): setupAccess()
        case Int(YL_ACTION_QUIT): quit()
        case Int(YL_ACTION_EXCLUDE):
            engine.queue.async { [self] in
                let id = engine.currentAppID
                guard !id.isEmpty else { return }
                let name = engine.currentAppName.isEmpty ? id : engine.currentAppName
                settings.update { $0.excludedApps[id] = name }
                refresh()
            }
        case Int(YL_ACTION_TOGGLE_PAUSE): toggle(0, !settings.values.enabled)
        // The tray calls on the GTK main thread, where the window may be shown.
        case Int(YL_ACTION_SHOW): yl_ui_show()
        default: break
        }
    }

    func ignoredChanged(_ text: String) {
        engine.queue.async { [self] in
            settings.update { $0.ignoredWords = text }
            engine.updateIgnored()
            post()
        }
    }

    func removeApp(_ id: String) {
        engine.queue.async { [self] in
            settings.update { $0.excludedApps.removeValue(forKey: id) }
            refresh()
        }
    }

    private func setupAccess() {
        engine.queue.async { [self] in
            guard !setupBusy else { return }
            setupBusy = true; post()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let asked = Setup.requestPermissions()
                // udev applies the new rule a moment later.
                var granted = false
                for _ in 0..<20 where !granted { usleep(250_000); granted = InputDevices.accessible }
                let ok = granted
                engine.queue.async { [self] in
                    setupBusy = false
                    if ok {
                        setupMessage = ""
                        // The virtual keyboard could not be made before; start again to make it.
                        if sink == nil { restart(into: Setup.resources); return }
                        accessOK = true
                    } else {
                        setupMessage = asked ? "Доступ настроен, но пока не действует. Выйдите из системы и войдите снова."
                            : "Доступ не настроен: пароль администратора не был введён."
                    }
                    refresh()
                }
            }
        }
    }

    // MARK: Quit and restart

    func quit() {
        timer?.cancel()
        devices?.stop()
        yl_ui_quit()
    }

    /// Starts the copy in `directory` once this one has quit (one copy runs at a time).
    func restart(into directory: URL) {
        let binary = directory.appendingPathComponent("yasno").path
        let pid = getpid()
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; exec \"$0\" --background"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, binary]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        // GTK runs the main thread, not Dispatch: quit() only posts to GTK and is safe here.
        quit()
    }

    // MARK: Run

    public static func run(arguments: [String]) -> Int32 {
        let app = App()
        shared = app
        var callbacks = yl_ui_callbacks(
            toggle: { which, value in App.shared?.toggle(which, value != 0) },
            action: { which in App.shared?.action(which) },
            ignored_changed: { text in if let text { App.shared?.ignoredChanged(String(cString: text)) } },
            remove_app: { id in if let id { App.shared?.removeApp(String(cString: id)) } },
            started: { background in App.shared?.started(background: background != 0) })
        var argv = arguments.map { strdup($0) }
        defer { argv.forEach { free($0) } }
        let status = YasnoVersion.current.withCString { version in
            yl_ui_run(Int32(argv.count), &argv, version, &callbacks)
        }
        app.devices?.stop()
        usleep(200_000)
        return status
    }
}

/// Stands in for the virtual keyboard when /dev/uinput cannot be opened.
final class NullSink: KeySink {
    func key(_ code: UInt16, _ value: Int32) {}
    func sync() {}
}
