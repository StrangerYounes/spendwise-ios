import Foundation

/// Text that code in Core shows to people (error messages, default names, report facts), looked up
/// by the Android string's name. The app points these at its Localizable.strings (English or
/// Arabic); until then (and in tests) the English below is used.
public enum CoreText {
    /// A string by key, formatted with its arguments ("%1$@", "%1$ld").
    public static var text: (String, [CVarArg]) -> String = { key, args in
        let format = english[key] ?? key
        return args.isEmpty ? format : String(format: format, locale: Locale(identifier: "en_US_POSIX"), arguments: args)
    }

    /// A plural by key for a count ("3 items").
    public static var plural: (String, Int) -> String = { key, n in
        guard let forms = englishPlurals[key] else { return "\(key) \(n)" }
        return String(format: n == 1 ? forms.one : forms.other, locale: Locale(identifier: "en_US_POSIX"), n)
    }

    static let english: [String: String] = [
        "ai_broken": "The AI's answer came back broken. Try again.",
        "ai_empty": "The AI's answer came back empty. Try again.",
        "ai_offline": "Couldn't reach the AI. Check your internet connection.",
        "ai_consent_off": "AI features are off. Turn them on in Settings → AI features.",
        "ai_signin_expired": "Your sign-in has expired. Sign in again in Settings.",
        "ai_cant_take": "The AI couldn't take that request.",
        "ai_invalid": "The AI couldn't take that request. Try again, or contact us if it keeps happening.",
        "ai_unauth": "The AI didn't accept this copy of the app. Try again later.",
        "ai_slow": "The AI took too long to answer. Try again.",
        "ai_down": "The AI isn't working right now. Try again later.",
        "receipt_list_name": "Receipt",
        "receipt_currency": "receipt currency",
        "report_empty": "The report came back empty. Try again.",
        "spending_report": "Spending report",
        "restored": "Restored %1$@, %2$@, %3$@",
        "restored_reports": ", %1$ld AI reports",
        "groceries": "Groceries",
        "fact_spent": "Spent",
        "fact_purchases": "Purchases",
        "fact_top_category": "Top category",
        "fact_biggest_purchase": "Biggest purchase",
        "fact_vs_previous": "%1$@ vs previous",
        "fact_before": "%1$ld before",
        "fact_of_spending": "%1$ld%% of spending",
        "based_on": "%1$@, %2$@",
        "not_a_backup": "This file does not look like a SpendWise backup",
    ]

    static let englishPlurals: [String: (one: String, other: String)] = [
        "items_count": ("%ld item", "%ld items"),
        "lists_count": ("%ld list", "%ld lists"),
        "library_items_n": ("%ld library item", "%ld library items"),
        "purchases_n": ("%ld purchase", "%ld purchases"),
        "restored_skipped": (" (%ld list already existed)", " (%ld lists already existed)"),
    ]
}

func str(_ key: String, _ args: CVarArg...) -> String { CoreText.text(key, args) }

func plural(_ key: String, _ n: Int) -> String { CoreText.plural(key, n) }
