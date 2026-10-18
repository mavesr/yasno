import Foundation

let detector = Detector()
let installed = KeyboardLayout.installed(enabledOnly: false)
let layouts = ["ABC", "Russian", "Ukrainian"].map { suffix in
    installed.first { $0.id == "com.apple.keylayout." + suffix }!
}
let keys = ["abc", "ru", "uk"]
func layout(_ key: String) -> KeyboardLayout { layouts[keys.firstIndex(of: key)!] }
struct Fixture: Codable {
    let id: String, category: String, typed: String, source: String, context: String, phase: String
    let preferred: String?, candidates: [String: String], expected: String
    let baseline: String, baseline_replacement: String, local_ms: Double
}
var fixtures: [Fixture] = []
func add(_ id: String, _ category: String, _ typed: String, _ source: String,
         _ context: String = "", _ expected: String = "keep", _ phase: String = "completed", _ preferred: String? = nil) {
    let origin = layout(source)
    var candidates = ["keep": typed]
    for key in keys where key != source {
        if let text = detector.convertTextManually(typed, source: origin, target: layout(key)) {
            candidates[key] = text
        }
    }
    func evaluate() -> Suggestion? {
        if phase == "typing" {
            return detector.suggestWhileTyping(typed, source: origin, layouts: layouts,
                preferredTargetID: preferred.map { layout($0).id }, context: context)
        }
        return detector.suggest(typed, source: origin, layouts: layouts,
            preferredTargetID: preferred.map { layout($0).id }, context: context)
    }
    let suggestion = evaluate()
    let start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<100 { _ = evaluate() }
    let ms = (ProcessInfo.processInfo.systemUptime - start) * 10
    let result = suggestion.flatMap { item in keys.first { layout($0).id == item.target.id } } ?? "keep"
    fixtures.append(Fixture(id: id, category: category, typed: typed, source: source,
        context: context, phase: phase, preferred: preferred, candidates: candidates, expected: expected,
        baseline: result, baseline_replacement: suggestion?.replacement ?? typed, local_ms: ms))
}
func wrong(_ id: String, _ word: String, _ target: String, _ source: String, _ context: String = "", _ category: String = "wrong_layout", _ phase: String = "completed") {
    add(id, category, layout(target).convert(word, to: layout(source))!, source, context, target, phase, "ru")
}
wrong("ru_greeting", "привет", "ru", "abc")
wrong("uk_greeting", "привіт", "uk", "abc")
wrong("en_greeting", "hello", "abc", "ru")
wrong("de_thanks", "danke", "abc", "ru")
wrong("browser", "браузер", "ru", "abc")
wrong("appconnect", "appconnect", "abc", "ru")
wrong("account_domain", "account.apple.com", "abc", "ru", "Открой сайт: ", "domain")
wrong("unknown_domain", "qzx-service123.dev", "abc", "uk", "Ссылка: ", "domain")
wrong("url_path", "https://example.org/path?q=3", "abc", "ru", "Ссылка: ", "domain")
add("pronoun_ru", "context", "ns", "abc", "Привет, как ", "ru", "completed", "uk")
add("pronoun_uk", "context", "ns", "abc", "Привіт, як ", "uk", "completed", "ru")
add("pronoun_ambiguous", "abstain", "ns", "abc")
add("single_ambiguous", "abstain", "z", "abc")
add("single_ru", "context", "b", "abc", "Он ", "ru", "completed", "ru")
add("single_uk", "context", "b", "abc", "Він ", "uk", "completed", "ru")
add("native_uk_collision", "preserve", "бил", "uk", "від ударів ")
add("native_uk", "preserve", "програми", "uk", "Запускаю ")
add("native_ru", "preserve", "программы", "ru", "Запускаю ")
add("native_ru_rare", "preserve", "короткими", "ru", "Привіт, як ти? Пишу ")
for word in ["hello", "host", "web", "code", "API", "SwiftUI", "a", "I", "Jev", "Xcode"] {
    add("preserve_" + word, "preserve", word, "abc", "")
}
for word in ["ChatGPT", "GitHub", "Kubernetes", "TestFlight", "nginx", "webhook", "frontend", "microservices"] {
    wrong("unknown_" + word, word, "abc", "ru", "Настраиваю ", "unknown_word")
}
add("code_identifier", "preserve", "user_id", "abc", "let ")
add("mail", "preserve", "demo@example.com", "abc", "Контакт: ")
add("native_domain", "preserve", "account.apple.com", "abc", "Ссылка: ")
for word in ["acco", "brow", "info", "hell"] { add("prefix_" + word, "prefix", word, "abc", "", "keep", "typing") }
wrong("live_ru", "привет", "ru", "abc", "", "live", "typing")
wrong("live_hello", "hello", "abc", "ru", "", "live", "typing")
wrong("live_domain", "account.apple.com", "abc", "ru", "", "live", "typing")
if CommandLine.arguments.contains("--holdout") {
    fixtures = []
    for word in ["проверка", "здравствуйте", "настройки"] { wrong("hold_ru_" + word, word, "ru", "abc") }
    for word in ["дякую", "налаштування", "сьогодні"] { wrong("hold_uk_" + word, word, "uk", "abc") }
    for word in ["please", "keyboard", "settings"] { wrong("hold_en_" + word, word, "abc", "uk") }
    for word in ["Docker", "PostgreSQL", "Cloudflare", "Supabase", "FastAPI", "TypeScript"] {
        wrong("hold_brand_" + word, word, "abc", "ru", "Настраиваю ", "unknown_word")
    }
    for word in ["TestFlight", "Docker", "docker", "thank", "node.js"] { add("hold_keep_" + word, "preserve", word, "abc") }
    add("hold_keep_uk", "preserve", "налаштування", "uk", "Відкрий ")
    add("hold_keep_ru", "preserve", "больше", "ru", "Хочу ")
    add("hold_ctx_ru", "context", "ns", "abc", "Скажи, как ", "ru", "completed", "uk")
    add("hold_ctx_uk", "context", "ns", "abc", "Скажи, як ", "uk", "completed", "ru")
    add("hold_single_uk", "context", "b", "abc", "Вона ", "uk", "completed", "ru")
    add("hold_single_ru", "context", "b", "abc", "Она ", "ru", "completed", "uk")
    add("hold_abstain", "abstain", "f", "abc")
    for word in ["scre", "buil"] { add("hold_prefix_" + word, "prefix", word, "abc", "", "keep", "typing") }
    add("hold_prefix_ru", "prefix", "пров", "ru", "", "keep", "typing")
    wrong("hold_live_ru", "спасибо", "ru", "abc", "", "live", "typing")
    wrong("hold_live_en", "screen", "abc", "ru", "", "live", "typing")
    wrong("hold_live_domain", "developer.mozilla.org", "abc", "uk", "", "live", "typing")
}
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(fixtures).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("Exported \(fixtures.count) synthetic cases; local correct \(fixtures.filter { $0.baseline == $0.expected }.count)")
