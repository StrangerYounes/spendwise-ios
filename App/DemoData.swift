#if DEBUG
import Foundation
import SpendWiseCore

/// Sample data for screenshots and tests: four months of a household's shopping in Beirut, in
/// English or Arabic (names are the person's own, so they follow the language the demo runs in).
@MainActor
enum DemoData {
    struct Names {
        let milk, eggs, bread, labneh, tomatoes, cucumbers, chicken, halloumi, oil, coffee, gas, detergent, towels, pizza, shawarma, panadol: String
        let spinneys, carrefour, total, pharmacy, malak: String
        let car, eatingOut, household, pharmacyCat: String
        let weekly, gasList, party, household1, dinner, pharmacyList: String
        let chips, juice, cake: String
    }

    static var names: Names {
        Lang.isArabic
            ? Names(milk: "حليب", eggs: "بيض", bread: "خبز عربي", labneh: "لبنة", tomatoes: "بندورة", cucumbers: "خيار", chicken: "صدر دجاج",
                    halloumi: "حلوم", oil: "زيت زيتون", coffee: "قهوة", gas: "بنزين", detergent: "مسحوق غسيل", towels: "محارم مطبخ",
                    pizza: "بيتزا", shawarma: "شاورما", panadol: "بنادول",
                    spinneys: "سبينيس", carrefour: "كارفور", total: "توتال", pharmacy: "صيدلية مازن", malak: "ملك الطاووق",
                    car: "Car", eatingOut: "مطاعم", household: "المنزل", pharmacyCat: "صيدلية",
                    weekly: "تسوق الأسبوع", gasList: "تعبئة بنزين", party: "سهرة السبت", household1: "أغراض البيت", dinner: "عشاء",
                    pharmacyList: "الصيدلية", chips: "شيبس", juice: "عصير", cake: "كاتو")
            : Names(milk: "Milk", eggs: "Eggs", bread: "Arabic bread", labneh: "Labneh", tomatoes: "Tomatoes", cucumbers: "Cucumbers",
                    chicken: "Chicken breast", halloumi: "Halloumi 400g", oil: "Olive oil", coffee: "Coffee", gas: "Gas", detergent: "Detergent",
                    towels: "Paper towels", pizza: "Pizza", shawarma: "Shawarma", panadol: "Panadol",
                    spinneys: "Spinneys", carrefour: "Carrefour", total: "Total", pharmacy: "Pharmacie Mazen", malak: "Malak al Tawouk",
                    car: "Car", eatingOut: "Eating out", household: "Household", pharmacyCat: "Pharmacy",
                    weekly: "Weekly groceries", gasList: "Gas fill-up", party: "Saturday party", household1: "Household", dinner: "Dinner",
                    pharmacyList: "Pharmacy", chips: "Chips", juice: "Juice", cake: "Cake")
    }

    static let day: Millis = 86_400_000

    /// Fills an empty database. Lists are written through the repository, so the item library and
    /// its per-store prices build up exactly as they do when people shop.
    static func load(_ model: AppModel, now: Millis = nowMillis()) {
        let repo = model.repo
        let n = names
        let start = Calendar.current.startOfDay(for: Date(millis: now)).millis + 11 * 3_600_000
        func at(_ daysAgo: Int, _ hour: Int = 0) -> Millis { start - Millis(daysAgo) * day + Millis(hour) * 3_600_000 }
        do {
            try model.database.db.transaction {
                model.updateSettings { $0.currencySymbol = "$"; $0.lastConversionRate = 89_500 }
                // Car is one of the default categories (stored in English, shown in the app's language)
                let car = try model.database.category(named: n.car)?.id
                    ?? repo.insertCategory(SpendWiseCore.Category(name: n.car, color: Int32(bitPattern: 0xFF03A9F4)))
                let eating = try repo.insertCategory(SpendWiseCore.Category(name: n.eatingOut, color: Int32(bitPattern: 0xFFFF9800)))
                let household = try repo.insertCategory(SpendWiseCore.Category(name: n.household, color: Int32(bitPattern: 0xFF9C27B0)))
                let pharmacy = try repo.insertCategory(SpendWiseCore.Category(name: n.pharmacyCat, color: Int32(bitPattern: 0xFFF44336)))
                let spinneys = try repo.insertStore(Store(name: n.spinneys))
                let carrefour = try repo.insertStore(Store(name: n.carrefour))
                let total = try repo.insertStore(Store(name: n.total))
                let mazen = try repo.insertStore(Store(name: n.pharmacy))
                let malak = try repo.insertStore(Store(name: n.malak))

                func bought(_ name: String, _ date: Millis, category: Int64? = nil, store: Int64?, _ items: [(String, Double, String?, Double)]) throws {
                    repo.now = { date }
                    let id = try repo.insertShoppingList(ShoppingList(name: name, createdDate: date - 3_600_000, completedDate: date, isCompleted: true,
                                                                      storeId: store, categoryId: category))
                    for (i, it) in items.enumerated() {
                        try repo.insertShoppingItem(ShoppingItem(listId: id, itemName: it.0, estimatedPrice: it.3, actualPrice: it.3, quantity: it.1,
                                                                 unit: it.2, purchased: true, orderIndex: i))
                    }
                }

                // Weekly groceries for four months, prices creeping up; every other week at Carrefour
                for week in stride(from: 17, through: 1, by: -1) {
                    let drift = 1 + Double(17 - week) * 0.008
                    let store = week % 2 == 0 ? carrefour : spinneys
                    let cheaper = store == carrefour ? 0.94 : 1.0
                    var items: [(String, Double, String?, Double)] = [
                        (n.milk, 2, "l", (1.65 * drift * cheaper * 100).rounded() / 100),
                        (n.eggs, 1, nil, (3.9 * drift * cheaper * 100).rounded() / 100),
                        (n.bread, 2, nil, 0.9),
                        (n.tomatoes, 1.5, "kg", (1.2 * drift * 100).rounded() / 100),
                        (n.cucumbers, 1, "kg", (0.95 * drift * 100).rounded() / 100),
                    ]
                    if week % 2 == 1 { items.append((n.chicken, 1.2, "kg", (7.5 * drift * cheaper * 100).rounded() / 100)) }
                    if week % 3 == 0 { items.append((n.labneh, 1, nil, (3.25 * drift * 100).rounded() / 100)) }
                    if week % 4 == 0 { items.append((n.halloumi, 1, nil, (4.6 * drift * cheaper * 100).rounded() / 100)) }
                    if week % 5 == 0 { items.append((n.coffee, 1, nil, (8.9 * drift * 100).rounded() / 100)) }
                    if week == 9 { items.append((n.oil, 1, "l", 11.5)) }
                    try bought(n.weekly, at(week * 7 + 2), store: store, items)
                }
                // Gas every ten days or so, sometimes as an amount only
                for (i, daysAgo) in [118, 106, 95, 83, 71, 60, 48, 37, 25, 14, 4].enumerated() {
                    let price = ((1.38 + Double(i) * 0.02) * 1000).rounded() / 1000
                    if i == 6 {
                        try bought(n.gasList, at(daysAgo), category: car, store: total, [(n.gas, 1, nil, 40)])
                    } else {
                        try bought(n.gasList, at(daysAgo), category: car, store: total, [(n.gas, Double(24 + i % 4 * 2), "l", price)])
                    }
                }
                try bought(n.dinner, at(40, 9), category: eating, store: malak, [(n.shawarma, 3, nil, 4.5), (n.juice, 3, nil, 2)])
                try bought(n.dinner, at(19, 9), category: eating, store: nil, [(n.pizza, 2, nil, 12)])
                try bought(n.dinner, at(6, 9), category: eating, store: malak, [(n.shawarma, 4, nil, 4.75)])
                try bought(n.household1, at(55), category: household, store: carrefour, [(n.detergent, 1, nil, 9.5), (n.towels, 2, nil, 3.2)])
                try bought(n.household1, at(12), category: household, store: carrefour, [(n.detergent, 1, nil, 9.9), (n.towels, 2, nil, 3.4)])
                try bought(n.pharmacyList, at(30), category: pharmacy, store: mazen, [(n.panadol, 2, nil, 2.75)])

                // Open lists: this week's shop, partly in the cart, and a party to plan
                repo.now = nowMillis
                let weekly = try repo.insertShoppingList(ShoppingList(name: n.weekly, createdDate: at(1), storeId: spinneys))
                let open: [(String, Double, String?, Double?, Bool)] = [
                    (n.milk, 2, "l", 1.79, true), (n.eggs, 1, nil, 4.25, true), (n.bread, 2, nil, 0.9, true),
                    (n.tomatoes, 1, "kg", 1.35, false), (n.labneh, 1, nil, 3.4, false), (n.halloumi, 1, nil, 4.9, false), (n.coffee, 1, nil, nil, false),
                ]
                for (i, it) in open.enumerated() {
                    try repo.insertShoppingItem(ShoppingItem(listId: weekly, itemName: it.0, estimatedPrice: it.3, actualPrice: it.4 ? it.3 : nil,
                                                             quantity: it.1, unit: it.2, purchased: it.4, orderIndex: i))
                }
                let party = try repo.insertShoppingList(ShoppingList(name: n.party, createdDate: at(0, 2)))
                for (i, it) in [(n.chips, 3.0, 1.5), (n.juice, 4.0, 2.0), (n.cake, 1.0, 18.0)].enumerated() {
                    try repo.insertShoppingItem(ShoppingItem(listId: party, itemName: it.0, estimatedPrice: it.2, quantity: it.1, orderIndex: i))
                }

                // A saved AI report
                let lastMonth = AnalysisRequest.lastMonth(now)
                try model.database.insertReport(AiReport(createdAt: at(3, 5), request: Lang.isArabic ? "كيف كان صرفي الشهر الماضي؟" : "How did I spend last month?",
                                                         periodStart: lastMonth.0, periodEnd: lastMonth.1,
                                                         title: Lang.isArabic ? "صرف أيلول" : "September spending", content: report.json))
            }
        } catch {
            print("SpendWise demo data failed: \(error)")
        }
        repo.now = nowMillis
        model.refresh()
    }

    static var report: ReportContent {
        Lang.isArabic
            ? ReportContent(summary: "صرفت 412$ في أيلول، أكثر بـ8% من آب. البقالة ما زالت الأكبر، والبنزين ارتفع سعره كل أسبوع تقريبًا.",
                            facts: [ReportFact(label: "المصروف", value: "$412.30", change: "+8% مقارنة بالفترة السابقة", direction: 1),
                                    ReportFact(label: "المشتريات", value: "11", change: "9 قبلها"),
                                    ReportFact(label: "الفئة الأكبر", value: "البقالة", change: "54% من الصرف"),
                                    ReportFact(label: "أكبر عملية شراء", value: "$47.10", change: "تسوق الأسبوع")],
                            sections: [ReportSection(kind: "prices", heading: "البنزين يرتفع", body: "سعر الليتر ارتفع من 1.46$ إلى 1.54$.", points: ["اشتريت 4 مرات من توتال"]),
                                       ReportSection(kind: "stores", heading: "كارفور أرخص للحليب", body: "الحليب أرخص بـ6% في كارفور.", points: [])],
                            tips: ["اشترِ الحليب والبيض من كارفور.", "عبّئ البنزين أول الأسبوع."], basedOn: "11 عملية شراء، 46 صنفًا")
            : ReportContent(summary: "You spent $412 in September, 8% more than in August. Groceries are still the biggest share, and gas went up almost every week.",
                            facts: [ReportFact(label: "Spent", value: "$412.30", change: "+8% vs previous", direction: 1),
                                    ReportFact(label: "Purchases", value: "11", change: "9 before"),
                                    ReportFact(label: "Top category", value: "Groceries", change: "54% of spending"),
                                    ReportFact(label: "Biggest purchase", value: "$47.10", change: "Weekly groceries")],
                            sections: [ReportSection(kind: "prices", heading: "Gas keeps climbing", body: "A litre went from $1.46 to $1.54.", points: ["Filled up 4 times at Total"]),
                                       ReportSection(kind: "stores", heading: "Carrefour is cheaper for milk", body: "Milk is 6% cheaper at Carrefour than at Spinneys.", points: [])],
                            tips: ["Buy milk and eggs at Carrefour.", "Fill up early in the week."], basedOn: "11 purchases, 46 items")
    }

    static let basePrompts: [String: String] = [
        "quickAdd": "You turn what a person says or types about their shopping into purchases.\nKnown categories: [categories]\nKnown stores: [stores]\nKnown items: [knownItems]\nToday is [today].",
        "receipt": "Read this receipt photo into a purchase: store, date, currency and every line.\nKnown items: [knownItems]",
        "analysisReport": "Write a short spending report in [language] from these figures:\n[data]",
    ]

    // MARK: - What the AI answers in demo mode

    /// A quick add as the AI answers "filled gas for 40 and milk and bread at Spinneys", plus to-buy items.
    static var quickAddAnswer: String {
        let n = names
        return """
        {"transcript": \(Lang.isArabic ? "\"عبّيت بنزين بـ40 وجبت حليب وخبز من سبينيس، وبدنا بيض\"" : "\"filled gas for 40, got milk and bread at Spinneys for 6, and we need eggs\""),
         "purchases": [
          {"bought": true, "listName": "\(n.gasList)", "category": "\(n.car)", "store": "\(n.total)", "date": null,
           "items": [{"name": "\(n.gas)", "quantity": 1, "unit": null, "unitPrice": null, "totalPrice": 40}]},
          {"bought": true, "listName": "\(n.weekly)", "category": "Groceries", "store": "\(n.spinneys)", "date": null,
           "items": [{"name": "\(n.milk)", "quantity": 2, "unit": "l", "unitPrice": null, "totalPrice": 3.6},
                     {"name": "\(n.bread)", "quantity": 1, "unitPrice": 2.4, "totalPrice": null}]},
          {"bought": false, "listName": "\(n.party)", "existingList": "\(n.party)", "items": [{"name": "\(n.eggs)", "quantity": 1}]}
         ]}
        """
    }

    /// A receipt in lira (converted at the saved rate), one line looking like a pack of three.
    static var receiptAnswer: String {
        let n = names
        return """
        {"store": "\(n.spinneys)", "date": null, "currency": "LBP", "listName": "\(n.weekly)", "category": "Groceries", "existingList": "\(n.weekly)",
         "items": [
          {"name": "\(n.tomatoes)", "listItem": "\(n.tomatoes)", "quantity": 1.2, "unit": "kg", "unitPrice": 120000, "totalPrice": 144000},
          {"name": "\(n.labneh)", "listItem": "\(n.labneh)", "quantity": 1, "unitPrice": 295000, "totalPrice": 295000},
          {"name": "\(n.halloumi)", "listItem": null, "quantity": 1, "unitPrice": 1180000, "totalPrice": 1180000},
          {"name": "\(n.coffee)", "listItem": "\(n.coffee)", "quantity": 1, "unitPrice": 815000, "totalPrice": 815000}
         ]}
        """
    }

    static var analysisRequestAnswer: String {
        let (start, end) = AnalysisRequest.lastMonth(nowMillis())
        return """
        {"transcript": \(Lang.isArabic ? "\"كيف كان صرفي الشهر الماضي؟\"" : "\"How did I spend last month?\""), "startDate": "\(AiPayload.day(start))", "endDate": "\(AiPayload.day(end))",
         "focus": [], "category": null, "store": null, "item": null, "question": null}
        """
    }

    static var reportAnswer: String {
        let r = report
        return JSON.object([
            ("title", .string(Lang.isArabic ? "صرف الشهر الماضي" : "Last month's spending")),
            ("summary", .string(r.summary)),
            ("sections", .array(r.sections.map { .object([("kind", .string($0.kind)), ("heading", .string($0.heading)), ("body", .string($0.body)),
                                                         ("points", .array($0.points.map(JSON.string)))]) })),
            ("tips", .array(r.tips.map(JSON.string))),
        ]).text
    }
}
#endif
