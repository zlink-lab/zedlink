import SwiftUI
import UIKit

struct SessionIssueBanner: View {
    @EnvironmentObject private var session: SessionManager
    var body: some View {
        if !session.issue.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(ZLTheme.warning)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    if let help = ConnectionHelp.forMessage(session.issue) {
                        Text(help.title).font(.footnote.weight(.semibold))
                        Text(help.detail).font(.footnote).textSelection(.enabled)
                    } else {
                        Text(session.issue).font(.footnote).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let help = ConnectionHelp.forMessage(session.issue) {
                    Button {
                        dismissZedLinkKeyboard()
                        if help.action == .connections { session.showConnections = true }
                        else { Task { await session.refresh() } }
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: help.action == .connections ? "network" : "arrow.clockwise")
                            Text(help.action == .connections ? "Connections" : "Retry")
                                .font(.caption2).fixedSize(horizontal: false, vertical: true)
                        }.frame(minWidth: 76, minHeight: 44)
                    }
                    .accessibilityLabel(help.action == .connections ? "Open Connections" : "Reconnect")
                    .disabled(help.action != .connections && (session.state == .connecting || session.state == .reconnecting))
                } else if session.notificationNeedsWorkspace || session.profile == nil {
                    Button {
                        session.clearIssue()
                        session.showConnections = true
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: "network")
                            Text("Connections").font(.caption2).fixedSize(horizontal: false, vertical: true)
                        }.frame(minWidth: 76, minHeight: 44)
                    }
                        .accessibilityLabel("Open Connections")
                } else if session.state != .live {
                    Button { Task { await session.refresh() } } label: {
                        VStack(spacing: 1) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry").font(.caption2).fixedSize(horizontal: false, vertical: true)
                        }.frame(minWidth: 76, minHeight: 44)
                    }
                    .accessibilityLabel("Reconnect")
                    .disabled(session.state == .connecting || session.state == .reconnecting)
                }
                Button { session.clearIssue() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Dismiss error")
            }.padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 6)
                .background(ZLTheme.surface)
                .accessibilityIdentifier("session-error")
        }
    }
}

/// Zed itself is closed, hung or restarting (gateway `zed.status`), with start/restart when the
/// gateway controls this Zed. Hidden while the connection is Live and Zed answers.
struct ZedControlBanner: View {
    @EnvironmentObject private var session: SessionManager

    private func title(_ health: ZedHealth) -> String {
        switch health {
        case .down: "Zed не запущен"
        case .hung: "Zed не отвечает"
        case .starting: "Запуск Zed…"
        case .restarting: "Перезапуск Zed…"
        case .running, .unknown: "Zed"
        }
    }

    var body: some View {
        let health: ZedHealth = session.zedHealth
        let issue: String = session.zedIssue
        if session.showsZedControl && ((health != .running && health != .unknown) || !issue.isEmpty) {
            HStack(alignment: .center, spacing: 8) {
                if health == .starting || health == .restarting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(ZLTheme.warning)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(health)).font(.footnote.weight(.semibold))
                    if !issue.isEmpty {
                        Text(issue).font(.footnote).foregroundStyle(ZLTheme.danger).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                ZedControlButton()
                if !issue.isEmpty {
                    Button { session.clearZedIssue() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("Dismiss Zed error")
                }
            }.padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 6)
                .frame(minHeight: 44)
                .background(ZLTheme.surface)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("zed-control-banner")
        }
    }
}

/// "Запустить Zed" when Zed is closed, "Перезапустить Zed" (with confirmation) otherwise.
struct ZedControlButton: View {
    @EnvironmentObject private var session: SessionManager

    var body: some View {
        if session.canControlZed {
            switch session.zedHealth {
            case .down:
                Button("Запустить Zed") { Task { await session.startZed() } }
                    .buttonStyle(.bordered).frame(minHeight: 44)
                    .accessibilityIdentifier("zed-start")
            case .hung, .running:
                Button("Перезапустить Zed") { session.requestZedRestart() }
                    .buttonStyle(.bordered).frame(minHeight: 44)
                    .accessibilityIdentifier("zed-restart")
            case .starting, .restarting, .unknown:
                EmptyView()
            }
        }
    }
}

/// The Zed restart confirmation, attached once at the app root so the banner, Settings and the
/// "Перезапустить Zed" alert action share it. After `TURNS_RUNNING` it asks again with the count.
struct ZedRestartDialog: ViewModifier {
    @ObservedObject var session: SessionManager

    private var presented: Binding<Bool> {
        Binding(get: { session.zedRestartPrompt != nil },
                set: { if !$0 { session.zedRestartPrompt = nil } })
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(session.zedRestartPrompt?.title ?? "Перезапустить Zed?", isPresented: presented,
                                   titleVisibility: .visible, presenting: session.zedRestartPrompt) { prompt in
            Button(prompt.confirmTitle, role: .destructive) {
                Task { await session.restartZed(force: prompt.force) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
    }
}

struct ReviewLine: Identifiable {
    enum Kind: Equatable { case plain, added, removed, header }
    let id: Int
    let text: String
    var kind: Kind {
        if text.hasPrefix("+++") || text.hasPrefix("---") || text.hasPrefix("@@") || text.hasPrefix("diff ") { return .header }
        if text.hasPrefix("+") { return .added }
        if text.hasPrefix("-") { return .removed }
        return .plain
    }
    static func lines(_ content: String) -> [ReviewLine] {
        content.components(separatedBy: "\n").enumerated().map { ReviewLine(id: $0.offset + 1, text: $0.element) }
    }
}

struct ReviewIndex {
    struct Section: Identifiable { let id: Int; let title: String }
    let lines: [ReviewLine]
    let sections: [Section]
    private(set) var matches: [Int] = []
    private(set) var hits: Set<Int> = []
    init(_ content: String) {
        lines = ReviewLine.lines(content)
        var sections: [Section] = [], start = 1, oldPath = ""
        for line in lines {
            if line.text.hasPrefix("diff --git ") { start = line.id }
            if line.text.hasPrefix("--- a/") { oldPath = String(line.text.dropFirst(6)) }
            if line.text.hasPrefix("+++ ") {
                let path = String(line.text.dropFirst(4))
                sections.append(Section(id: sections.contains(where: { $0.id == start }) ? line.id : start, title: path == "/dev/null" ? oldPath : path.hasPrefix("b/") ? String(path.dropFirst(2)) : path))
            }
        }
        self.sections = sections
    }
    mutating func find(_ query: String) {
        matches = query.isEmpty ? [] : lines.filter { $0.text.localizedCaseInsensitiveContains(query) }.map(\.id)
        hits = Set(matches)
    }
    static func nextMatch(_ current: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (current + delta + count) % count
    }
}

struct CodeReviewView: View {
    let content: String
    var title = "File"
    var diff = false
    var truncated = false
    var initialLine: Int? = nil
    var allowsExpansion = true
    @State private var wrap = true
    @State private var query = ""
    @State private var matchIndex = 0
    @State private var expanded = false
    @State private var index = ReviewIndex("")
    @State private var highlighted: [Int: AttributedString] = [:]
    @State private var scrollTarget: Int?
    @State private var scrollRequest = UUID()
    @State private var showingJump = false
    @State private var lineNumber = ""
    private func jump(_ line: Int) { scrollTarget = line; scrollRequest = UUID() }
    private func moveMatch(_ delta: Int) {
        guard !index.matches.isEmpty else { return }
        matchIndex = ReviewIndex.nextMatch(matchIndex, delta: delta, count: index.matches.count)
        jump(index.matches[matchIndex])
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                TextField("Find in \(diff ? "diff" : "file")", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("find-in-file")
                Text(index.matches.isEmpty ? "0" : "\(matchIndex + 1)/\(index.matches.count)").font(.caption.monospaced())
                Button { moveMatch(-1) } label: { Image(systemName: "chevron.up").frame(width: 44, height: 44) }
                    .disabled(index.matches.isEmpty).accessibilityLabel("Previous match")
                Button { moveMatch(1) } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                    .disabled(index.matches.isEmpty).accessibilityLabel("Next match")
                Menu {
                    Toggle("Wrap lines", isOn: $wrap)
                    Button("Jump to line") { showingJump = true }
                    if diff, !index.sections.isEmpty {
                        Menu("Jump to file") { ForEach(index.sections) { section in Button(section.title) { jump(section.id) } } }
                    }
                    if allowsExpansion { Button("Expand") { expanded = true } }
                    Button("Copy text") { UIPasteboard.general.string = content }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            }.padding(.horizontal, 12)
            Hairline()
            ScrollViewReader { reader in
                ScrollView(wrap ? [.vertical] : [.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(index.lines) { line in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(line.id)").foregroundStyle(ZLTheme.muted).frame(width: 38, alignment: .trailing)
                                Text(diff ? AttributedString(line.text.isEmpty ? " " : line.text) : highlighted[line.id] ?? AttributedString(line.text))
                                    .foregroundStyle(diff ? lineColor(line) : Color.primary)
                                    .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                                    .fixedSize(horizontal: !wrap, vertical: true)
                            }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .padding(.vertical, 3).padding(.horizontal, 8)
                                .background(index.hits.contains(line.id) ? ZLTheme.warning.opacity(0.25) : lineBackground(line)).id(line.id)
                        }
                    }
                }
                .task(id: content) {
                    index = ReviewIndex(content); index.find(query); matchIndex = 0
                    highlighted = diff ? [:] : Dictionary(uniqueKeysWithValues: index.lines.map { ($0.id, highlightedSource($0.text.isEmpty ? " " : $0.text)) })
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    if let initialLine { reader.scrollTo(initialLine, anchor: .center) }
                }
                .onChange(of: query) { _, value in
                    index.find(value); matchIndex = 0
                    if let first = index.matches.first { jump(first) }
                }
                .onChange(of: scrollRequest) { _, _ in if let scrollTarget { reader.scrollTo(scrollTarget, anchor: .center) } }
            }
            if truncated { Label("Partial content · native size limit", systemImage: "exclamationmark.triangle").font(.caption).padding(8) }
        }
        .alert("Jump to line", isPresented: $showingJump) {
            TextField("Line number", text: $lineNumber).keyboardType(.numberPad)
            Button("Go") { if let line = Int(lineNumber), (1...max(1, index.lines.count)).contains(line) { jump(line) } }
                .disabled(Int(lineNumber).map { !(1...max(1, index.lines.count)).contains($0) } ?? true)
            Button("Cancel", role: .cancel) {}
        } message: { Text("Enter a line between 1 and \(index.lines.count).") }
        .fullScreenCover(isPresented: $expanded) {
            NavigationStack {
                CodeReviewView(content: content, title: title, diff: diff, truncated: truncated, initialLine: scrollTarget, allowsExpansion: false)
                    .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { expanded = false } } }
            }
        }
    }
    private func lineColor(_ line: ReviewLine) -> Color {
        switch line.kind { case .added: ZLTheme.healthy; case .removed: ZLTheme.danger; case .header: ZLTheme.focus; case .plain: .primary }
    }
    private func lineBackground(_ line: ReviewLine) -> Color {
        guard diff else { return .clear }
        return switch line.kind { case .added: ZLTheme.healthy.opacity(0.08); case .removed: ZLTheme.danger.opacity(0.08); default: .clear }
    }
}

struct SessionModelControls: View {
    @EnvironmentObject private var session: SessionManager
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                SessionIssueBanner()
                if let settings = session.threadSettings {
                    managedSection(settings)
                    modesSection(settings)
                    configOptionsSection(settings)
                    profileSection(settings)
                    thinkingSection(settings)
                    modelSection(settings)
                    contextSection(settings)
                } else { Text("Model selection is not advertised by this Agent. Its configuration stays in desktop Zed.") }
            }.navigationTitle("Agent settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    /// Controls are usable only while the native turn is idle (the bridge refuses busy threads).
    private var controlsDisabled: Bool {
        session.state != .live || session.snapshot?.status != "Idle" || session.updatingModel || !session.capabilities.contains("thread.settings.update")
    }

    private var agentName: String {
        session.threads.first(where: { $0.id == session.selectedThreadID })?.agentName ?? "This agent"
    }

    @ViewBuilder private func managedSection(_ settings: NativeThreadSettings) -> some View {
        if settings.managedByAgent {
            Section {
                Label("Managed by the agent", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                Text(settings.modes == nil && settings.configOptions.isEmpty && settings.models.isEmpty
                     ? "\(agentName) keeps its own model and settings. Change them in desktop Zed or in the agent's configuration."
                     : "\(agentName) keeps its own configuration. The options it shares with Zed are listed below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func modesSection(_ settings: NativeThreadSettings) -> some View {
        if let modes = settings.modes {
            Section("Mode") {
                Picker("Mode", selection: Binding<String>(
                    get: { modes.currentID ?? "" },
                    set: { id in Task { await session.selectMode(id) } }
                )) {
                    ForEach(modes.available) { mode in
                        Text(mode.name).tag(mode.id)
                    }
                }
                .disabled(controlsDisabled)
                .accessibilityIdentifier("thread-mode-picker")
                if let current = modes.available.first(where: { $0.id == modes.currentID }), let detail = current.description {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func configOptionsSection(_ settings: NativeThreadSettings) -> some View {
        if !settings.configOptions.isEmpty {
            Section("Agent options") {
                ForEach(settings.configOptions) { option in
                    configOptionPicker(option)
                }
            }
        }
    }

    @ViewBuilder private func configOptionPicker(_ option: NativeConfigOption) -> some View {
        Picker(option.name, selection: Binding<String>(
            get: { option.currentValue ?? "" },
            set: { value in Task { await session.selectConfigOption(option, value: value) } }
        )) {
            ForEach(option.options) { choice in
                Text(choice.name).tag(choice.value)
            }
        }
        .disabled(controlsDisabled)
        .accessibilityIdentifier("thread-config-" + option.id)
        if let detail = option.description {
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func profileSection(_ settings: NativeThreadSettings) -> some View {
        if !settings.profiles.isEmpty {
            Section("Agent profile") {
                ForEach(settings.profiles) { profile in
                    Button { Task { await session.updateAgentSettings(profileID: profile.id) } } label: {
                        HStack { Text(profile.name); Spacer(); if profile.id == settings.profileID { Image(systemName: "checkmark") } }
                    }.disabled(controlsDisabled || settings.managedByAgent)
                }
            }
        }
    }

    @ViewBuilder private func thinkingSection(_ settings: NativeThreadSettings) -> some View {
        if settings.thinkingSupported, let enabled = settings.thinkingEnabled {
            Section("Thinking") {
                Toggle("Model thinking", isOn: Binding(get: { enabled }, set: { value in Task { await session.updateAgentSettings(thinking: value) } }))
                    .disabled(controlsDisabled || !settings.thinkingCanDisable || settings.managedByAgent)
                if !settings.thinkingCanDisable { Text("This model requires thinking.").font(.caption) }
            }
        }
    }

    private func isSelected(_ model: NativeModelOption, _ settings: NativeThreadSettings) -> Bool {
        model.id == "\(settings.providerID ?? "")\n\(settings.modelID ?? "")"
    }

    @ViewBuilder private func modelSection(_ settings: NativeThreadSettings) -> some View {
        if !settings.models.isEmpty || !settings.managedByAgent {
            Section(settings.managedByAgent ? "Model" : "Zed model") {
                if settings.models.isEmpty { Text("This Agent does not advertise a remote model selector. Configure it in desktop Zed.").font(.caption) }
                ForEach(settings.models) { model in
                    Button { Task { await session.selectModel(model) } } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(model.name)
                                if model.providerID != "acp" { Text(model.providerID).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if isSelected(model, settings) { Image(systemName: "checkmark") }
                        }
                    }.disabled(controlsDisabled || !settings.canSelectModels)
                }
            }
        }
    }

    @ViewBuilder private func contextSection(_ settings: NativeThreadSettings) -> some View {
        Section("Context · last reported by Zed") {
            if let used = settings.usedTokens, let maximum = settings.maxTokens, maximum > 0 {
                LabeledContent("Used", value: "\(used.formatted()) / \(maximum.formatted()) tokens")
                ProgressView(value: min(Double(used) / Double(maximum), 1))
                    .tint(Double(used) / Double(maximum) >= 0.8 ? ZLTheme.warning : ZLTheme.focus)
                if let input = settings.inputTokens {
                    LabeledContent { Text("\(input.formatted()) tokens") } label: {
                        Label("Input", systemImage: "arrow.down")
                    }
                }
                if let output = settings.outputTokens {
                    LabeledContent { Text("\(output.formatted()) tokens") } label: {
                        Label("Output", systemImage: "arrow.up")
                    }
                }
                if let remaining = settings.remainingTokens {
                    LabeledContent("Remaining", value: "\(remaining.formatted()) tokens")
                }
                if Double(used) / Double(maximum) >= 0.8 {
                    Text("Context is filling up. Check desktop Zed's compaction state before sending a long prompt.")
                        .font(.caption).foregroundStyle(ZLTheme.warning)
                }
            } else {
                Text(settings.managedByAgent ? "This agent has not reported context usage." : "Zed has not reported context usage for this thread yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ConversationScrollMetrics: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}

func promptJPEG(_ image: UIImage) -> Data? {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return nil }
    let scale = min(1, 1600 / max(size.width, size.height))
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let outputSize = CGSize(width: size.width * scale, height: size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
    let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: outputSize)) }
    for quality in [0.85, 0.65, 0.45, 0.25] {
        if let data = resized.jpegData(compressionQuality: quality), data.count <= 1024 * 1024 { return data }
    }
    return nil
}
