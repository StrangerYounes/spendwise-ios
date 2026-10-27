import SwiftUI
import UIKit
import SpendWiseCore

// Small pieces the screens share (Android ui/components/Common.kt, Guide.kt, AmountField.kt,
// LockedSheet.kt and the Premium badge).

/// A dot of a category's colour.
struct ColorDot: View {
    let color: Color
    var size: CGFloat = 10
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

/// Category chip: tinted background, readable label in both themes.
struct CategoryChip: View {
    let name: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            ColorDot(color: color, size: 8)
            Text(categoryLabel(name)).font(.labelM).foregroundStyle(Palette.onSurface).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(Palette.onPrimaryContainer)
                .frame(width: 72, height: 72)
                .background(Palette.primaryContainer, in: Circle())
            Text(title).font(.titleM).multilineTextAlignment(.center).foregroundStyle(Palette.onSurface)
            Text(message).font(.bodyM).foregroundStyle(Palette.onSurfaceVariant).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.titleS).foregroundStyle(Palette.primary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
    }
}

/// The gold PREMIUM badge, with a sparkle and a sweeping shine.
struct PremiumBadge: View {
    @State private var shine = false
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles").font(.system(size: 9, weight: .bold))
            Text(L("premium_badge")).font(.system(size: 10, weight: .heavy)).tracking(0.6)
        }
        .foregroundStyle(Color(rgb: 0x3A2600))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(LinearGradient(colors: [Palette.goldLight, Palette.gold], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
        .overlay(
            GeometryReader { g in
                LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width / 2)
                    .offset(x: shine ? g.size.width * 1.2 : -g.size.width * 0.7)
            }
            .clipShape(Capsule())
            .allowsHitTesting(false)
        )
        .fixedSize()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false).delay(0.8)) { shine = true }
        }
        .accessibilityLabel(L("premium_badge"))
    }
}

/// A step of the first-run guide: what to do next, with a way out of the guide.
struct GuideCard: View {
    let icon: String
    let title: String
    let message: String
    let actionLabel: String
    let action: () -> Void
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.onTertiary)
                    .frame(width: 40, height: 40)
                    .background(Palette.tertiary, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.titleM)
                    Text(message).font(.bodyM)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(actionLabel, action: action)
                .font(.labelL)
                .foregroundStyle(Palette.tertiary)
                .padding(.vertical, 10).padding(.horizontal, 8)
        }
        .foregroundStyle(Palette.onTertiaryContainer)
        .padding(.leading, 16).padding(.trailing, 8).padding(.top, 16).padding(.bottom, 2)
        .card(Palette.tertiaryContainer)
    }
}

extension View {
    /// Gently grows and shrinks what the guide points at.
    func pulse(_ on: Bool) -> some View { modifier(Pulse(on: on)) }
}

private struct Pulse: ViewModifier {
    let on: Bool
    @State private var big = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(on && big ? 1.08 : 1)
            .onAppear { if on { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { big = true } } }
            .onChange(of: on) { _, now in
                if now { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { big = true } } else { big = false }
            }
    }
}

/// In place of a drag handle: sheets close only with this ✕ (or by finishing), never by a swipe.
struct SheetCloseBar: View {
    let close: () -> Void
    var body: some View {
        HStack {
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.onSurfaceVariant)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(L("close"))
        }
        .padding(.horizontal, 4)
    }
}

/// The message bar at the bottom: dark in both themes, with an action (Undo) when there is one.
struct SnackbarHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let snack = model.snack {
                HStack(spacing: 12) {
                    Text(snack.message).font(.bodyM).foregroundStyle(Palette.onSnackbar).frame(maxWidth: .infinity, alignment: .leading)
                    if let label = snack.actionLabel {
                        Button(label) {
                            snack.action?()
                            model.snack = nil
                        }
                        .font(.labelL).foregroundStyle(Palette.snackbarAction)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Palette.snackbar, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                .padding(.horizontal, 12).padding(.bottom, 12)
                .readableWidth()
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(snack.id)
                .onAppear {
                    task?.cancel()
                    task = Task {
                        try? await Task.sleep(for: .seconds(snack.seconds))
                        if !Task.isCancelled, model.snack?.id == snack.id { withAnimation { model.snack = nil } }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.snack)
    }
}

extension View {
    func snackbarHost() -> some View { modifier(SnackbarHost()) }
    /// Floating buttons move up while the message bar shows, as on Android (Scaffold's FAB).
    func clearOfSnackbar() -> some View { modifier(ClearOfSnackbar()) }
}

struct ClearOfSnackbar: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content
            .padding(.bottom, model.snack == nil ? 0 : 60)
            .animation(.easeInOut(duration: 0.2), value: model.snack == nil)
    }
}

/// A price box that also does sums ("89500/3", "2×1.5"): the number keyboard has no + − × ÷, so
/// they show as keys under the box while it's being typed in; the result shows as "= 29833.33"
/// and replaces the sum when the box is left.
struct AmountField: View {
    let title: String
    @Binding var text: String
    var currency: String? = nil
    var onSubmit: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        let sum = isSum(text)
        let result = sum ? parseAmount(text) : nil
        let unfinished = text.trimmingCharacters(in: .whitespaces).last.map { "+-*/×÷−(".contains($0) } ?? false
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.labelM).foregroundStyle(focused ? Palette.primary : Palette.onSurfaceVariant)
            HStack(spacing: 4) {
                if let currency, !Lang.isArabic { Text(currency).foregroundStyle(Palette.onSurfaceVariant) }
                TextField("", text: Binding(get: { text }, set: { text = String($0.filter { $0.isNumber || ".,٫،٬+-*/×÷−() ".contains($0) }) }))
                    .keyboardType(.decimalPad)
                    .focused($focused)
                    .multilineTextAlignment(.leading)
                    .onSubmit { onSubmit?() }
                if let currency, Lang.isArabic { Text(currency).foregroundStyle(Palette.onSurfaceVariant) }
            }
            .environment(\.layoutDirection, .leftToRight)
            .fieldStyle(error: sum && result == nil && !unfinished && !focused, focused: focused)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            if sum {
                Text(result.map { "= \(formatPriceInput($0))" } ?? ((unfinished || focused) ? "=" : L("sum_unreadable")))
                    .font(.bodyS)
                    .foregroundStyle(sum && result == nil && !unfinished && !focused ? Palette.error : Palette.onSurfaceVariant)
            }
            if focused {
                HStack(spacing: 4) {
                    ForEach(["+", "−", "×", "÷"], id: \.self) { op in
                        Button { text += op } label: {
                            Text(op).font(.titleM).frame(maxWidth: .infinity, minHeight: 36)
                                .foregroundStyle(Palette.onSecondaryContainer)
                                .background(Palette.secondaryContainer, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plainRow)
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
            }
        }
        .onChange(of: focused) { was, now in
            // Leaving the box: the sum becomes its result
            if was && !now, isSum(text), let v = parseAmount(text) { text = formatPriceInput(v) }
        }
    }
}

/// A labelled text field in the Android outlined style.
struct LabeledField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboard: UIKeyboardType = .default
    var autofocus = false
    var submitLabel: SubmitLabel = .done
    var onSubmit: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.labelM).foregroundStyle(focused ? Palette.primary : Palette.onSurfaceVariant)
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .focused($focused)
                .submitLabel(submitLabel)
                .onSubmit { onSubmit?() }
                .fieldStyle(focused: focused)
        }
        .onAppear {
            if autofocus { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true } }
        }
    }
}

/// Category menu used when creating or editing a list; nil means Groceries.
struct CategoryPicker: View {
    let categories: [SpendWiseCore.Category]
    @Binding var selected: Int64?

    var body: some View {
        let groceries = categories.first { $0.name == "Groceries" }
        let current = categories.first { $0.id == selected } ?? groceries
        VStack(alignment: .leading, spacing: 4) {
            Text(L("category")).font(.labelM).foregroundStyle(Palette.onSurfaceVariant)
            Menu {
                ForEach(categories.sorted { ($0.name != "Groceries" ? 1 : 0) < ($1.name != "Groceries" ? 1 : 0) }) { c in
                    Button {
                        // Groceries is stored as nil, as lists were always saved
                        selected = c.name == "Groceries" ? nil : c.id
                    } label: {
                        Label(categoryLabel(c.name), systemImage: c.id == current?.id ? "checkmark" : "circle.fill")
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    ColorDot(color: Color(argb: current?.color ?? AppDatabase.groceriesColor), size: 12)
                    Text(categoryLabel(current?.name)).foregroundStyle(Palette.onSurface)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Palette.onSurfaceVariant)
                }
                .fieldStyle()
            }
        }
    }
}

/// A thin progress bar with round ends.
struct ProgressBar: View {
    let value: Double
    var color: Color = Palette.primary
    var track: Color = Palette.surfaceVariant
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: height)
        .environment(\.layoutDirection, Lang.isArabic ? .rightToLeft : .leftToRight)
    }
}

/// A row in a menu-like list with an icon.
struct IconRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = Palette.onSurfaceVariant
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bodyL).foregroundStyle(Palette.onSurface)
                if let subtitle { Text(subtitle).font(.bodyS).foregroundStyle(Palette.onSurfaceVariant) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

/// A pending confirmation: shown as an alert by `.confirm(_:)`.
struct Confirm: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let label: String
    var destructive = true
    let action: () -> Void
}

extension View {
    func confirm(_ request: Binding<Confirm?>) -> some View {
        alert(request.wrappedValue?.title ?? "", isPresented: Binding(get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }),
              presenting: request.wrappedValue) { r in
            Button(r.label, role: r.destructive ? .destructive : nil) { r.action() }
            Button(L("cancel"), role: .cancel) {}
        } message: { r in
            Text(r.message)
        }
    }
}

/// A screen's background and the navigation bar's look.
extension View {
    func screen(_ title: String) -> some View {
        self
            .background(Palette.surface.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.surface, for: .navigationBar)
    }
}
