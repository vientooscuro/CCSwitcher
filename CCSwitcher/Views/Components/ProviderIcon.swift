import SwiftUI

/// A provider's mark, sized like an SF Symbol and tintable by the caller.
///
/// Claude and Gemini use SF Symbols. Codex uses the ChatGPT wordmark glyph,
/// extracted from the installed ChatGPT app and stored as a template asset so it
/// takes the surrounding `foregroundStyle` — the coloured app icon would fight
/// both themes at 12pt and could not go white on a selected segment.
struct ProviderIcon: View {
    let provider: AIProviderType
    var size: CGFloat = 13

    var body: some View {
        switch provider {
        case .codex:
            Image("CodexGlyph")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                // Optical sizing: the glyph is a dense ring, so matching an SF
                // Symbol's cap height makes it read heavier. Trim it slightly.
                .frame(width: size * 0.92, height: size * 0.92)
        case .claudeCode, .gemini:
            Image(systemName: provider.iconName)
                .font(.system(size: size))
        }
    }
}
