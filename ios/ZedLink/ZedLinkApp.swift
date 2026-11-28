import SwiftUI

@main @MainActor struct ZedLinkApp: App {
    @UIApplicationDelegateAdaptor(ZedLinkAPNsDelegate.self) private var pushDelegate
    init() { ApprovalNotifications.shared.configure() }
    @StateObject private var library = SessionLibrary()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var session = SessionManager()
    @StateObject private var summary = SummaryStore()
    @StateObject private var extras = GatewayExtrasStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("zedlink.appearance") private var appearance = "dark"
    /// Tags: 0 Sessions, 1 Сводка (shown first and selected at launch), 2 Settings.
    @State private var selectedTab = 1
    @State private var sessionsPath: [String] = []
    /// The Summary tab's own stack: threads opened from Summary or a push pop back to Summary.
    @State private var summaryPath: [SummaryRoute] = []
    @State private var connectionDraft = ConnectionDraft()
    @State private var showingConnections = false

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "system": nil
        default: .dark
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                SummaryView(path: $summaryPath)
                    .tabItem { Label("Сводка", systemImage: "list.bullet.rectangle") }.tag(1)
                    .badge(extras.unreadTotal)
                SessionsView(navigationPath: $sessionsPath)
                    .tabItem { Label("Sessions", systemImage: "bubble.left.and.bubble.right") }.tag(0)
                SettingsView(connectionDraft: $connectionDraft, showingConnections: $showingConnections)
                    .tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
            }
            .environmentObject(profiles)
            .environmentObject(session)
            .environmentObject(library)
            .environmentObject(summary)
            .environmentObject(extras)
            .preferredColorScheme(preferredColorScheme)
            .tint(ZLTheme.focus)
            .toolbarBackground(ZLTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: selectedTab, initial: true) { _, tab in
                dismissZedLinkKeyboard()
                session.visibleStack = tab == 1 ? .summary : .sessions
            }
            .onChange(of: session.showConnections) { _, requested in
                // Connections live in Settings › Connection & access.
                if requested { sessionsPath = []; selectedTab = 2; showingConnections = true; session.showConnections = false }
            }
            .onChange(of: session.showZedControl) { _, requested in
                // A tapped "Zed не отвечает" alert: Settings › Connection & access shows Zed's status.
                if requested { selectedTab = 2; session.showZedControl = false }
            }
            .modifier(ZedRestartDialog(session: session))
            .onChange(of: session.summaryThreadID) { _, thread in
                guard let thread else { return }
                dismissZedLinkKeyboard()
                selectedTab = 1
                summaryPath = [.thread(thread)]
                // The session now shows this thread; an older one left open in Sessions would be stale.
                if let open = sessionsPath.last, open != thread { sessionsPath = [] }
                session.summaryThreadID = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: EndpointSelection.didChange)) { note in
                // Main or mesh address: remember the one that passed the identity check last.
                guard let raw = note.userInfo?["profile_id"] as? String, let id = UUID(uuidString: raw),
                      let endpoint = note.userInfo?["endpoint"] as? String else { return }
                profiles.recordWorkingEndpoint(profileID: id, endpoint: endpoint)
                session.endpointSelectionChanged()
            }
            .onChange(of: session.threads) { _, threads in
                guard !session.demoPreview else { return }
                summary.absorb(threads, profile: session.profile, targetID: session.targetID, hosts: session.workspaceHosts)
            }
            .task {
                #if DEBUG
                // The demo preview (UI tests, screenshots) starts on the Sessions list.
                if ProcessInfo.processInfo.arguments.contains("--zedlink-demo") { selectedTab = 0; session.loadDemoPreview(); return }
                #endif
                ApprovalNotifications.shared.configure()
                await ApprovalNotifications.shared.refreshStatus()
                ApprovalNotifications.shared.onRemoteToken = { _ = Task { await session.syncAPNs() } }
                session.enterForeground()
                if session.profile == nil, let profile = profiles.preferredProfile {
                    await session.connect(profile)
                    if session.state == .live { profiles.markUsed(profile) }
                }
                // Install only after initial profile restoration; earlier responses are queued.
                ApprovalNotifications.shared.handler = { data, action in
                    // Push taps open their thread on the Summary tab's stack; problems that need
                    // the session list (wrong connection, workspace) are shown in Sessions.
                    selectedTab = 1
                    await session.handleApprovalNotification(data, action: action, profiles: profiles.profiles)
                    if session.notificationNeedsWorkspace { selectedTab = 0 }
                    Task { await extras.refreshUnread(profiles: profiles.profiles, preferring: session.profile) }
                }
                await SharedInboxProcessor.shared.process(profiles: profiles.profiles)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, session.profile != nil, !session.demoPreview {
                    session.enterForeground()
                    // The badge does not wait for the session to reconnect.
                    Task { await extras.refreshUnread(profiles: profiles.profiles, preferring: session.profile) }
                    Task {
                        await ApprovalNotifications.shared.refreshStatus()
                        await session.refresh()
                        await SharedInboxProcessor.shared.process(profiles: profiles.profiles)
                    }
                } else if phase != .active {
                    Task { await session.persistConversation() }
                    if phase == .background { session.enterBackground() }
                }
            }
        }
    }

}
