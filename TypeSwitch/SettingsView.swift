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
                case .trigger: TriggerPane()
                case .provider: ProviderPane()
                }
            }
            .navigationTitle(pane.title)
        }
        .frame(width: 660)
    }

    enum Pane: String, CaseIterable, Identifiable {
        case trigger, provider

        var id: String { rawValue }

        /// LocalizedStringKey rather than String: a plain String handed to
        /// Label or navigationTitle is displayed verbatim, never looked up.
        var title: LocalizedStringKey {
            switch self {
            case .trigger: "触发"
            case .provider: "AI 服务"
            }
        }

        var symbol: String {
            switch self {
            case .trigger: "keyboard"
            case .provider: "sparkles"
            }
        }

        /// Each pane gets its own colour, which is what makes a row findable at
        /// a glance rather than read one word at a time.
        var tint: Color {
            switch self {
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

// MARK: - Trigger

private struct TriggerPane: View {
    @AppStorage(PrefKey.triggerKeyCode) private var triggerKeyCode = Int(TriggerBinding.space.keyCode)
    @AppStorage(PrefKey.triggerModifierFlag) private var triggerModifierFlag = 0
    @AppStorage(PrefKey.triggerCharacter) private var triggerCharacter = TriggerBinding.space.character
    @AppStorage(PrefKey.triggerCount) private var triggerCount = 3
    @AppStorage(PrefKey.triggerWindow) private var triggerWindow = 0.3
    @AppStorage(PrefKey.showMenuBarIcon) private var showMenuBarIcon = true

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

            Section {
                Explained(text: "关掉后，再次打开 TypeSwitch 会回到这个窗口。出错时屏幕上会弹一条提示，不依赖这个图标。") {
                    Toggle("在菜单栏显示图标", isOn: $showMenuBarIcon)
                }
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
    // read in one place now, when a request is actually made.
    @State private var apiKey = ""
    @State private var hasStoredKey = Keychain.hasAPIKey
    @State private var outcome: TestOutcome?
    @State private var testing = false

    /// A sentence that is itself half in another language, so the test shows
    /// what the app actually does. Localized, because the demo only reads as a
    /// demo in a language the user speaks.
    private static let sample = String(localized: "writing English 卡住了？")

    private var promptIsDefault: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            == Rewriter.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fill(from endpoint: KnownEndpoint) {
        baseURL = endpoint.baseURL
        model = endpoint.model
        outcome = nil
    }

    var body: some View {
        Form {
            // A Form lays a labelled TextField out on its own: label left, field
            // right, text reading left to right. Wrapping one in LabeledContent
            // right-aligns the content and pushes the placeholder outside.
            Section {
                // What the endpoint speaks, which is the only thing that
                // differs between one address and another. Stated rather than
                // offered: there is one format today, and a row that names it
                // tells the user what will be accepted in the field below,
                // where a menu of one would only pretend to be a choice.
                LabeledContent("接口格式") {
                    Text(APIFormat.openAICompatible.name)
                        .foregroundStyle(.secondary)
                }
                TextField("地址", text: $baseURL)
                TextField("模型", text: $model)
                Explained(text: "任何说这个格式的地址都可以填。Key 存在你的钥匙串里，只发给上面这个地址；跑在本机的模型通常不需要 Key，留空即可。") {
                    SecureField(
                        "API Key",
                        text: $apiKey,
                        prompt: Text(hasStoredKey ? "已保存，输入可替换" : "sk-…")
                    )
                    .onChange(of: apiKey) { _, new in
                        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                        Keychain.apiKey = trimmed
                        hasStoredKey = !trimmed.isEmpty
                        outcome = nil
                    }
                }
            } header: {
                HStack {
                    Text("接口")
                    Spacer()
                    // A shortcut, not a setting: it fills the two fields in and
                    // is then forgotten. Nothing downstream asks which one was
                    // used, because the request only needs the address.
                    Menu("常用地址") {
                        ForEach(KnownEndpoint.all, id: \.name) { endpoint in
                            Button(endpoint.name) { fill(from: endpoint) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
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

            Section {
                HStack(spacing: 10) {
                    Button("试一句「\(Self.sample)」") { runTest() }
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    result
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var result: some View {
        switch outcome {
        case .ok(let text):
            Text(text).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
        case .failed(let message):
            Text(message).foregroundStyle(.red).textSelection(.enabled).lineLimit(2)
        case nil:
            EmptyView()
        }
    }

    private func runTest() {
        testing = true
        outcome = nil
        Task {
            do {
                outcome = .ok(try await Rewriter.rewrite(Self.sample))
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            testing = false
        }
    }
}

private enum TestOutcome {
    case ok(String)
    case failed(String)
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
