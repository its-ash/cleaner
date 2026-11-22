import SwiftUI

// Shared building blocks for the app's look: rounded "icon tiles" like System
// Settings, soft elevated cards, pills, and banners.

enum Theme {
    static let corner: CGFloat = 14
    static let brandGradient = LinearGradient(
        colors: [Color(red: 0.36, green: 0.42, blue: 1.0), Color(red: 0.62, green: 0.36, blue: 0.98)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static func gradient(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom)
    }
}

/// A white SF Symbol on a rounded, gradient-filled square.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.gradient(color))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            }
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.25), radius: size * 0.12, y: size * 0.05)
    }
}

/// A small coloured capsule label.
struct Pill: View {
    let text: String
    var color: Color = .secondary
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Soft elevated surface used by cards.
struct CardSurface: ViewModifier {
    var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(hovering ? 0.12 : 0.06), radius: hovering ? 12 : 6, y: hovering ? 4 : 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(.separator.opacity(0.45))
            }
    }
}

extension View {
    func cardSurface(hovering: Bool = false) -> some View { modifier(CardSurface(hovering: hovering)) }
}

/// A clickable tile with an icon, a title and a value; lifts on hover.
struct ActionTile: View {
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, color: color, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .offset(x: hovering ? 2 : 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: Theme.corner))
            .cardSurface(hovering: hovering)
            .scaleEffect(hovering ? 1.01 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hovering = h } }
    }
}

/// An inline status message with optional actions.
struct BannerView<Actions: View>: View {
    let text: String
    var isError = false
    var onClose: (() -> Void)?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(isError ? .orange : .green)
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background((isError ? Color.orange : Color.green).opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder((isError ? Color.orange : Color.green).opacity(0.25)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

extension BannerView where Actions == EmptyView {
    init(text: String, isError: Bool = false, onClose: (() -> Void)? = nil) {
        self.init(text: text, isError: isError, onClose: onClose) { EmptyView() }
    }
}

/// A circular usage ring with a label in the middle.
struct UsageRing: View {
    /// Segments as fractions of the whole, drawn in order.
    let segments: [(Double, Color)]
    var lineWidth: CGFloat = 14
    var center: AnyView

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.14), lineWidth: lineWidth)
            ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                let start = segments.prefix(i).reduce(0) { $0 + $1.0 }
                Circle()
                    .trim(from: start, to: min(1, start + seg.0))
                    .stroke(seg.1, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            center
        }
        .animation(.smooth, value: segments.map(\.0))
    }
}
