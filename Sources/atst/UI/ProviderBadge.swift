import SwiftUI

/// Small coloured chip that identifies a translation provider in the
/// tooltip — the visual analogue to a vendor logo, but built from a
/// letter + brand colour rather than the real logo PNG. Keeps us out of
/// brand-guideline territory and renders crisply at any size.
struct ProviderBadge: View {
    let id: TranslationProviderID

    var body: some View {
        switch id {
        case .google:
            badge(letter: "G", color: Color(red: 66/255, green: 133/255, blue: 244/255))
        case .microsoft:
            // Use the strong red from the Microsoft logo grid for the
            // letter mark — single colour reads cleaner at 18px than
            // attempting a four-square stack.
            badge(letter: "M", color: Color(red: 242/255, green: 80/255, blue: 34/255))
        case .ai:
            sparkleBadge
        }
    }

    private func badge(letter: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color)
                .frame(width: 18, height: 18)
            Text(letter)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var sparkleBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.purple, Color.indigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 18, height: 18)
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}
