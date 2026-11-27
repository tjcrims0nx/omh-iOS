import SwiftUI
import UIKit
import Security
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

// Custom providers (custom-openai, custom-anthropic). The API key is sent
// only to the user-configured base URL. This store shares the Keychain
// service/account and UserDefaults keys with OMHProviderCredentials (ObjC),
// so the UIKit provider setup and the SwiftUI dashboard read and write the
// same config. The base URL and model ID are not secrets (UserDefaults);
// only the API key is in the Keychain.
private enum CustomProviderStore {
    static let ids = ["custom-openai", "custom-anthropic"]
    static let service = "com.openmind.omh.provider-credentials"
    static func label(for id: String) -> String { id == "custom-openai" ? "Custom OpenAI" : "Custom Anthropic" }
    static func baseURL(for id: String) -> String? {
        let v = UserDefaults.standard.string(forKey: "omh.custom.\(id).url")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return v?.isEmpty == false ? v : nil
    }
    static func model(for id: String) -> String? {
        let v = UserDefaults.standard.string(forKey: "omh.custom.\(id).model")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return v?.isEmpty == false ? v : nil
    }
    static func apiKey(for id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }
    static func save(id: String, baseURL: String, apiKey: String, model: String) {
        UserDefaults.standard.set(baseURL, forKey: "omh.custom.\(id).url")
        UserDefaults.standard.set(model, forKey: "omh.custom.\(id).model")
        let data = Data(apiKey.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func isConfigured(id: String) -> Bool {
        baseURL(for: id) != nil && model(for: id) != nil && apiKey(for: id) != nil
    }
    static func remove(id: String) {
        UserDefaults.standard.removeObject(forKey: "omh.custom.\(id).url")
        UserDefaults.standard.removeObject(forKey: "omh.custom.\(id).model")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id
        ]
        SecItemDelete(query as CFDictionary)
    }
    static func chatEndpoint(for id: String) -> URL? {
        guard var base = baseURL(for: id) else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        let path = id == "custom-openai" ? "/chat/completions" : "/v1/messages"
        return URL(string: base + path)
    }
    static func verifyEndpoint(for id: String) -> URL? {
        guard var base = baseURL(for: id) else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        let path = id == "custom-openai" ? "/models" : "/v1/models"
        return URL(string: base + path)
    }
}

// Blocks redirects so a provider key is never carried to another host.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
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
            // The harness backend lists only the 10 built-in providers.
            // Custom providers are configured natively in the app, so they
            // are merged in here. They are available only when a base URL,
            // model ID and API key are all saved.
            providers += CustomProviderStore.ids.map { id in
                Provider(id: id, label: CustomProviderStore.label(for: id), model: CustomProviderStore.model(for: id) ?? "Not configured", available: CustomProviderStore.isConfigured(id: id))
            }
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
            let replyText: String
            if provider.id == "custom-openai" || provider.id == "custom-anthropic" {
                // Custom providers are called directly at the
                // user-configured endpoint (OpenAI-compatible or Anthropic
                // protocol), not via the harness backend, which does not
                // know them.
                replyText = try await sendCustom(provider: provider, messages: context)
            } else {
                let body = try JSONEncoder().encode(ChatPayload(provider: provider.id, messages: context.map { .init(role: $0.role, content: $0.content) }))
                guard body.count <= 22000 else { status = "Conversation exceeds the request limit."; return }
                let token = try JSONDecoder().decode(SessionResponse.self, from: await request("/api/session")).csrf
                let reply = try JSONDecoder().decode(ChatResponse.self, from: await request("/api/chat", body: body, csrf: token))
                replyText = reply.text
            }
            if let i = conversations.firstIndex(where: { $0.id == conversationID }) {
                conversations[i].messages += [user, Message(role: "assistant", content: replyText)]
                conversations[i].messages = Array(conversations[i].messages.suffix(50))
                save()
            }
            if draft == input { draft = "" }
        } catch { status = error.localizedDescription }
    }
    // Direct call to a custom provider endpoint. The key is sent only to
    // the configured base URL, on an ephemeral session that blocks
    // redirects. Throws a user-facing error on any failure.
    func sendCustom(provider: Provider, messages: [Message]) async throws -> String {
        guard let url = CustomProviderStore.chatEndpoint(for: provider.id),
              let key = CustomProviderStore.apiKey(for: provider.id),
              let model = CustomProviderStore.model(for: provider.id) else {
            throw NSError(domain: "OMH", code: 0, userInfo: [NSLocalizedDescriptionKey: "Configure this custom provider in Settings first."])
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let entries = messages.map { ["role": $0.role, "content": $0.content] }
        let body: [String: Any]
        if provider.id == "custom-openai" {
            body = ["model": model, "messages": entries]
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else {
            // Anthropic requires alternating turns starting with a user
            // turn. Trimming to the last 16 can leave a leading assistant
            // turn; drop it.
            var anthropicEntries = entries
            while anthropicEntries.first?["role"] == "assistant" { anthropicEntries.removeFirst() }
            guard !anthropicEntries.isEmpty else {
                throw NSError(domain: "OMH", code: 0, userInfo: [NSLocalizedDescriptionKey: "No user message to send."])
            }
            body = ["model": model, "max_tokens": 1024, "messages": anthropicEntries]
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        guard bodyData.count <= 22000 else {
            throw NSError(domain: "OMH", code: 0, userInfo: [NSLocalizedDescriptionKey: "Conversation exceeds the request limit."])
        }
        request.httpBody = bodyData
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "OMH", code: code, userInfo: [NSLocalizedDescriptionKey: "Custom provider request failed (HTTP \(code))."])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if provider.id == "custom-openai" {
            if let choices = json?["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String, !content.isEmpty {
                return content
            }
        } else {
            if let content = json?["content"] as? [[String: Any]] {
                for block in content {
                    if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                        return text
                    }
                }
            }
        }
        throw NSError(domain: "OMH", code: 0, userInfo: [NSLocalizedDescriptionKey: "Custom provider returned an unexpected response."])
    }
    // Verifies a custom provider by GETting its models endpoint with the
    // saved key. Returns a user-facing status string.
    func verifyCustom(id: String) async -> String {
        guard let url = CustomProviderStore.verifyEndpoint(for: id) else { return "Configure a base URL first." }
        guard let key = CustomProviderStore.apiKey(for: id) else { return "No API key saved." }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        if id == "custom-anthropic" {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return "Verified" }
            if status == 401 || status == 403 { return "Credentials rejected" }
            return "Provider verification failed"
        } catch {
            return "Network verification failed"
        }
    }
}

// Native configuration screen for the two custom providers. The API key is
// stored in the iOS Keychain; the base URL and model ID are not secrets.
private struct CustomProviderSettingsView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var openAIURL = CustomProviderStore.baseURL(for: "custom-openai") ?? ""
    @State private var openAIKey = ""
    @State private var openAIModel = CustomProviderStore.model(for: "custom-openai") ?? ""
    @State private var anthropicURL = CustomProviderStore.baseURL(for: "custom-anthropic") ?? ""
    @State private var anthropicKey = ""
    @State private var anthropicModel = CustomProviderStore.model(for: "custom-anthropic") ?? ""
    @State private var openAIStatus = ""
    @State private var anthropicStatus = ""
    @State private var verifyingOpenAI = false
    @State private var verifyingAnthropic = false
    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Base URL", text: $openAIURL)
                        .autocapitalization(.none).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("omh.custom.openai.url")
                    SecureField(CustomProviderStore.apiKey(for: "custom-openai") == nil ? "API key" : "API key (saved)", text: $openAIKey)
                        .autocapitalization(.none).autocorrectionDisabled()
                        .accessibilityIdentifier("omh.custom.openai.key")
                    TextField("Model ID", text: $openAIModel)
                        .autocapitalization(.none).autocorrectionDisabled()
                        .accessibilityIdentifier("omh.custom.openai.model")
                    HStack {
                        Button("Verify connection") {
                            verifyingOpenAI = true
                            Task {
                                openAIStatus = await model.verifyCustom(id: "custom-openai")
                                verifyingOpenAI = false
                            }
                        }.disabled(verifyingOpenAI || openAIURL.isEmpty)
                            .accessibilityIdentifier("omh.custom.openai.verify")
                        if verifyingOpenAI { ProgressView() }
                        if !openAIStatus.isEmpty { Text(openAIStatus).font(.caption).foregroundStyle(muted) }
                    }
                    Button("Save Custom OpenAI") {
                        let key = openAIKey.isEmpty ? (CustomProviderStore.apiKey(for: "custom-openai") ?? "") : openAIKey
                        CustomProviderStore.save(id: "custom-openai", baseURL: openAIURL.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: key, model: openAIModel.trimmingCharacters(in: .whitespacesAndNewlines))
                        openAIKey = ""
                        openAIStatus = "Saved."
                        Task { await model.refresh() }
                    }.disabled(openAIURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || openAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("omh.custom.openai.save")
                    Button("Remove Custom OpenAI", role: .destructive) {
                        CustomProviderStore.remove(id: "custom-openai")
                        openAIURL = ""; openAIKey = ""; openAIModel = ""; openAIStatus = "Removed."
                        Task { await model.refresh() }
                    }.accessibilityIdentifier("omh.custom.openai.remove")
                } header: {
                    Text("Custom OpenAI (OpenAI-compatible)")
                } footer: {
                    Text("Base URL ends in /v1, e.g. https://api.example.com/v1. The key is sent only to this URL.")
                }
                Section {
                    TextField("Base URL", text: $anthropicURL)
                        .autocapitalization(.none).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("omh.custom.anthropic.url")
                    SecureField(CustomProviderStore.apiKey(for: "custom-anthropic") == nil ? "API key" : "API key (saved)", text: $anthropicKey)
                        .autocapitalization(.none).autocorrectionDisabled()
                        .accessibilityIdentifier("omh.custom.anthropic.key")
                    TextField("Model ID", text: $anthropicModel)
                        .autocapitalization(.none).autocorrectionDisabled()
                        .accessibilityIdentifier("omh.custom.anthropic.model")
                    HStack {
                        Button("Verify connection") {
                            verifyingAnthropic = true
                            Task {
                                anthropicStatus = await model.verifyCustom(id: "custom-anthropic")
                                verifyingAnthropic = false
                            }
                        }.disabled(verifyingAnthropic || anthropicURL.isEmpty)
                            .accessibilityIdentifier("omh.custom.anthropic.verify")
                        if verifyingAnthropic { ProgressView() }
                        if !anthropicStatus.isEmpty { Text(anthropicStatus).font(.caption).foregroundStyle(muted) }
                    }
                    Button("Save Custom Anthropic") {
                        let key = anthropicKey.isEmpty ? (CustomProviderStore.apiKey(for: "custom-anthropic") ?? "") : anthropicKey
                        CustomProviderStore.save(id: "custom-anthropic", baseURL: anthropicURL.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: key, model: anthropicModel.trimmingCharacters(in: .whitespacesAndNewlines))
                        anthropicKey = ""
                        anthropicStatus = "Saved."
                        Task { await model.refresh() }
                    }.disabled(anthropicURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || anthropicModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("omh.custom.anthropic.save")
                    Button("Remove Custom Anthropic", role: .destructive) {
                        CustomProviderStore.remove(id: "custom-anthropic")
                        anthropicURL = ""; anthropicKey = ""; anthropicModel = ""; anthropicStatus = "Removed."
                        Task { await model.refresh() }
                    }.accessibilityIdentifier("omh.custom.anthropic.remove")
                } header: {
                    Text("Custom Anthropic (Anthropic-compatible)")
                } footer: {
                    Text("Base URL is the API host, e.g. https://api.example.com. The key is sent only to this URL.")
                }
            }
            .navigationTitle("Custom providers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("omh.custom.done")
                }
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("omh.custom.providers")
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
    @State private var showCustomProviders = false
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
        .sheet(isPresented: $showCustomProviders) { CustomProviderSettingsView(model: model) }
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
                Button { sidebar = false } label: { Image(systemName: "chevron.left.2") }.accessibilityLabel("Collapse sidebar").accessibilityIdentifier("omh.sidebar.collapse")
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
                } label: { Image(systemName: "sidebar.left").frame(width: 44, height: 44) }.accessibilityLabel("Sidebar").accessibilityIdentifier("omh.sidebar.expand")
            }
            brand.frame(width: 34, height: 34).accessibilityIdentifier("omh.native.brand.logo")
            Text(wide ? "OpenMind Harness" : "OMH").font(.headline).lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                ForEach(model.providers) { p in Button(p.label + " — " + p.model) { model.select(p) }.disabled(!p.available || model.busy) }
                Button("Configure custom providers…") { showCustomProviders = true }.accessibilityIdentifier("omh.custom.configure")
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

// The factory is an Objective-C-compatible wrapper: neither the class nor
// the make method carries actor isolation, so both appear in the
// generated OMH-Swift.h. A @MainActor annotation on either hides it from
// Objective-C (CI runs 45896757219 and 45907478634). The hosting
// controller is still built on the main actor, via assumeIsolated — the
// SceneDelegate calls this from UIKit lifecycle code, which is
// main-thread, so the assumption holds.
@objc(OMHReferenceDashboardFactory) public final class OMHReferenceDashboardFactory: NSObject {
    @objc(makeWithBaseURL:settings:workspace:runtime:)
    public static func make(baseURL: URL, settings: @escaping () -> Void, workspace: @escaping () -> Void, runtime: @escaping () -> Void) -> UIViewController {
        MainActor.assumeIsolated {
            UIHostingController(rootView: ReferenceDashboard(model: DashboardModel(base: baseURL), settings: settings, workspace: workspace, runtime: runtime))
        }
    }
}

