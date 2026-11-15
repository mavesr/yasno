import Foundation
import SwitchCore
import CYasnoLinux

/// `yasno --diagnose`: what Yasno sees here, for a bug report or a quick check after setup.
public enum Diagnose {
    public static func run() -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        print("Ясно \(YasnoVersion.current) (\(Updater.architecture))")
        print("Рабочий стол: \(environment["XDG_CURRENT_DESKTOP"] ?? "?"), сеанс: \(environment["XDG_SESSION_TYPE"] ?? "?")")
        print("Доступ к клавиатуре: \(InputDevices.accessible ? "есть" : "нет") (/dev/uinput \(yl_access_ok("/dev/uinput", 1) != 0 ? "доступен" : "недоступен"))")
        guard let backend = Backends.detect() else {
            print("Раскладки: не удалось узнать (нет поддерживаемого рабочего стола)")
            return 1
        }
        let specs = backend.layouts()
        print("Источник раскладок: \(backend.name)")
        for (index, spec) in specs.enumerated() {
            let table = XkbTables.layout(spec)
            let languages = (KeyboardLayout.languages(forID: spec.id) ?? []).map { "\($0)" }.joined(separator: ",")
            print("  \(index == backend.currentIndex() ? "*" : " ") \(spec.id) «\(spec.name)» таблица: \(table == nil ? "нет" : "есть") языки: \(languages.isEmpty ? "—" : languages)")
        }
        if let app = backend.focusedApplication() { print("Активное приложение: \(app.id) «\(app.name)»") }
        print("Ввод пароля: \(backend.secure() ? "да" : "нет")")
        let words: [(String, String, Language)] = [("привет", "ru", .russian), ("привіт", "uk", .ukrainian), ("hello", "en", .english), ("hallo", "de", .german)]
        print("Словари: " + words.map { "\($0.1) \(SystemLexicon.shared.knows($0.0, language: $0.2) == true ? "есть" : "нет")" }.joined(separator: ", "))
        print("Обновления: \(Updater.runningInstall()?.path ?? "не установленная копия")")
        return 0
    }
}
