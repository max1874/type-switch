import SwiftUI

struct SettingsView: View {
    @State private var pane: Pane = .trigger

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(162)
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
            } footer: {
                Text(triggerNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if triggerKeyCode == Int(TriggerBinding.space.keyCode) {
                Section {
                    Toggle("连按两次空格加句号", isOn: doubleSpacePeriodBinding)
                } footer: {
                    Text("这是 macOS 的全局设置，改这里等同于改系统设置，影响所有 app。关掉后用空格触发不会再冒出句号；已经开着的 app 可能要重开才生效。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(excluded, id: \.self) { bundleID in
                    ExcludedAppRow(bundleID: bundleID) { remove(bundleID) }
                }
                Button("添加 app…", action: addApp)
            } header: {
                Text("不在这些 app 里触发")
            } footer: {
                Text("触发键认的是按键，不是按键底下是什么。终端和代码编辑器里读到的一行，很可能是提示符或一行代码而不是正文。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("在菜单栏显示图标", isOn: $showMenuBarIcon)
            } footer: {
                Text("关掉后，再次打开 TypeSwitch 会回到这个窗口。出错时图标会自己回来，否则你不会知道它失败了。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
    @AppStorage(PrefKey.providerBaseURL) private var baseURL = AIProvider.default.baseURL
    @AppStorage(PrefKey.providerModel) private var model = AIProvider.default.model

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

    /// The preset whose address and model both match what is in the fields, if
    /// any — editing either by hand lands on 自定义.
    private var matchedPreset: AIProvider? {
        AIProvider.presets.first { $0.baseURL == baseURL && $0.model == model }
    }

    private var serviceBinding: Binding<String> {
        Binding(
            get: { matchedPreset?.name ?? "" },
            set: { name in
                guard let preset = AIProvider.presets.first(where: { $0.name == name })
                else { return }
                baseURL = preset.baseURL
                model = preset.model
                outcome = nil
            }
        )
    }

    var body: some View {
        Form {
            // A Form lays a labelled TextField out on its own: label left, field
            // right, text reading left to right. Wrapping one in LabeledContent
            // right-aligns the content and pushes the placeholder outside.
            Section {
                // Shows what is selected rather than a permanent "预设" label,
                // and says what is being picked: the service, which fills in the
                // two fields below.
                Picker("服务商", selection: serviceBinding) {
                    if matchedPreset == nil {
                        Text("自定义").tag("")
                    }
                    ForEach(AIProvider.presets, id: \.name) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
                TextField("地址", text: $baseURL)
                TextField("模型", text: $model)
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
            } header: {
                Text("接口")
            } footer: {
                Text("任何兼容 OpenAI 格式的服务都可以填。Key 存在你的钥匙串里，只发给上面这个地址。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("输出语言", text: $targetLanguage, prompt: Text("English"))
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
            } header: {
                HStack {
                    Text("改写指令")
                    Spacer()
                    Button("恢复默认") { prompt = Rewriter.defaultSystemPrompt }
                        .buttonStyle(.link)
                        .disabled(promptIsDefault)
                }
            } footer: {
                Text("发给模型的原话，其中 \(Rewriter.languagePlaceholder) 会替换成上面的输出语言。删光等同于用回内置指令。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
