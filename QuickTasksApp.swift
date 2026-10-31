import SwiftUI
import AppIntents
#if os(iOS)
import UIKit
#endif

#if os(iOS)
/// Long-press the Kitty icon on the Home Screen and choose "Talk to Kitty".
enum KittyQuickAction {
    static let talkType = "kitty.talk"

    static func install() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(type: talkType,
                                      localizedTitle: "Talk to Kitty",
                                      localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "mic.fill"),
                                      userInfo: nil)
        ]
    }

    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == talkType else { return false }
        Task { @MainActor in LaunchRouter.shared.requestConversation() }
        return true
    }
}

final class KittyAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { KittyQuickAction.handle(item) }   // the app was launched from the icon menu
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = KittySceneDelegate.self
        return config
    }
}

final class KittySceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(KittyQuickAction.handle(shortcutItem))
    }
}
#endif

@main
struct QuickTasksApp: App {
    @StateObject private var store = TaskStore.shared
    #if os(iOS)
    @UIApplicationDelegateAdaptor(KittyAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .tint(Color.indigo)
                .task {
                    #if os(iOS)
                    KittyQuickAction.install()
                    #endif
                    store.refreshRoutines()
                    // The accurate speech model takes a while to load, so start it now rather than when the mic opens.
                    if SpeechEngineChoice.effective() == .whisperTurbo {
                        WhisperAccurate.shared.prepare(keyTerms: KeyTerms.build(household: VocabularyProvider.current()))
                        WhisperAccurate.shared.unloadSoon()      // let go again if the conversation is not opened
                    }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var convo = VoiceConversation()
    @ObservedObject private var router = LaunchRouter.shared
    @StateObject private var wake = WakeWordListener()
    @AppStorage("kitty.heyKittyInApp") private var heyKitty = false
    @State private var showConversation = false
    @State private var seedText: String?
    @State private var seedIsVoice = false
    @State private var route: TasksRoute?
    @State private var chips: [HomeChip] = []       // set when the screen appears, so they never move while you look
    @State private var showLibrary = false
    @State private var query = ""
    @State private var queryFocused = false

    private func refreshChips() {
        chips = HomeLabels.row(index: store.tagIndex, tasks: store.tasks, profiles: store.profiles,
                               recentTaps: RecentLabels.list(), tapDates: RecentLabels.dates())
    }

    private func open(_ chip: HomeChip) {
        if chip.kind == .label { RecentLabels.note(chip.name) }      // only labels are "labels you use"; the smart views are always there
        route = TasksRoute(chip)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let typing = queryFocused
                ZStack {
                    Color.screenBackground.ignoresSafeArea()
                        .onTapGesture { queryFocused = false }
                    // Typing does not remove anything: the same views glide to a compact, top-anchored version in one animation. The
                    // title shrinks, the big mic shrinks away and a small mic appears beside the box, and the box slides up under the
                    // header and grows downward with every line in view (there is room above the keyboard). The layout depends only
                    // on `typing`, never on the keyboard, so nothing jumps while the keyboard slides up. The box is one view that is
                    // never moved between branches (that would close the keyboard).
                    VStack(spacing: 0) {
                        VStack(spacing: typing ? 10 : 30) {
                            VStack(spacing: 6) {
                                Text("Kitty")
                                    .font(.system(size: typing ? 30 : 54, weight: .bold, design: .rounded))
                                Text("What can I do for you?")
                                    .font(typing ? .subheadline : .title3)
                                    .foregroundStyle(.secondary)
                                wakeStatus
                            }
                            talkButton
                                .scaleEffect(typing ? 0.3 : 1)
                                .opacity(typing ? 0 : 1)
                                .frame(height: typing ? 0 : nil)
                                .clipped()
                                .allowsHitTesting(!typing)
                                .accessibilityHidden(typing)
                            HStack(alignment: .bottom, spacing: 0) {
                                searchBar(maxLines: typing && geo.size.height < 650 ? 4 : 6)
                                    .layoutPriority(1)
                                smallMic
                                    .scaleEffect(typing ? 1 : 0.3)
                                    .opacity(typing ? 1 : 0)
                                    .frame(width: typing ? 60 : 0, alignment: .trailing)
                                    .clipped()
                                    .allowsHitTesting(typing)
                                    .accessibilityHidden(!typing)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: typing ? .top : .center)
                        .padding(.top, typing ? 8 : 0)
                        taskLabels
                            .opacity(typing ? 0 : 1)
                            .allowsHitTesting(!typing)
                            .accessibilityHidden(typing)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
                .animation(.spring(response: 0.38, dampingFraction: 0.88), value: typing)
            }
            // The home layout never follows the keyboard: it changes only with `typing`, so nothing jumps behind the keypad.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .overlay(alignment: .top) { noticeBanner }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showLibrary = true } label: {
                            Label("Routines, playbooks & names", systemImage: "repeat")
                        }
                        Button { _ = store.clearCompleted() } label: {
                            Label("Clear completed", systemImage: "checkmark.circle")
                        }
                        Toggle(isOn: $heyKitty) {
                            Label("Listen for “Hey Kitty” while open", systemImage: "ear")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                store.refreshRoutines()
                refreshChips()
                wake.onWake = { openFromWake() }
                openIfRequested()
                updateWake()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    store.refreshRoutines()
                    refreshChips()
                    openIfRequested()
                }
                updateWake()
            }
            // Siri ("Hey Siri, talk to Kitty"), the Action Button or Back Tap asked for the conversation.
            .onChange(of: router.conversationRequested) { _, _ in openIfRequested() }
            .onChange(of: heyKitty) { _, _ in updateWake() }
            .onChange(of: showConversation) { _, open in updateWake(); if !open { refreshChips() } }
            .onChange(of: route) { _, now in updateWake(); if now == nil { refreshChips() } }
            .sensoryFeedback(.impact(weight: .light), trigger: route)
            .animation(.easeInOut(duration: 0.25), value: router.notice)
            .onChange(of: showLibrary) { _, _ in updateWake() }
            .fullScreenCover(isPresented: $showConversation, onDismiss: { seedText = nil; seedIsVoice = false }) {
                ConversationView(convo: convo, seed: seedText, seedIsVoice: seedIsVoice)
            }
            .sheet(item: $route) { route in
                switch route {
                case .all: TasksView(filter: PanelFilter(who: .all, category: nil, day: .all, status: .all))
                case .overdue: TasksView(filter: PanelFilter(who: .all, category: nil, day: .all, status: .overdue))
                case .today: TasksView(filter: PanelFilter(who: .all, category: nil, day: .today, status: .open))
                case .new: NewTasksView()
                case .label(let name): LabelTasksView(label: name)
                }
            }
            .sheet(isPresented: $showLibrary) { LibraryView() }
        }
    }

    /// When "Hey Kitty" is on, always say what it is doing and what it heard.
    @ViewBuilder
    private var wakeStatus: some View {
        if heyKitty {
            VStack(spacing: 2) {
                if wake.isListening {
                    Label("Say “Hey Kitty”", systemImage: "ear")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    if !wake.heard.isEmpty {
                        Text("Heard: “\(wake.heard)”")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else if let error = wake.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Starting “Hey Kitty”…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: The one big thing: talk to Kitty

    private var talkButton: some View {
        Button { startConversation(seed: nil) } label: {
            VStack(spacing: 14) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 112, height: 112)
                    .background(Color.accentColor, in: Circle())
                Text("Talk to Kitty")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
            }
        }
        .buttonStyle(.plain)
    }

    /// The small microphone beside the box while typing: the same as the big one, so you can still talk instead.
    private var smallMic: some View {
        Button { startConversation(seed: nil) } label: {
            Image(systemName: "mic.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.accentColor, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Talk to Kitty")
    }

    // MARK: Type a task or a question

    private func searchBar(maxLines: Int = 6) -> some View {
        TypedInputBox(placeholder: "Type a task or ask Kitty", text: $query, isFocused: $queryFocused,
                      leadingIcon: "magnifyingglass", maxLines: maxLines) { submitQuery() }
    }

    private func submitQuery() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        query = ""
        startConversation(seed: text)
    }

    private func startConversation(seed: String?, voice: Bool = false) {
        queryFocused = false
        seedText = seed
        seedIsVoice = voice && seed != nil
        showConversation = true
    }

    private func openIfRequested() {
        guard router.conversationRequested else { return }
        router.conversationRequested = false
        // Siri may have brought words along ("what are my tasks for today"): Kitty runs them, speaks the answer and listens on.
        let request = router.takeRequest()
        if showConversation {
            if let request { convo.submitTyped(request) }       // already open: run it in the conversation that is on screen
            return
        }
        if route != nil || showLibrary {
            // A sheet is open: close it first, then open the conversation once it is gone.
            route = nil
            showLibrary = false
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                startConversation(seed: request, voice: true)
            }
        } else {
            startConversation(seed: request, voice: true)
        }
    }

    private func openFromWake() {
        guard !showConversation else { return }
        startConversation(seed: nil)
    }

    /// "Hey Kitty" listens only when it is turned on, the app is in front, and nothing else is open.
    private func updateWake() {
        let shouldListen = heyKitty && scenePhase == .active && !showConversation && route == nil && !showLibrary
        if shouldListen { wake.start() } else { wake.stop() }
    }

    // MARK: A note about something that finished after the Talk screen closed

    @ViewBuilder
    private var noticeBanner: some View {
        if let text = router.notice {
            Button { router.clearNotice() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    Text(text).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading).lineLimit(3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.cardBackground, in: Capsule())
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    // MARK: One tap to a label's tasks

    /// Where your tasks are one tap away: the chip tray.
    private var taskLabels: some View {
        ChipTray(chips: chips.filter { $0.kind != .all }, onOpen: { open($0) }, onAll: { route = .all })
            .padding(.horizontal, -24)          // the tray runs edge to edge; its chips line up with the screen's margin
    }
}

/// Chips dealt into a fixed number of rows, each chip into the shortest row so far. The layout is as wide as its longest row, so a
/// scroll view around it scrolls sideways when the rows are longer than the screen.
struct PackedRowsLayout: Layout {
    var rows: Int
    var spacing: CGFloat = ChipTrayLevels.gap

    private func widths(_ subviews: Subviews) -> [CGFloat] { subviews.map { $0.sizeThatFits(.unspecified).width } }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = widths(subviews)
        let packed = ChipTrayLevels.pack(widths: w, rows: rows, spacing: spacing)
        let used = packed.filter { !$0.isEmpty }.count
        let width = packed.map { ChipTrayLevels.rowWidth($0, widths: w, spacing: spacing) }.max() ?? 0
        let height = used == 0 ? 0 : CGFloat(used) * ChipTrayLevels.rowHeight + CGFloat(used - 1) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(subviews)
        var y = bounds.minY
        for row in ChipTrayLevels.pack(widths: w, rows: rows, spacing: spacing) where !row.isEmpty {
            var x = bounds.minX
            for i in row {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += w[i] + spacing
            }
            y += ChipTrayLevels.rowHeight + spacing
        }
    }
}

private struct ChipWidthsKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// The home screen's chips. Two rows to start, scrolling sideways. A small dash above them is a handle: drag it up and the chips
/// re-pack into more rows (the tray follows your finger and settles on whole rows), drag it down for fewer. When every chip fits, the
/// sideways scroll goes away. Tapping the dash opens it all the way and back. The height you leave it at is kept. "All tasks" sits on
/// the dash line. What is late, today and new come first, then the labels you open most.
struct ChipTray: View {
    let chips: [HomeChip]
    var onOpen: (HomeChip) -> Void
    var onAll: () -> Void

    @AppStorage("kitty.chipRows") private var storedRows = ChipTrayLevels.startRows
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var widths: [String: CGFloat] = [:]
    @State private var trayWidth: CGFloat = 0
    @State private var drag: CGFloat = 0            // how far the finger has moved; up is negative
    @State private var dragging = false
    @State private var dragStartRows: Int?          // the rows it rested at when the finger came down: the drag is measured from here
    @State private var liveRows = ChipTrayLevels.startRows     // the rows shown while dragging; changes only well past a boundary

    private let dashHeight: CGFloat = 40
    private let margin: CGFloat = 24

    private var chipWidths: [CGFloat] { chips.map { widths[$0.id] ?? 90 } }
    private var maxRows: Int {
        ChipTrayLevels.rowsToFit(widths: chipWidths, available: max(trayWidth - 2 * margin, 0))
    }
    /// The rows it rests at: what you left it at, never more than fit. VoiceOver gets everything.
    private var rows: Int { voiceOver ? maxRows : min(max(storedRows, 1), maxRows) }
    /// The height while a finger is on the dash, for a finger that has moved `drag` from where it came down.
    private func height(forDrag drag: CGFloat) -> CGFloat {
        let start = dragStartRows ?? rows
        return min(max(ChipTrayLevels.height(rows: start) - drag, ChipTrayLevels.height(rows: min(1, maxRows))), ChipTrayLevels.height(rows: maxRows))
    }
    private var liveHeight: CGFloat { height(forDrag: drag) }
    private var shownRows: Int { dragging ? liveRows : rows }
    private var shownHeight: CGFloat { dragging ? liveHeight : ChipTrayLevels.height(rows: rows) }

    var body: some View {
        // The screen keeps room for the tray at rest. While you drag, it can pass over the space above for a moment.
        Color.clear
            .frame(height: dashHeight + ChipTrayLevels.height(rows: rows))
            .overlay(alignment: .bottom) { tray }
    }

    private var tray: some View {
        VStack(spacing: 0) {
            dashRow
            ScrollView(.horizontal) {
                PackedRowsLayout(rows: max(shownRows, 1)) {
                    ForEach(chips) { chip in
                        LabelChip(chip: chip) { onOpen(chip) }
                            .background(GeometryReader { Color.clear.preference(key: ChipWidthsKey.self, value: [chip.id: $0.size.width]) })
                    }
                }
                .padding(.horizontal, margin)
                .padding(.top, 2)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
            .frame(height: shownHeight, alignment: .top)
            .mask(fade)
        }
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
                .padding(.horizontal, 10)
                .opacity(shownRows > ChipTrayLevels.startRows ? 1 : 0)
        }
        .onPreferenceChange(ChipWidthsKey.self) { widths = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trayWidth = $0 }
        // The tray follows the finger exactly while it is down; only a release (or a tap) settles with an animation.
        .animation(dragging ? nil : .snappy(duration: 0.28), value: shownRows)
        .animation(dragging ? nil : .snappy(duration: 0.28), value: rows)
        .sensoryFeedback(.selection, trigger: shownRows)
    }

    /// A soft edge on both sides, so a chip that runs off the screen reads as "more this way".
    private var fade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 14)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 14)
        }
    }

    /// The dash (the handle) in the middle, "All tasks" at the right.
    private var dashRow: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(dragging ? 0.7 : 0.4))
                .frame(width: 36, height: 5)
                .frame(width: 120, height: dashHeight)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.28)) { storedRows = ChipTrayLevels.tapped(rows: rows, maxRows: maxRows) }
                }
                .gesture(
                    // Measured on the screen, not in the handle: the handle moves up with the tray, and a measure that moves with it
                    // feeds back into itself (the tray bounces under a fast finger).
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { v in
                            if dragStartRows == nil { dragStartRows = rows; liveRows = rows }
                            dragging = true
                            drag = v.translation.height
                            liveRows = ChipTrayLevels.snap(height: height(forDrag: v.translation.height), from: liveRows, maxRows: maxRows)
                        }
                        .onEnded { v in
                            // A quick flick carries on a little: settle where it was heading.
                            let start = dragStartRows ?? rows
                            let heading = ChipTrayLevels.height(rows: start) - (v.translation.height + v.predictedEndTranslation.height) / 2
                            let target = ChipTrayLevels.snap(height: heading, maxRows: maxRows)
                            dragStartRows = nil
                            withAnimation(.snappy(duration: 0.28)) {
                                if target > 0 { storedRows = target }
                                dragging = false
                                drag = 0
                            }
                        }
                )
                .accessibilityElement()
                .accessibilityLabel("Chip tray height")
                .accessibilityValue("\(rows) rows")
                .accessibilityAdjustableAction { direction in
                    storedRows = ChipTrayLevels.adjusted(rows: rows, by: direction == .increment ? 1 : -1, maxRows: maxRows)
                }
            HStack {
                Spacer()
                Button(action: onAll) {
                    HStack(spacing: 4) {
                        Text("All tasks")
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: dashHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, margin)
        }
        .frame(height: dashHeight)
    }
}

/// Routines, playbooks and diagnostics, kept out of the way of the daily list.
struct LibraryView: View {
    @ObservedObject private var store = TaskStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var crumbs: [String] = Breadcrumb.lines
    @State private var showSiriTip = true

    var body: some View {
        NavigationStack {
            List {
                #if os(iOS)
                Section {
                    SiriTipView(intent: TalkToKittyIntent(), isVisible: $showSiriTip)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                #endif

                Section("Routines") {
                    if store.routines.isEmpty {
                        Text("None yet. Say: “Every day the maid sweeps and mops.”")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.routines) { r in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(r.title).font(.body.weight(.medium))
                            FlowLayout(spacing: 6) {
                                TagPill(text: r.scheduleText.prefix(1).uppercased() + r.scheduleText.dropFirst(),
                                        icon: "repeat", color: .purple)
                                if !r.effectiveAssignee.isEmpty {
                                    TagPill(text: r.effectiveAssignee, icon: "person.fill",
                                            color: Assignee.color(for: r.effectiveAssignee))
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete(perform: store.removeRoutines)
                }

                Section("Lists") {
                    if store.profiles.isEmpty {
                        Text("None yet. Say: “Add milk to my Blinkit order.” Kitty makes the list the first time you mention it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.profiles) { list in
                        let items = store.items(in: list)
                        HStack(spacing: 10) {
                            Image(systemName: list.symbol).foregroundStyle(.orange).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(list.name).font(.body.weight(.medium))
                                Text("\(items.filter { !$0.isDone }.count) open · \(items.count) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { store.profiles[$0].id }
                        ids.forEach { store.removeProfile($0, deleteItems: true) }
                    }
                }

                Section("Playbooks") {
                    if store.playbooks.isEmpty {
                        Text("None yet. Say: “Here’s how I make biryani…” and list the steps and who does them.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.playbooks) { pb in
                        DisclosureGroup {
                            ForEach(Array(pb.steps.enumerated()), id: \.offset) { index, step in
                                HStack(spacing: 8) {
                                    Text("\(index + 1).").foregroundStyle(.secondary)
                                    Text(step.title)
                                    Spacer()
                                    if let who = step.assignee {
                                        TagPill(text: who, icon: "person.fill", color: Assignee.color(for: who))
                                    }
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pb.name).font(.body.weight(.medium))
                                Text("\(pb.steps.count) tasks").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { store.playbooks[$0].id }
                        ids.forEach { store.removePlaybook($0) }
                    }
                }

                Section("Household") {
                    NavigationLink {
                        GuideEditorView()
                    } label: {
                        Label("Names and spellings", systemImage: "text.book.closed")
                    }
                }

                Section("Diagnostics") {
                    if crumbs.isEmpty {
                        Text("Nothing logged.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced())
                    }
                    Button("Refresh") { crumbs = Breadcrumb.lines }
                    Button("Clear", role: .destructive) {
                        Breadcrumb.clear()
                        crumbs = []
                    }
                }
            }
            .navigationTitle("Routines & playbooks")
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { crumbs = Breadcrumb.lines }
        }
    }
}


/// Names and spellings Kitty should recognise. Reference vocabulary only: it is never turned into tasks.
struct GuideEditorView: View {
    @ObservedObject private var guide = KittyGuide.shared

    var body: some View {
        Form {
            Section {
                TextEditor(text: $guide.household).frame(minHeight: 160)
            } header: {
                Text("Names and spellings")
            } footer: {
                Text("For example: Rani is the house help. Suresh is the cook. Kitty uses these only to hear and spell names correctly; they never become tasks.")
            }
        }
        .navigationTitle("Household words")
        .inlineNavTitle()
        .scrollDismissesKeyboard(.interactively)
    }
}


/// A plain text box that is one line to start and grows with every line you add, up to `maxLines` (then it scrolls inside). Return makes
/// a new line, so the keyboard has no Send key. A long line wraps and grows it too. The height is set ONLY by an invisible copy of the
/// text; the editor is drawn over that copy, so the box never takes more room than its text needs (a bare `TextEditor` fills all it is
/// offered). Every line you wrote stays in view while it fits.
struct GrowingTextBox: View {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    var maxLines = 6
    @FocusState private var focus: Bool

    private var sizer: String { text.isEmpty ? " " : (text.hasSuffix("\n") ? text + " " : text) }

    var body: some View {
        Text(sizer)
            .lineLimit(1...maxLines)
            .opacity(0)
            .padding(.horizontal, 5)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Always its full height for the width it is given: a parent that is short of room (the home screen with the keyboard
            // up) must not squeeze the box back to one line.
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .focused($focus)
                    .accessibilityLabel(placeholder)
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: focus) { _, now in if isFocused != now { isFocused = now } }
            .onChange(of: isFocused) { _, now in if focus != now { focus = now } }
    }
}

/// The typing box used on the home screen and in the conversation: the same box, the same send button inside it, the same Done button
/// above the keyboard. Only what is around it differs (the home screen has a search icon, the conversation has the mic beside it).
struct TypedInputBox: View {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    var leadingIcon: String? = nil
    var maxLines = 6
    var onSend: () -> Void

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let leadingIcon {
                Image(systemName: leadingIcon).foregroundStyle(.secondary).padding(.bottom, 9)
            }
            GrowingTextBox(placeholder: placeholder, text: $text, isFocused: $isFocused, maxLines: maxLines)
            if canSend {
                Button(action: onSend) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .padding(.bottom, 6)
                    .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFocused = false }
            }
        }
    }
}
