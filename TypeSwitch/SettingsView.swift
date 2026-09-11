import SwiftUI

struct SettingsView: View {
    @State private var pane: Pane

    init(pane: Pane = .trigger) {
        _pane = State(initialValue: pane)
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                PaneRow(pane: pane).tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(178)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralPane()
                case .trigger: TriggerPane()
                case .provider: ProviderPane()
                }
            }
            .navigationTitle(pane.title)
        }
        .frame(width: 660)
    }

    enum Pane: String, CaseIterable, Identifiable {
        case general, trigger, provider

        var id: String { rawValue }

        /// LocalizedStringKey rather than String: a plain String handed to
        /// Label or navigationTitle is displayed verbatim, never looked up.
        var title: LocalizedStringKey {
            switch self {
            case .general: "通用"
            case .trigger: "触发"
            case .provider: "AI 服务"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .trigger: "keyboard"
            case .provider: "sparkles"
            }
        }

        /// Each pane gets its own colour, which is what makes a row findable at
        /// a glance rather than read one word at a time.
        var tint: Color {
            switch self {
            case .general: .gray
            case .trigger: .indigo
            case .provider: .purple
            }
        }
    }
}

/// A sidebar row: the symbol in a filled rounded square, the way settings
/// windows on this platform have come to look.
private struct PaneRow: View {
    let pane: SettingsView.Pane

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: pane.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 5.5))
            Text(pane.title)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - General

/// What the app does when it is not rewriting anything: whether it shows up in
/// the menu bar, and how it gets replaced by a newer copy of itself.
private struct GeneralPane: View {
    @AppStorage(PrefKey.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(PrefKey.checkForUpdates) private var checkForUpdates = true

    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            Section {
                Explained(text: "关掉后，再次打开 TypeSwitch 会回到这个窗口。出错时屏幕上会弹一条提示，不依赖这个图标。") {
                    Toggle("在菜单栏显示图标", isOn: $showMenuBarIcon)
                }
            }

            Section {
                LabeledContent("当前版本") {
                    Text(verbatim: Updater.currentVersion).foregroundStyle(.secondary)
                }
                Explained(text: "启动时向 GitHub 问一次最新的版本号，请求里没有任何关于你的东西。有新版本时，菜单栏的菜单里会出现更新按钮，更新前会校验下载的文件，并确认它和你手上这份是同一个签名身份。") {
                    HStack {
                        Toggle("自动检查更新", isOn: $checkForUpdates)
                        Spacer()
                        if case .checking = updater.stage {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("现在检查") {
                                Task { await updater.check(asked: true) }
                            }
                        }
                    }
                }
                if case .found(let available) = updater.stage {
                    HStack(spacing: 10) {
                        Button("更新到 \(available.version)") { updater.install(available) }
                            .buttonStyle(.borderedProminent)
                        Link("先看看 \(available.version) 改了什么…", destination: available.page)
                            .font(.callout)
                    }
                }
                if case .installing = updater.stage {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在更新…").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("更新")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Trigger

private struct TriggerPane: View {
    @AppStorage(PrefKey.triggerKeyCode) private var triggerKeyCode = Int(TriggerBinding.space.keyCode)
    @AppStorage(PrefKey.triggerModifierFlag) private var triggerModifierFlag = 0
    @AppStorage(PrefKey.triggerCharacter) private var triggerCharacter = TriggerBinding.space.character
    @AppStorage(PrefKey.triggerCount) private var triggerCount = 3
    @AppStorage(PrefKey.triggerWindow) private var triggerWindow = 0.3

    @State private var doubleSpacePeriod = SystemTextPrefs.doubleSpacePeriod
    @State private var excluded = ExcludedApps.bundleIDs
    @State private var recording = false
    @State private var recorder: Any?

    var body: some View {
        Form {
            Section {
                LabeledContent("触发键") {
                    KeyRecorder(label: binding.label, recording: recording) {
                        recording ? stopRecording() : startRecording()
                    }
                }

                Explained(text: triggerNote) {
                    // Reads as one sentence rather than three separate settings.
                    LabeledContent("连按") {
                        HStack(spacing: 6) {
                            NumberField(value: $triggerCount, range: 2...8, width: 38)
                            Text("次，间隔")
                            DecimalField(value: $triggerWindow, range: 0.1...1.0, width: 56)
                            Text("秒以内")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("触发")
            }

            if triggerKeyCode == Int(TriggerBinding.space.keyCode) {
                Section {
                    Explained(text: "这是 macOS 的全局设置，改这里等同于改系统设置，影响所有 app。关掉后用空格触发不会再冒出句号；已经开着的 app 可能要重开才生效。") {
                        Toggle("连按两次空格加句号", isOn: doubleSpacePeriodBinding)
                    }
                }
            }

            Section {
                ForEach(excluded, id: \.self) { bundleID in
                    ExcludedAppRow(bundleID: bundleID) { remove(bundleID) }
                }
                Explained(text: "触发键认的是按键，不是按键底下是什么。终端和代码编辑器里读到的一行，很可能是提示符或一行代码而不是正文。") {
                    Button("添加 app…", action: addApp)
                }
            } header: {
                Text("不在这些 app 里触发")
            }

        }
        .formStyle(.grouped)
        .onAppear { doubleSpacePeriod = SystemTextPrefs.doubleSpacePeriod }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            // Catches the case where it was changed in System Settings instead.
            doubleSpacePeriod = SystemTextPrefs.doubleSpacePeriod
        }
        .onDisappear(perform: stopRecording)
    }

    private func addApp() {
        guard let bundleID = ExcludedApps.pick() else { return }
        ExcludedApps.add(bundleID)
        excluded = ExcludedApps.bundleIDs
    }

    private func remove(_ bundleID: String) {
        ExcludedApps.remove(bundleID)
        excluded = ExcludedApps.bundleIDs
    }

    /// Writes through to the system only when the user flips it, so refreshing
    /// the displayed state never writes anything back.
    private var doubleSpacePeriodBinding: Binding<Bool> {
        Binding(
            get: { doubleSpacePeriod },
            set: { enabled in
                doubleSpacePeriod = enabled
                SystemTextPrefs.setDoubleSpacePeriod(enabled)
            }
        )
    }

    private var binding: TriggerBinding {
        TriggerBinding(keyCode: Int64(triggerKeyCode),
                       modifierFlagRaw: UInt64(triggerModifierFlag),
                       character: triggerCharacter)
    }

    private var triggerNote: LocalizedStringKey {
        triggerModifierFlag != 0
            ? "修饰键不输入字符，不会在正文里留下痕迹。"
            : "这个键会输入字符，多出来的会被整行替换掉。"
    }

    private func startRecording() {
        recording = true
        recorder = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown, event.keyCode == 53 {   // Esc keeps the current binding
                stopRecording()
                return nil
            }
            guard let binding = TriggerBinding(event: event) else { return nil }
            triggerKeyCode = Int(binding.keyCode)
            triggerModifierFlag = Int(binding.modifierFlagRaw)
            triggerCharacter = binding.character
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        recording = false
    }
}

// MARK: - Provider

private struct ProviderPane: View {
    @AppStorage(PrefKey.providerBaseURL) private var baseURL = KnownEndpoint.default.baseURL
    @AppStorage(PrefKey.providerModel) private var model = KnownEndpoint.default.model

    @AppStorage(PrefKey.systemPrompt) private var prompt = Rewriter.defaultSystemPrompt
    @AppStorage(PrefKey.targetLanguage) private var targetLanguage = "English"

    // The field never shows the stored key. A SecureField renders dots either
    // way, so reading the secret back to fill it in buys nothing — and reading
    // it is exactly what raises the keychain's access prompt. Whether one is
    // stored can be answered without touching the secret; the secret itself is
    // read only when a request is actually made.
    @State private var apiKey = ""
    @State private var hasStoredKey = Keychain.hasAPIKey
    @State private var keyEdited = false
    @FocusState private var keyFocused: Bool

    @State private var outcome: TestOutcome?
    @State private var testing = false
    @State private var choosingModel = false

    /// A sentence that is itself half in another language, so the test shows
    /// what the app actually does. Localized, because the demo only reads as a
    /// demo in a language the user speaks.
    private static let sample = String(localized: "writing English 卡住了？")

    private var promptIsDefault: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            == Rewriter.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The service the current address belongs to, or nil once it has been
    /// edited into something we do not recognise.
    private var service: KnownEndpoint? { KnownEndpoint.matching(baseURL) }

    private static let custom = "__custom__"

    /// Picking a service is picking an address and a model. Reading it back
    /// from the address is what lets the row say a name instead of a URL, and
    /// means an address typed by hand is still described honestly as custom.
    private var serviceName: Binding<String> {
        Binding(
            get: { service?.name ?? Self.custom },
            set: { name in
                guard let chosen = KnownEndpoint.all.first(where: { $0.name == name }) else { return }
                fill(from: chosen)
            }
        )
    }

    private func fill(from endpoint: KnownEndpoint) {
        baseURL = endpoint.baseURL
        model = endpoint.model
        outcome = nil
    }

    /// The URL the rewrite will actually be posted to.
    ///
    /// Nothing about `https://api.deepseek.com` next to `https://api.openai.com/v1`
    /// says which one already ends in its version segment, and getting it wrong
    /// produces a 404 from somewhere else entirely, later. Showing the finished
    /// URL turns that into something you can read and check before you commit.
    private var requestURL: URL? { Endpoint.chatCompletions(baseURL) }

    var body: some View {
        Form {
            // A macOS TextField draws its own label to the left of the field, so
            // these rows keep the Form's two-column look even when wrapped in a
            // stack to hang something underneath them.
            Section {
                Picker("服务", selection: serviceName) {
                    ForEach(KnownEndpoint.all, id: \.name) { endpoint in
                        Text(endpoint.name).tag(endpoint.name)
                    }
                    // Offered only when that is already the situation: custom is
                    // a state you end up in by typing an address, not an action.
                    if service == nil {
                        Divider()
                        Text("自定义").tag(Self.custom)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    TextField("地址", text: $baseURL)
                    // No reset button beside this: picking the service again is
                    // the same action, and the picker is already showing
                    // "custom" the moment the address stops matching one.
                    requestPreview
                }
                .onChange(of: baseURL) { outcome = nil }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        TextField("模型", text: $model, prompt: Text("还没选"))
                        Button {
                            keyFocused = false
                            choosingModel = true
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .help("列出这个地址上有哪些模型")
                    }
                    // Only while there is nothing to run: an icon button is
                    // discoverable by hovering it, which is no help to someone
                    // who does not yet know a list is available. Once a model is
                    // set, the sentence has done its job and would be noise.
                    if model.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("点右边，让这个地址自己列出它有哪些模型。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: model) { outcome = nil }

                Explained(text: keyNote) {
                    SecureField(
                        "API Key",
                        text: $apiKey,
                        prompt: Text(hasStoredKey ? "已保存，输入可替换" : "sk-…")
                    )
                    .focused($keyFocused)
                    .onChange(of: apiKey) { keyEdited = true; outcome = nil }
                    .onSubmit(commitKey)
                    // Written when you leave the field, not on every keystroke:
                    // typing one by hand used to put s, sk, sk-, sk-1 … into the
                    // keychain in turn, and the placeholder claimed a key was
                    // saved from the first character on.
                    .onChange(of: keyFocused) { _, focused in if !focused { commitKey() } }
                }

                check
            } header: {
                HStack {
                    Text("接口")
                    Spacer()
                    if let service, let keyURL = service.keyURL,
                       let url = URL(string: keyURL) {
                        Link("到 \(service.name) 拿 Key", destination: url)
                            .font(.callout)
                    }
                }
            } footer: {
                // Says what it speaks rather than offering it: there is one
                // format today, and a menu of one would pretend to be a choice.
                Text("只说一种格式：\(APIFormat.openAICompatible.name) 的 \(Text("POST /chat/completions").monospaced())。任何说这套格式的地址都可以填。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("输出语言", text: $targetLanguage, prompt: Text("English"))
                Explained(text: "发给模型的原话，其中 \(Rewriter.languagePlaceholder) 会替换成上面的输出语言。删光等同于用回内置指令。") {
                    TextEditor(text: $prompt)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(height: 112)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor))
                        )
                }
            } header: {
                HStack {
                    Text("改写指令")
                    Spacer()
                    Button("恢复默认") { prompt = Rewriter.defaultSystemPrompt }
                        .buttonStyle(.link)
                        .disabled(promptIsDefault)
                }
            }

        }
        .formStyle(.grouped)
        .onDisappear(perform: commitKey)
        .sheet(isPresented: $choosingModel) {
            ModelPicker(baseURL: baseURL, model: $model)
        }
    }

    // MARK: Address

    @ViewBuilder
    private var requestPreview: some View {
        if let requestURL {
            Text(verbatim: "→ \(requestURL.absoluteString)")
                .font(.callout)
                .monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(String(localized: "改写请求会发到这个地址"))
        } else {
            Text("这不是一个能用的地址")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    // MARK: Key

    private var keyNote: LocalizedStringKey {
        service?.keyURL == nil && service != nil
            ? "跑在这台机器上的模型通常不要 Key，留空就行。"
            : "Key 存在你的钥匙串里，只发给上面这个地址。"
    }

    /// Empty means "leave what is stored alone" until the field has been
    /// touched — the field starts empty every time the window opens, and
    /// treating that as a deletion would throw the key away for opening the
    /// window. Emptied by hand, it is a deletion.
    private func commitKey() {
        guard keyEdited else { return }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.apiKey = trimmed
        hasStoredKey = !trimmed.isEmpty
        keyEdited = false
        // Cleared so the placeholder can say it landed. A SecureField shows the
        // same row of dots whatever it holds, so the field itself can never be
        // the confirmation that anything was saved.
        apiKey = ""
    }

    // MARK: Check

    /// The check is here, under the three fields it checks, rather than at the
    /// end of the window: it answers a question you have while you are filling
    /// them in. It sends the real thing — same address, key, model, and
    /// instructions the trigger uses — so a pass means the app works, not that
    /// something replied.
    @ViewBuilder
    private var check: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button("测试一句", action: runTest)
                    .disabled(testing)
                if testing { ProgressView().controlSize(.small) }
            }
            result
        }
    }

    @ViewBuilder
    private var result: some View {
        switch outcome {
        case .ok(let text, let ms):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                // The sample and what came back, together: the point is not that
                // the endpoint answered but that it answered like this.
                Text(verbatim: "\(Self.sample) → \(text)")
                    .textSelection(.enabled)
                Text(verbatim: "\(ms) ms")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).textSelection(.enabled)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    private func runTest() {
        // Whatever is half-typed in the key field is what the user means to
        // test, so it has to be stored before the request reads it back.
        keyFocused = false
        commitKey()
        testing = true
        outcome = nil
        Task {
            let started = Date()
            do {
                let text = try await Rewriter.rewrite(Self.sample)
                outcome = .ok(text, Int(Date().timeIntervalSince(started) * 1000))
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            testing = false
        }
    }
}

private enum TestOutcome {
    case ok(String, Int)
    case failed(String)
}

/// What this address can run, asked of the address.
///
/// The model name is the one field nobody can be expected to know: it is a fact
/// about the endpoint rather than a preference, the endpoint can be asked, and
/// a typo in it surfaces much later as a 404 that reads like an address
/// problem. A search field rather than a plain list because one address offers
/// four models and another offers four hundred.
struct ModelPicker: View {
    let baseURL: String
    @Binding var model: String

    @Environment(\.dismiss) private var dismiss
    @State private var names: [String] = []
    @State private var query = ""
    @State private var loading = true
    @State private var failure: String?

    private var shown: [String] {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return names }
        return names.filter { $0.localizedCaseInsensitiveContains(wanted) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("这个地址上的模型").font(.headline)
                    Spacer()
                    if !loading, failure == nil {
                        Text("\(names.count) 个").foregroundStyle(.secondary)
                    }
                }
                // A sheet has no toolbar to hang `.searchable` on, so the filter
                // is a field. One address offers four models and another offers
                // four hundred; the field earns its place at the second kind.
                if !loading, failure == nil, names.count > 8 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("筛选", text: $query)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if loading {
                centred { ProgressView() }
            } else if let failure {
                centred {
                    VStack(spacing: 8) {
                        Text(failure)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("重试") { load() }
                    }
                    .padding(.horizontal, 24)
                }
            } else {
                // The current model is preselected, so opening this on a working
                // setup shows where you already are rather than the top of an
                // alphabet.
                List(shown, id: \.self, selection: Binding(get: { model }, set: choose)) { name in
                    Text(name)
                        .monospaced()
                        .tag(name)
                }
                .listStyle(.inset)
                .frame(minHeight: 240)
            }

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 420, height: 400)
        .onAppear(perform: load)
    }

    private func choose(_ name: String) {
        model = name
        dismiss()
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity)
    }

    private func load() {
        loading = true
        failure = nil
        Task {
            do {
                names = try await ModelCatalog.fetch(baseURL: baseURL, key: Prefs.apiKey)
            } catch {
                failure = error.localizedDescription
            }
            loading = false
        }
    }
}

// MARK: - Components

/// The one control unique to this app, so it gets to be the thing you notice:
/// a real field showing the bound key, which turns the accent colour while it
/// is listening.
private struct KeyRecorder: View {
    let label: String
    let recording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(recording ? String(localized: "按任意键…") : label)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(recording ? Color.accentColor : .primary)
                .frame(minWidth: 120)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            recording ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: recording ? 2 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help("点一下，然后按你想用的键；Esc 取消")
    }
}

private struct ExcludedAppRow: View {
    let bundleID: String
    let remove: () -> Void

    var body: some View {
        let app = ExcludedApps.describe(bundleID)
        HStack(spacing: 8) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Text(app.name)
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("不再排除这个 app")
        }
    }
}

/// A control and the sentence explaining it, kept in one row.
///
/// A Form draws a divider between rows, so an explanation placed beside its
/// control belongs to it visibly; the same text as its own row reads as
/// belonging to the whole group instead, and a group's last explanation ends up
/// looking like a note about the group.
private struct Explained<Content: View>: View {
    let text: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            content
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let width: CGFloat

    var body: some View {
        TextField("", value: $value, format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .foregroundStyle(.primary)
            .frame(width: width)
            .onSubmit { value = min(max(value, range.lowerBound), range.upperBound) }
    }
}

private struct DecimalField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let width: CGFloat

    var body: some View {
        TextField("", value: $value, format: .number.precision(.fractionLength(2)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .foregroundStyle(.primary)
            .frame(width: width)
            .onSubmit { value = min(max(value, range.lowerBound), range.upperBound) }
    }
}
