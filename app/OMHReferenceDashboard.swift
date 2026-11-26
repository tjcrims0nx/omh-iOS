import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let ink = Color(red: 0.035, green: 0.026, blue: 0.045)
private let panel = Color(red: 0.075, green: 0.055, blue: 0.095)
private let purple = Color(red: 0.78, green: 0.18, blue: 1)
private let muted = Color(red: 0.73, green: 0.67, blue: 0.79)

private struct Provider: Codable, Identifiable {
    let id: String
    let label: String
    let model: String
    let available: Bool
}
private struct Message: Codable, Identifiable {
    var id = UUID()
    let role: String
    let content: String
    var date = Date()
}
private struct Conversation: Codable, Identifiable {
    var id = UUID()
    var messages: [Message] = []
    var title: String { String(messages.first(where: { $0.role == "user" })?.content.prefix(48) ?? "New chat") }
}
private struct ProviderResponse: Decodable { let providers: [Provider] }
private struct SessionResponse: Decodable { let csrf: String }
private struct ChatResponse: Decodable { let text: String }
private struct ChatPayload: Encodable {
    struct Entry: Encodable { let role: String; let content: String }
    let provider: String
    let messages: [Entry]
}
@MainActor private final class DashboardModel: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var selected = UserDefaults.standard.string(forKey: "omh.chat.selectedProvider.v1") ?? ""
    @Published var conversations: [Conversation] = []
    @Published var active = UUID()
    @Published var draft = ""
    @Published var busy = false
    @Published var status = ""
    let base: URL
    private let key = "omh.swiftui.conversations.v1"
    init(base: URL) {
        self.base = base
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = saved
        } else if let legacy = UserDefaults.standard.array(forKey: "omh.chat.history.v1") as? [[String: String]] {
            let messages = legacy.compactMap { row -> Message? in
                guard let role = row["role"], let content = row["content"], ["user","assistant"].contains(role) else { return nil }
                return Message(role: role, content: content)
            }
            if !messages.isEmpty { conversations = [Conversation(messages: messages)] }
        }
        if let first = conversations.first { active = first.id } else { newChat() }
    }
    var messages: [Message] { conversations.first(where: { $0.id == active })?.messages ?? [] }
    var provider: Provider? { providers.first(where: { $0.id == selected && $0.available }) }
    func select(_ p: Provider) {
        selected = p.id
        UserDefaults.standard.set(p.id, forKey: "omh.chat.selectedProvider.v1")
        status = ""
    }
    func save() {
        if let data = try? JSONEncoder().encode(conversations) { UserDefaults.standard.set(data, forKey: key) }
    }
    func newChat() {
        guard !busy else { return }
        let c = Conversation()
        conversations.insert(c, at: 0); active = c.id; draft = ""; save()
    }
    func request(_ path: String, body: Data? = nil, csrf: String? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: body == nil ? 15 : 30)
        if let body {
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(csrf, forHTTPHeaderField: "x-omh-csrf")
            var origin = "\(base.scheme ?? "http")://\(base.host ?? "127.0.0.1")"
            if let port = base.port { origin += ":\(port)" }
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "OMH", code: code, userInfo: [NSLocalizedDescriptionKey: "Runtime request failed (HTTP \(code))."])
        }
        return data
    }
    func refresh() async {
        do {
            providers = try JSONDecoder().decode(ProviderResponse.self, from: await request("/api/chat")).providers
            status = providers.contains(where: { $0.available }) ? "" : "Configure a provider in Settings to start."
        } catch { status = error.localizedDescription }
    }
    func send() async {
        guard !busy, let provider, let index = conversations.firstIndex(where: { $0.id == active }) else { return }
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= 8000 else { status = "Enter a message of up to 8,000 characters."; return }
        let conversationID = active
        let user = Message(role: "user", content: input)
        var context = Array((conversations[index].messages + [user]).suffix(16))
        while context.count > 1 && context.reduce(0, { $0 + $1.content.count }) > 18000 { context.removeFirst() }
        busy = true; status = ""
        defer { busy = false }
        do {
            let body = try JSONEncoder().encode(ChatPayload(provider: provider.id, messages: context.map { .init(role: $0.role, content: $0.content) }))
            guard body.count <= 22000 else { status = "Conversation exceeds the request limit."; return }
            let token = try JSONDecoder().decode(SessionResponse.self, from: await request("/api/session")).csrf
            let reply = try JSONDecoder().decode(ChatResponse.self, from: await request("/api/chat", body: body, csrf: token))
            if let i = conversations.firstIndex(where: { $0.id == conversationID }) {
                conversations[i].messages += [user, Message(role: "assistant", content: reply.text)]
                conversations[i].messages = Array(conversations[i].messages.suffix(50))
                save()
            }
            if draft == input { draft = "" }
        } catch { status = error.localizedDescription }
    }
}

private struct PurpleWave: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0, paused: reduceMotion || scenePhase != .active)) { timeline in
            Canvas { context, size in
                let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 12) * .pi / 6
                var path = Path()
                for i in 0...180 {
                    let u = Double(i) / 180
                    let envelope = pow(sin(.pi * u), 1.3)
                    let y = 0.78 - envelope * (0.30 + 0.23 * sin(8*u - phase) + 0.09 * sin(15*u + phase))
                    let point = CGPoint(x: size.width * u, y: size.height * y)
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                let gradient = GraphicsContext.Shading.linearGradient(Gradient(colors: [.clear, purple, Color.purple.opacity(0.9), .clear]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
                for (width, blur, opacity) in [(CGFloat(15), CGFloat(18), 0.23), (7, 9, 0.5), (2, 3, 0.9)] {
                    var glow = context
                    glow.opacity = opacity
                    glow.addFilter(.blur(radius: blur))
                    glow.stroke(path, with: gradient, lineWidth: width)
                }
                context.stroke(path, with: gradient, lineWidth: 1.5)
            }
        }.accessibilityHidden(true)
    }
}

@MainActor private struct ReferenceDashboard: View {
    @StateObject var model: DashboardModel
    let settings: () -> Void
    let workspace: () -> Void
    let runtime: () -> Void
    @State private var sidebar = true
    @State private var importing = false
    @State private var showFileError = false
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700
            HStack(spacing: 0) {
                if wide && sidebar {
                    sidebarView.frame(width: geometry.size.width * 0.26)
                    Rectangle().fill(purple.opacity(0.13)).frame(width: 1)
                }
                VStack(spacing: 0) {
                    header(wide: wide)
                    Rectangle().fill(purple.opacity(0.13)).frame(height: 1)
                    ScrollViewReader { scroll in
                        ScrollView {
                            VStack(spacing: 22) {
                                hero
                                ForEach(model.messages) { message in bubble(message).id(message.id) }
                                if model.busy { HStack { brand.frame(width: 38, height: 38); ProgressView().tint(purple); Spacer() } }
                                Color.clear.frame(height: 1).id("bottom")
                            }.padding(.horizontal, 24).padding(.bottom, 24)
                        }.onChange(of: model.messages.count) { _ in withAnimation { scroll.scrollTo("bottom", anchor: .bottom) } }
                    }
                    if !model.status.isEmpty { Text(model.status).font(.caption).foregroundStyle(muted).padding(.horizontal) }
                    composer.padding(.horizontal, 24).padding(.bottom, 12).padding(.top, 8)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ink).preferredColorScheme(.dark).tint(purple)
        .accessibilityIdentifier("omh.native.dashboard")
        .task { await model.refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                guard let data = try handle.read(upToCount: 8001), data.count <= 8000, let content = String(data: data, encoding: .utf8) else { showFileError = true; return }
                model.draft += "\n" + content
            } catch { showFileError = true }
        }
        .alert("Could not import text", isPresented: $showFileError) { Button("OK", role: .cancel) {} }
    }
    private var brand: some View {
        Image("OMHBrandMark").resizable().scaledToFit().accessibilityLabel("OpenMind Harness logo")
    }
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 8) {
                brand.frame(width: 36, height: 36)
                Text("OpenMind\nHarness").font(.headline)
                Spacer(minLength: 0)
                Button { sidebar = false } label: { Image(systemName: "chevron.left.2") }.accessibilityLabel("Collapse sidebar")
            }.padding(.bottom, 12)
            Button { model.newChat() } label: {
                Label("New chat", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(13)
                    .background(LinearGradient(colors: [purple.opacity(0.38), purple.opacity(0.22)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(purple, lineWidth: 1))
            }.disabled(model.busy)
            nav("Chat", "message", selected: true) {}
            nav("Runtime", "gauge.with.dots.needle.33percent", action: runtime)
            nav("Settings", "gearshape", action: settings)
            Divider().overlay(purple.opacity(0.25))
            Text("Recent chats").foregroundStyle(muted).font(.subheadline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.conversations.filter { !$0.messages.isEmpty }) { chat in
                        Button { model.active = chat.id; model.draft = "" } label: {
                            HStack(alignment: .top) {
                                Image(systemName: "message").foregroundStyle(muted)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chat.title).font(.subheadline).lineLimit(2)
                                    if let last = chat.messages.last { Text(last.date, style: .relative).font(.caption).foregroundStyle(muted) }
                                }
                                Spacer(minLength: 0)
                            }
                        }.disabled(model.busy)
                    }
                }
            }
            Spacer(minLength: 0)
        }.buttonStyle(.plain).padding(16).frame(maxHeight: .infinity, alignment: .top)
            .background(LinearGradient(colors: [ink, panel.opacity(0.5)], startPoint: .top, endPoint: .bottom))
            .accessibilityIdentifier("omh.native.sidebar")
    }
    private func nav(_ title: String, _ icon: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .foregroundStyle(selected ? purple : .white)
                .background(selected ? purple.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.accessibilityIdentifier("omh.native.sidebar." + title.lowercased())
    }
    private func header(wide: Bool) -> some View {
        HStack(spacing: 12) {
            if !wide || !sidebar {
                Menu {
                    Button("New chat") { model.newChat() }
                    Button("Runtime", action: runtime)
                    Button("Workspace", action: workspace)
                    if wide { Button("Expand sidebar") { sidebar = true } }
                    ForEach(model.conversations.filter { !$0.messages.isEmpty }) { chat in Button(chat.title) { if !model.busy { model.active = chat.id } } }
                } label: { Image(systemName: "sidebar.left").frame(width: 44, height: 44) }
            }
            brand.frame(width: 34, height: 34).accessibilityIdentifier("omh.native.brand.logo")
            Text(wide ? "OpenMind Harness" : "OMH").font(.headline).lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                ForEach(model.providers) { p in Button(p.label + " — " + p.model) { model.select(p) }.disabled(!p.available || model.busy) }
                Button("Refresh providers") { Task { await model.refresh() } }
            } label: {
                HStack { Image(systemName: "cube").foregroundStyle(purple); Text(model.provider?.model ?? "Choose provider").lineLimit(1); Image(systemName: "chevron.down").font(.caption) }
                    .padding(10).overlay(RoundedRectangle(cornerRadius: 12).stroke(purple.opacity(0.4)))
            }.accessibilityIdentifier("omh.native.chat.provider")
            Button(action: settings) { Image(systemName: "gearshape").frame(width: 44, height: 44).overlay(RoundedRectangle(cornerRadius: 12).stroke(purple.opacity(0.4))) }
                .accessibilityIdentifier("omh.native.settings").accessibilityLabel("Settings")
        }.buttonStyle(.plain).padding(.horizontal, 22).padding(.vertical, 12)
    }
    private var hero: some View {
        VStack(spacing: 16) {
            PurpleWave().frame(height: 125)
            Text("How can OpenMind Harness\nhelp today?").font(.system(size: 29, weight: .bold)).multilineTextAlignment(.center)
            Text("Chat, build, and run with your preferred models — all in one place.").font(.subheadline).foregroundStyle(muted).multilineTextAlignment(.center)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { cards }
                VStack(spacing: 10) { cards }
            }.padding(.top, 12)
        }.padding(.bottom, 24)
    }
    private var cards: some View {
        ForEach(["Write and refactor code", "Design an AI workflow", "Explore model options"], id: \.self) { title in
            Button { if title == "Explore model options" { settings() } else { model.draft = title + ": " } } label: {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: title.hasPrefix("Write") ? "chevron.left.forwardslash.chevron.right" : title.hasPrefix("Design") ? "square.3.layers.3d" : "sparkles")
                        .foregroundStyle(purple).padding(10).background(purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    HStack { Text(title).font(.subheadline); Spacer(minLength: 4); Image(systemName: "arrow.right").font(.caption) }
                }.padding(14).frame(maxWidth: .infinity, minHeight: 104, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(purple.opacity(0.15)))
            }.buttonStyle(.plain)
        }
    }
    private func bubble(_ message: Message) -> some View {
        let user = message.role == "user"
        return HStack(alignment: .top, spacing: 12) {
            if user { Spacer(minLength: 35) } else { brand.frame(width: 38, height: 38) }
            VStack(alignment: user ? .trailing : .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 12) {
                    Text((try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.content)).textSelection(.enabled)
                    if !user { Button { UIPasteboard.general.string = message.content } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy response") }
                }.padding(15).background(user ? purple.opacity(0.16) : panel, in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(purple.opacity(0.16)))
                Text(message.date, style: .time).font(.caption2).foregroundStyle(muted)
            }
            if user { Image(systemName: "person.crop.circle").font(.system(size: 31)).foregroundStyle(muted) } else { Spacer(minLength: 22) }
        }.buttonStyle(.plain)
    }
    private var composer: some View {
        HStack(spacing: 12) {
            Button { importing = true } label: { Image(systemName: "paperclip").font(.title2).foregroundStyle(muted).frame(width: 44, height: 44) }.accessibilityLabel("Import text file")
            TextField("Message OpenMind Harness…", text: $model.draft, axis: .vertical).lineLimit(1...5).accessibilityIdentifier("omh.native.chat.composer")
            Button { Task { await model.send() } } label: {
                Image(systemName: "paperplane").font(.title3).frame(width: 44, height: 44).background(purple, in: RoundedRectangle(cornerRadius: 13))
            }.disabled(model.busy || model.provider == nil || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("omh.native.chat.send").accessibilityLabel("Send")
        }.buttonStyle(.plain).padding(8).background(panel, in: RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(purple.opacity(0.45)))
    }
}

@objc(OMHReferenceDashboardFactory) @MainActor final class OMHReferenceDashboardFactory: NSObject {
    @objc(makeWithBaseURL:settings:workspace:runtime:)
    static func make(baseURL: URL, settings: @escaping () -> Void, workspace: @escaping () -> Void, runtime: @escaping () -> Void) -> UIViewController {
        UIHostingController(rootView: ReferenceDashboard(model: DashboardModel(base: baseURL), settings: settings, workspace: workspace, runtime: runtime))
    }
}
