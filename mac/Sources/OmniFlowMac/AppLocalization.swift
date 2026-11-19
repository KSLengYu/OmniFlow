import SwiftUI
import AppKit

extension Notification.Name {
    static let omniFlowLanguageChanged = Notification.Name("OmniFlowLanguageChanged")
}

/// Inline bilingual translation helper preserving exact original Chinese copy while enabling clean English mode.
@inline(__always)
func tr(_ isEnglish: Bool, _ zh: String, _ en: String) -> String {
    isEnglish ? en : zh
}

/// Fetches GitHub profile display name for `@KSLengYu` asynchronously with immediate hardcoded fallback.
@MainActor
final class GitHubProfileSync: ObservableObject {
    static let shared = GitHubProfileSync()

    let username = "KSLengYu"
    let handle = "@KSLengYu"
    let profileURL = URL(string: "https://github.com/KSLengYu")!
    @Published private(set) var displayName: String = "楞宇"
    @Published private(set) var avatarImage: NSImage?
    private var didFetch = false

    private struct GitHubUserDTO: Decodable {
        let login: String?
        let name: String?
        let avatar_url: String?
    }

    func syncIfNeeded() {
        guard !didFetch else { return }
        didFetch = true

        Task { [weak self] in
            guard let apiURL = URL(string: "https://api.github.com/users/KSLengYu") else { return }
            var req = URLRequest(url: apiURL)
            req.timeoutInterval = 4.0
            req.setValue("OmniFlow", forHTTPHeaderField: "User-Agent")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let dto = try? JSONDecoder().decode(GitHubUserDTO.self, from: data) else {
                return
            }

            if let syncedName = dto.name?.trimmingCharacters(in: .whitespacesAndNewlines), !syncedName.isEmpty {
                await MainActor.run { [weak self] in
                    self?.displayName = syncedName
                }
            }
            if let avatarStr = dto.avatar_url, let avatarURL = URL(string: "\(avatarStr)\(avatarStr.contains("?") ? "&" : "?")s=96") {
                var imgReq = URLRequest(url: avatarURL)
                imgReq.timeoutInterval = 4.0
                if let (imgData, _) = try? await URLSession.shared.data(for: imgReq),
                   let img = NSImage(data: imgData) {
                    await MainActor.run { [weak self] in
                        self?.avatarImage = img
                    }
                }
            }
        }
    }
}

/// Vector GitHub Octocat silhouette icon (zero external SVG runtime dependency).
struct GitHubOctocatIcon: View {
    var size: CGFloat = 15

    var body: some View {
        Canvas { ctx, sz in
            let s = min(sz.width, sz.height) / 24.0
            let p = Path { path in
                // GitHub mark silhouette normalized on 24x24 viewBox
                path.move(to: CGPoint(x: 12 * s, y: 1.5 * s))
                path.addCurve(
                    to: CGPoint(x: 1.5 * s, y: 12 * s),
                    control1: CGPoint(x: 6.2 * s, y: 1.5 * s),
                    control2: CGPoint(x: 1.5 * s, y: 6.2 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 8.7 * s, y: 21.95 * s),
                    control1: CGPoint(x: 1.5 * s, y: 16.64 * s),
                    control2: CGPoint(x: 4.51 * s, y: 20.57 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 9.4 * s, y: 21.3 * s),
                    control1: CGPoint(x: 9.22 * s, y: 22.05 * s),
                    control2: CGPoint(x: 9.4 * s, y: 21.72 * s)
                )
                path.addLine(to: CGPoint(x: 9.4 * s, y: 19.05 * s))
                path.addCurve(
                    to: CGPoint(x: 5.55 * s, y: 17.5 * s),
                    control1: CGPoint(x: 6.5 * s, y: 19.68 * s),
                    control2: CGPoint(x: 5.88 * s, y: 17.85 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 4.35 * s, y: 16.0 * s),
                    control1: CGPoint(x: 5.08 * s, y: 16.32 * s),
                    control2: CGPoint(x: 4.4 * s, y: 16.0 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 5.42 * s, y: 15.9 * s),
                    control1: CGPoint(x: 3.4 * s, y: 15.35 * s),
                    control2: CGPoint(x: 4.42 * s, y: 15.38 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 7.05 * s, y: 17.0 * s),
                    control1: CGPoint(x: 6.48 * s, y: 16.0 * s),
                    control2: CGPoint(x: 7.05 * s, y: 17.0 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 9.45 * s, y: 17.6 * s),
                    control1: CGPoint(x: 8.0 * s, y: 18.62 * s),
                    control2: CGPoint(x: 9.52 * s, y: 18.15 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 10.12 * s, y: 16.1 * s),
                    control1: CGPoint(x: 9.55 * s, y: 16.92 * s),
                    control2: CGPoint(x: 9.82 * s, y: 16.45 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 5.28 * s, y: 11.15 * s),
                    control1: CGPoint(x: 7.8 * s, y: 15.84 * s),
                    control2: CGPoint(x: 5.38 * s, y: 14.95 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 6.45 * s, y: 8.2 * s),
                    control1: CGPoint(x: 5.28 * s, y: 10.02 * s),
                    control2: CGPoint(x: 5.68 * s, y: 9.08 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 6.56 * s, y: 5.25 * s),
                    control1: CGPoint(x: 6.32 * s, y: 7.9 * s),
                    control2: CGPoint(x: 5.94 * s, y: 6.68 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 9.48 * s, y: 6.38 * s),
                    control1: CGPoint(x: 6.56 * s, y: 5.25 * s),
                    control2: CGPoint(x: 7.52 * s, y: 4.94 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 14.52 * s, y: 6.38 * s),
                    control1: CGPoint(x: 10.4 * s, y: 6.12 * s),
                    control2: CGPoint(x: 13.6 * s, y: 6.12 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 17.44 * s, y: 5.25 * s),
                    control1: CGPoint(x: 16.48 * s, y: 4.94 * s),
                    control2: CGPoint(x: 17.44 * s, y: 5.25 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 17.55 * s, y: 8.2 * s),
                    control1: CGPoint(x: 18.06 * s, y: 6.68 * s),
                    control2: CGPoint(x: 17.68 * s, y: 7.9 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 18.72 * s, y: 11.15 * s),
                    control1: CGPoint(x: 18.32 * s, y: 9.08 * s),
                    control2: CGPoint(x: 18.72 * s, y: 10.02 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 13.86 * s, y: 16.1 * s),
                    control1: CGPoint(x: 18.62 * s, y: 14.95 * s),
                    control2: CGPoint(x: 16.2 * s, y: 15.84 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 14.6 * s, y: 18.22 * s),
                    control1: CGPoint(x: 14.26 * s, y: 16.45 * s),
                    control2: CGPoint(x: 14.6 * s, y: 17.12 * s)
                )
                path.addLine(to: CGPoint(x: 14.6 * s, y: 21.3 * s))
                path.addCurve(
                    to: CGPoint(x: 15.32 * s, y: 21.95 * s),
                    control1: CGPoint(x: 14.6 * s, y: 21.72 * s),
                    control2: CGPoint(x: 14.78 * s, y: 22.05 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 22.5 * s, y: 12 * s),
                    control1: CGPoint(x: 19.49 * s, y: 20.57 * s),
                    control2: CGPoint(x: 22.5 * s, y: 16.64 * s)
                )
                path.addCurve(
                    to: CGPoint(x: 12 * s, y: 1.5 * s),
                    control1: CGPoint(x: 22.5 * s, y: 6.2 * s),
                    control2: CGPoint(x: 17.8 * s, y: 1.5 * s)
                )
                path.closeSubpath()
            }
            ctx.fill(p, with: .foreground)
        }
        .frame(width: size, height: size)
    }
}

struct GitHubAuthorBadgeButton: View {
    @ObservedObject private var profile = GitHubProfileSync.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            NSWorkspace.shared.open(profile.profileURL)
        }) {
            HStack(spacing: 8) {
                if let avatar = profile.avatarImage {
                    Image(nsImage: avatar)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.8))
                } else {
                    GitHubOctocatIcon(size: 16)
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                }

                VStack(alignment: .leading, spacing: 0.5) {
                    HStack(spacing: 4) {
                        GitHubOctocatIcon(size: 11)
                            .foregroundColor(Color(white: 0.78))
                        Text(profile.displayName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    Text(profile.handle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isHovered ? .white : Color(white: 0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color(white: 0.19) : Color(white: 0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovered ? Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0).opacity(0.45) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("https://github.com/KSLengYu")
        .onAppear { profile.syncIfNeeded() }
    }
}

struct LanguagePillToggle: View {
    @Binding var isEnglish: Bool

    var body: some View {
        HStack(spacing: 0) {
            pillItem(title: "中", active: !isEnglish) {
                if isEnglish { isEnglish = false }
            }
            pillItem(title: "EN", active: isEnglish) {
                if !isEnglish { isEnglish = true }
            }
        }
        .padding(2)
        .background(Color(white: 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
        )
    }

    private func pillItem(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: active ? .bold : .medium))
                .foregroundColor(active ? .white : Color(white: 0.65))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(active ? Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}
