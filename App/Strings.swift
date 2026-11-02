import Foundation
import SpendWiseCore

/// The app's language (FEATURES.md §4.9): the phone's, or English or Arabic chosen in Settings or
/// on the welcome pages. Like Android's per-app language, the choice switches the text at once;
/// strings come from that language's .lproj, and Arabic shows Western digits (0-9) as receipts do.
enum Lang {
    enum Choice: String, CaseIterable { case phone, en, ar }

    /// Android keeps it in prefs "app_language" / "tag".
    static let key = "app_language"

    static var choice: Choice {
        Choice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .phone
    }

    static func set(_ c: Choice) {
        UserDefaults.standard.set(c == .phone ? nil : c.rawValue, forKey: key)
        cached = nil
    }

    /// The first of the phone's languages the app has (French then Arabic shows Arabic), else English.
    static var phoneCode: String {
        let have = ["en", "ar"]
        for lang in Locale.preferredLanguages {
            let base = String(lang.prefix(2))
            if have.contains(base) { return base }
        }
        return "en"
    }

    static var code: String {
        switch choice {
        case .en: return "en"
        case .ar: return "ar"
        case .phone: return phoneCode
        }
    }

    static var isArabic: Bool { code == "ar" }

    private static var cached: (String, Bundle)?

    /// The .lproj of the app's language.
    static var bundle: Bundle {
        let c = code
        if let cached, cached.0 == c { return cached.1 }
        let b = Bundle.main.path(forResource: c, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        cached = (c, b)
        return b
    }

    /// Text and numbers: the app's language with Latin digits.
    static var formatLocale: Locale { Locale(identifier: isArabic ? "ar@numbers=latn" : "en_US") }

    /// Dates: Arabic months are the Levantine ones (كانون الثاني…), never يناير; digits stay Western.
    static var dateLocale: Locale {
        if isArabic { return Locale(identifier: "ar_LB@numbers=latn") }
        let region = Locale.current.region?.identifier ?? "US"
        return Locale(identifier: "en_\(region)")
    }

    /// The language reports are written in, as the backend's prompt names it.
    static var reportLanguage: String { isArabic ? "Arabic" : "English" }
}

/// Localised text by its Android resource name, with Android's arguments ("%1$s", "%1$d").
func L(_ key: String, _ args: Any...) -> String { Strings.format(Strings.lookup(key), args) }

/// A plural by its Android name for [count], with Android's arguments (the count by default):
/// the form is chosen by the language's rules (Arabic has six), as Android's getQuantityString.
func P(_ key: String, _ count: Int, _ args: Any...) -> String {
    let form = "\(key)#\(Strings.pluralCategory(count))"
    var text = Strings.lookup(form)
    if text == form { text = Strings.lookup("\(key)#other") }
    return Strings.format(text, args.isEmpty ? [count] : args)
}

enum Strings {
    static func lookup(_ key: String) -> String {
        let text = Lang.bundle.localizedString(forKey: key, value: key, table: nil)
        // Android's translatable="false" strings (app_name) exist only in English, as in values/
        return text == key ? english.localizedString(forKey: key, value: key, table: nil) : text
    }

    private static let english: Bundle =
        Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main

    /// CLDR plural categories for English and Arabic.
    static func pluralCategory(_ n: Int) -> String {
        if !Lang.isArabic { return n == 1 ? "one" : "other" }
        let m = n % 100
        switch true {
        case n == 0: return "zero"
        case n == 1: return "one"
        case n == 2: return "two"
        case (3...10).contains(m): return "few"
        case (11...99).contains(m): return "many"
        default: return "other"
        }
    }

    /// Formats "%1$@", "%2$ld", "%s", "%d", "%.1f" and "%%" with Latin digits, whatever the
    /// language, and tolerates forms that skip an argument (Arabic "one" forms often do).
    static func format(_ f: String, _ args: [Any]) -> String {
        if args.isEmpty && !f.contains("%%") { return f }
        var out = ""
        var next = 0
        var i = f.startIndex
        while i < f.endIndex {
            let c = f[i]
            guard c == "%" else { out.append(c); i = f.index(after: i); continue }
            var j = f.index(after: i)
            guard j < f.endIndex else { out.append(c); break }
            if f[j] == "%" { out.append("%"); i = f.index(after: j); continue }
            // %N$
            var digits = ""
            var k = j
            while k < f.endIndex, f[k].isNumber { digits.append(f[k]); k = f.index(after: k) }
            var position: Int?
            if !digits.isEmpty, k < f.endIndex, f[k] == "$" { position = Int(digits); j = f.index(after: k) }
            // flags, width, precision
            var spec = ""
            while j < f.endIndex, "-+ 0#.123456789".contains(f[j]) { spec.append(f[j]); j = f.index(after: j) }
            // length and conversion
            var conversion = ""
            while j < f.endIndex, "hlqLzt".contains(f[j]) { j = f.index(after: j) }
            guard j < f.endIndex else { out += String(f[i...]); break }
            conversion = String(f[j])
            let index = (position.map { $0 - 1 }) ?? next
            next = index + 1
            let arg: Any? = index < args.count ? args[index] : nil
            out += render(arg, conversion, spec)
            i = f.index(after: j)
        }
        return out
    }

    static func render(_ arg: Any?, _ conversion: String, _ spec: String) -> String {
        guard let arg else { return "" }
        switch conversion {
        case "d", "i", "u":
            if let n = arg as? Int { return String(n) }
            if let n = arg as? Int64 { return String(n) }
            if let n = arg as? Int32 { return String(n) }
            if let d = arg as? Double { return String(Int64(d)) }
            return "\(arg)"
        case "f", "e", "g":
            let d = (arg as? Double) ?? (arg as? Int).map(Double.init) ?? 0
            return String(format: "%\(spec)\(conversion)", locale: Locale(identifier: "en_US_POSIX"), d)
        default:
            if let s = arg as? String { return s }
            if let s = arg as? Substring { return String(s) }
            return "\(arg)"
        }
    }
}

/// Core's messages (AI errors, default names, report facts) in the app's language.
func installCoreText() {
    CoreText.text = { key, args in Strings.format(Strings.lookup(key), args.map { $0 as Any }) }
    CoreText.plural = { key, n in P(key, n) }
}

/// A category's name as shown: the built-in Groceries in the app's language; others as named.
/// A category's name as shown: the default ones (stored in English, so they sync and merge the
/// same on every phone) in the app's language; others as the person named them.
func categoryLabel(_ name: String?) -> String {
    guard let name else { return L("groceries") }
    return AppDatabase.defaultCategoryKey(name).map { L($0) } ?? name
}

/// An account's name as shown: its name, else its email, else "Apple account" when Apple hides it.
func accountTitle(_ name: String, _ email: String) -> String {
    switch AccountName.title(name: name, email: email) {
    case .name(let n): return n
    case .email(let e): return e
    case .hidden: return L("apple_account")
    }
}

/// Wraps text that may mix directions (a name or amount in an Arabic sentence) so it keeps its own.
func isolate(_ s: String) -> String { "\u{2068}" + s + "\u{2069}" }

/// Dates in the app's language, from a template ("MMMd" → "Oct 21" / "21 تشرين الأول").
enum Dates {
    private static var cache: [String: DateFormatter] = [:]

    static func format(_ millis: Millis, _ template: String) -> String {
        let key = Lang.code + template
        let f = cache[key] ?? {
            let df = DateFormatter()
            df.locale = Lang.dateLocale
            // Arabic short months on iOS are "تشرين ١"; Android (ar-LB) shows the full Levantine names
            let t = Lang.isArabic ? template.replacingOccurrences(of: "MMMM", with: "MMM").replacingOccurrences(of: "MMM", with: "MMMM") : template
            df.setLocalizedDateFormatFromTemplate(t)
            cache[key] = df
            return df
        }()
        return f.string(from: Date(millis: millis))
    }

    static func reset() { cache = [:] }

    /// "MMMM": this month's name.
    static func monthName(_ date: Date = Date()) -> String { format(date.millis, "MMMM") }
}
