import AppKit

/// Shared green/orange/red thresholds for the token-usage gauge, used by the
/// menu bar icon (AppDelegate), the popover's token label
/// (StatusViewController), so they always agree.
enum TokenGauge {
    enum Tier {
        case normal
        case warning
        case critical
    }

    static func tier(forRatio ratio: Double) -> Tier {
        switch ratio {
        case ..<0.5: return .normal
        case ..<0.85: return .warning
        default: return .critical
        }
    }

    static func color(forRatio ratio: Double) -> NSColor {
        color(for: tier(forRatio: ratio))
    }

    static func color(for tier: Tier) -> NSColor {
        switch tier {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}
