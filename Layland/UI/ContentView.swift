import SwiftUI

struct ContentView: View {
    @Environment(ScanSession.self) private var session
    /// Split-view state is kept separate from the preference: the split view collapses the
    /// column on its own during window setup, and that must not flip `showsLegend`.
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    private var wantsSidebar: Bool {
        session.showsLegend && (session.phase == .finished || session.isPreparingMap || session.isEditingPalette)
    }

    private func applySidebarState() {
        let wanted = wantsSidebar
        if (columnVisibility != .detailOnly) != wanted {
            columnVisibility = wanted ? .all : .detailOnly
        }
        if session.sidebarVisible != wanted {
            session.sidebarVisible = wanted
        }
    }

    var body: some View {
        @Bindable var session = session
        // A NavigationSplitView sidebar: inset glass on macOS 26, plain on earlier systems.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LegendSidebar()
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 360)
        } detail: {
            // The map is built as soon as there's a result, underneath the scanning screen, and
            // only uncovered once it has drawn: no blank frame when it appears.
            ZStack {
                if session.isEditingPalette || session.result != nil {
                    TreemapScreen()
                }
                if !session.isEditingPalette, session.phase != .finished {
                    Group {
                        switch session.phase {
                        case .idle:
                            WelcomeView()
                        case .scanning:
                            ScanningView()
                        case .finished:
                            EmptyView()
                        case let .failed(message):
                            ContentUnavailableView {
                                Label("Scan Failed", systemImage: "exclamationmark.triangle")
                            } description: {
                                Text(message)
                            } actions: {
                                Button("Choose Another Folder…") { session.chooseFolder() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .contentShape(Rectangle())
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        // Toggling the preference animates; the sidebar simply appearing with a finished scan
        // (window open, load) does not.
        .onChange(of: session.showsLegend) { _, _ in
            withAnimation { applySidebarState() }
        }
        .onChange(of: session.phase) { _, _ in applySidebarState() }
        .onChange(of: session.isEditingPalette) { _, _ in applySidebarState() }
        .onChange(of: session.isPreparingMap) { _, _ in applySidebarState() }
        .onChange(of: session.licensing.isUnlocked) { _, _ in session.licenseDidChange() }
        .onAppear { applySidebarState() }
        .onChange(of: columnVisibility) { _, visibility in
            // The user dragged the column closed (or open): remember that.
            let visible = visibility != .detailOnly
            if session.sidebarVisible != visible {
                withAnimation { session.sidebarVisible = visible }
            }
            if session.phase == .finished || session.isEditingPalette, session.showsLegend != visible {
                session.showsLegend = visible
            }
        }
        .confirmationDialog(
            trashTitle,
            isPresented: Binding(get: { session.pendingTrash != nil }, set: { if !$0 { session.pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { session.confirmTrash() }
            Button("Cancel", role: .cancel) { session.pendingTrash = nil }
        } message: {
            if let tree = session.tree, let node = session.pendingTrash {
                Text("\(Format.bytes(tree[node].size(session.sizeMode))) will be moved to the Trash. You can restore it from the Trash until you empty it.")
            }
        }
        // Applies to dialogs presented from the view it modifies, so it goes right after the
        // confirmation (and before the error alert, which shouldn't offer it).
        .dialogSuppressionToggle("Don't ask again", isSuppressed: $session.skipsTrashConfirmation)
        .alert("Couldn't Move to Trash", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private var trashTitle: String {
        guard let tree = session.tree, let node = session.pendingTrash else { return "" }
        return "Move “\(tree.name(node))” to the Trash?"
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(ScanSession.self) private var session

    var body: some View {
        VStack(spacing: 28) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Layland")
                    .font(.largeTitle.weight(.semibold))
                Text("See what's taking up space, in seconds.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                Button {
                    session.scanHomeFolder()
                } label: {
                    Label("Scan Home Folder", systemImage: "house")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                Button {
                    session.scanStartupDisk()
                } label: {
                    Label("Scan Startup Disk", systemImage: "internaldrive")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    session.chooseFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                let recents = session.recentFolders.filter { FileManager.default.fileExists(atPath: $0) }
                if !recents.isEmpty {
                    RecentFoldersButton(paths: recents)
                }
            }
            .controlSize(.large)
            .frame(width: 260)
            Text("For a complete picture, grant Layland Full Disk Access in System Settings → Privacy & Security.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A regular button (so it sizes like its neighbors; a SwiftUI `Menu` won't stretch) that
/// drops down a native menu of recently scanned folders.
struct RecentFoldersButton: View {
    @Environment(ScanSession.self) private var session
    let paths: [String]
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            anchor.popUp(menu())
        } label: {
            HStack(spacing: 6) {
                Label("Recent Folders", systemImage: "clock.arrow.circlepath")
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .background(anchor)
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        for path in paths {
            let item = ClosureMenuItem(title: FileManager.default.displayName(atPath: path)) { session.scan(path: path) }
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.toolTip = path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Clear Menu") { session.clearRecentFolders() })
        return menu
    }
}

/// Invisible view marking where a pop-up menu should appear (just below it).
struct MenuAnchor: NSViewRepresentable {
    private final class Box { weak var view: NSView? }
    private let box = Box()

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }

    func popUp(_ menu: NSMenu) {
        guard let view = box.view else { return }
        menu.minimumWidth = view.bounds.width
        let origin = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4)
        menu.popUp(positioning: nil, at: origin, in: view)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

// MARK: - Scanning

struct ScanningView: View {
    @Environment(ScanSession.self) private var session

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text("Scanning \(session.rootPath ?? "")")
                    .font(.title3.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Format.count(session.progress.files)) files · \(Format.count(session.progress.directories)) folders · \(Format.bytes(session.progress.logicalBytes))")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("\(session.progress.fraction.formatted(.percent.precision(.fractionLength(0)))) · \(Format.duration(session.elapsed))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            ProgressView(value: session.progress.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 420)
            Text(session.progress.currentPath)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 600)
            HStack {
                Button("Cancel") { session.reset() }
                    .keyboardShortcut(.cancelAction)
                Button("Stop and Show Results") { session.cancelScan() }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Treemap screen

struct TreemapScreen: View {
    @Environment(ScanSession.self) private var session

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            if session.isEditingPalette {
                SampleDataBanner()
                Divider()
            } else if session.showsFullDiskAccessHint {
                FullDiskAccessBanner()
                Divider()
            }
            BreadcrumbBar()
            Divider()
            if let tree = session.displayedTree {
                TreemapHostView(
                    tree: tree,
                    configuration: session.treemapConfiguration,
                    selection: session.selection,
                    highlightedNodes: session.searchMatches,
                    quickLookRequest: session.quickLookRequest,
                    onHover: { session.hovered = $0 },
                    onSelect: { session.selection = $0 },
                    onOpen: { session.open($0) },
                    onRender: { session.mapDidRender() },
                    onDelete: { session.requestTrash($0) },
                    isLocked: { session.isLocked($0) },
                    onLocked: { _ in session.requestUnlock(ScanSession.lockedItemReason) }
                )
            }
            Divider()
            StatusBar()
        }
        .searchable(text: $session.searchText, placement: .toolbar, prompt: "Search file names")
        .onSubmit(of: .search) { session.selectNextMatch() }
        .toolbar {
            // Nothing while the map is still hidden behind the scanning screen.
            if session.phase == .finished || session.isEditingPalette {
                treemapToolbar
            }
        }
    }

    @ToolbarContentBuilder
    private var treemapToolbar: some ToolbarContent {
        @Bindable var session = session
        ToolbarItemGroup(placement: .automatic) {
            Button {
                session.zoomOut()
            } label: {
                Label("Zoom Out", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(!session.canZoomOut)
            .help("Zoom out to the enclosing folder (⌘↑)")
            Button {
                session.zoomIntoSelection()
            } label: {
                Label("Zoom In", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .disabled(session.selection == nil)
            .help("Zoom into the selected folder (⌘↓)")
            Button {
                if let node = session.selection { session.revealInFinder(node) }
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(!session.canRevealSelection)
            .help("Show the selected item in Finder (⌘↩)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Size", selection: $session.sizeMode) {
                ForEach(SizeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Logical size counts bytes as reported; size on disk counts allocated blocks.")
            Button {
                session.rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Scan the same folder again (⌘R)")
            .disabled(session.isEditingPalette)
        }
    }
}

struct SampleDataBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "paintpalette")
                .foregroundStyle(.tint)
            Text("Showing sample data with every file category while the palette editor is open. Close the editor to return to your scan.")
                .lineLimit(2)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.tint.opacity(0.10))
    }
}

/// Back + sidebar toggle. Lives at the leading edge of the detail toolbar while the sidebar is
/// hidden, and moves into the sidebar's toolbar when it is shown (like Notes).
struct NavigationButtons: View {
    @Environment(ScanSession.self) private var session

    var body: some View {
        @Bindable var session = session
        HStack(spacing: 0) {
            Button {
                session.reset()
            } label: {
                Label("New Scan", systemImage: "chevron.backward")
            }
            .help("Back to the start screen to scan something else (⌘N)")
            // A plain button (not a Toggle) so it isn't drawn highlighted while the sidebar is open,
            // like the sidebar button in Notes or Finder.
            Button {
                withAnimation { session.showsLegend.toggle() }
            } label: {
                Label("Legend", systemImage: "sidebar.leading")
            }
            .help("Show or hide the legend sidebar (⌥⌘L)")
        }
    }
}

struct BreadcrumbBar: View {
    @Environment(ScanSession.self) private var session

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if let tree = session.displayedTree {
                    let chain = tree.ancestors(of: session.zoomRoot)
                    ForEach(Array(chain.enumerated()), id: \.element) { position, node in
                        if position > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            session.zoomRoot = node
                        } label: {
                            if session.isLocked(node) {
                                Label("Locked", systemImage: "lock.fill")
                                    .foregroundStyle(.secondary)
                                    .fontWeight(position == chain.count - 1 ? .semibold : .regular)
                                    .lineLimit(1)
                            } else {
                                Text(position == 0 ? tree.rootPath : tree.name(node))
                                    .fontWeight(position == chain.count - 1 ? .semibold : .regular)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(position == chain.count - 1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

struct StatusBar: View {
    @Environment(ScanSession.self) private var session

    var body: some View {
        // With the unlock hint when everything fits at full length, else without it: the path
        // gets the room first.
        ViewThatFits(in: .horizontal) {
            content(showsHint: wantsHint)
            content(showsHint: false)
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 30)
        .background(.bar)
    }

    /// Unlicensed, and search isn't already showing its own unlock link.
    private var wantsHint: Bool {
        !session.licensing.isUnlocked && !session.isEditingPalette && !session.searchIsLocked
    }

    private func content(showsHint: Bool) -> some View {
        HStack(spacing: 12) {
            if let tree = session.displayedTree, let node = session.focusNode {
                if node < 0, let result = session.result {
                    let free = node == TreemapCell.freeSpaceNode
                    Text(free ? "Free space on the volume" : "Used elsewhere on the volume (system, apps, other users, snapshots…)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(Format.bytes(free ? result.freeSpace : max(0, result.volumeSize - result.freeSpace - tree[FileTree.rootIndex].size(session.sizeMode))))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                } else if node >= 0 {
                    let item = tree[node]
                    let root = tree[session.zoomRoot]
                    let size = item.size(session.sizeMode)
                    if session.isLocked(node) {
                        // The free tier names the nearest shallow folder, never files or deep folders.
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                        Text(tree.path(session.freeAncestor(of: node)) + "/…")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Show Name…") { session.requestUnlock(ScanSession.lockedItemReason) }
                            .buttonStyle(.link)
                            .fixedSize()
                    } else {
                        Text(tree.path(node))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Text(detail(item: item, size: size, of: root.size(session.sizeMode)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            } else {
                Text("Hover over the map to inspect items. Double-click a folder to zoom in.")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
            }
            if session.searchIsLocked {
                Divider().frame(height: 14)
                Button {
                    session.requestUnlock("Search needs a license.")
                } label: {
                    Label("Search needs a license", systemImage: "lock.fill")
                }
                .buttonStyle(.link)
                .fixedSize()
            } else if let matches = session.searchMatches {
                Divider().frame(height: 14)
                Text(matches.isEmpty ? "No matches" : "\(Format.count(matches.count)) matches" + (session.searchPosition.map { " · \($0 + 1)" } ?? ""))
                    .foregroundStyle(matches.isEmpty ? .secondary : .primary)
                    .monospacedDigit()
                    .fixedSize()
                    .help("⌘G selects the next match")
            }
            if let result = session.result, !session.isEditingPalette {
                Divider().frame(height: 14)
                Text(summary(result))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            if showsHint {
                Divider().frame(height: 14)
                Button {
                    session.requestUnlock(nil)
                } label: {
                    Label("Unlock Layland…", systemImage: "lock.fill")
                }
                .buttonStyle(.link)
                .fixedSize()
            }
        }
    }

    private func detail(item: FileNode, size: Int64, of total: Int64) -> String {
        var parts = [Format.bytes(size), Format.percent(size, of: total)]
        if item.isDirectory {
            parts.append("\(Format.count(item.itemCount)) items")
        }
        if session.colorMode == .modified, item.modTime > 0 {
            parts.append("modified " + Date(timeIntervalSince1970: TimeInterval(item.modTime)).formatted(date: .abbreviated, time: .omitted))
        }
        if item.flags.contains(.inaccessible) { parts.append("not readable") }
        if item.flags.contains(.mountPoint) { parts.append("separate volume, not scanned") }
        if item.flags.contains(.hardLinkDuplicate) { parts.append("hard link, counted elsewhere") }
        if item.kind == .symlink { parts.append("symlink") }
        return parts.joined(separator: " · ")
    }

    private func summary(_ result: ScanResult) -> String {
        let stats = result.statistics
        let total = result.tree[FileTree.rootIndex].size(session.sizeMode)
        var text = "\(Format.count(stats.files)) files · \(Format.bytes(total)) · \(Format.duration(result.duration))"
        if result.cancelled { text += " · partial" }
        if let loadedFrom = session.loadedFrom {
            text += " · from \(loadedFrom.lastPathComponent), \(result.date.formatted(date: .abbreviated, time: .shortened))"
        }
        return text
    }
}

/// Sidebar: color legend for the current mode, plus the scan's key facts.
struct LegendSidebar: View {
    @Environment(ScanSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var session = session
        let palette = TreemapPalette(spec: session.paletteSpec, dark: colorScheme == .dark)
        var entries = TreemapPalette.legend(for: session.colorMode)
        let showsVolume = session.showsVolume && !session.isEditingPalette && (session.result?.volumeSize ?? 0) > 0
        if showsVolume {
            entries.append((TreemapPalette.freeSpaceSlot, "Free space"))
            entries.append((TreemapPalette.otherSpaceSlot, "Elsewhere on volume"))
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Color by")
                        .font(.headline)
                    // A Menu rather than a bare Picker: the pre-Tahoe pop-up mis-sizes a
                    // label-less picker, while a pull-down with an explicit title is fine everywhere.
                    Menu {
                        Picker("Color by", selection: $session.colorMode) {
                            ForEach(ColorMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(session.colorMode.title)
                    }
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entries, id: \.slot) { entry in
                            swatch(palette.displayedColor(entry.slot), entry.title)
                        }
                    }
                    .padding(.top, 4)
                }

                if let result = session.result, !session.isEditingPalette {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan")
                            .font(.headline)
                        fact("Folder", result.tree.rootPath)
                        fact("Scanned", result.date.formatted(date: .abbreviated, time: .shortened))
                        fact("Files", Format.count(result.statistics.files))
                        fact("Folders", Format.count(result.statistics.directories))
                        fact("Logical size", Format.bytes(result.tree[FileTree.rootIndex].logicalSize))
                        fact("On disk", Format.bytes(result.tree[FileTree.rootIndex].allocatedSize))
                        if result.volumeSize > 0 {
                            fact("Volume", Format.bytes(result.volumeSize))
                            fact("Free", Format.bytes(result.freeSpace))
                        }
                        if result.statistics.permissionDenied > 0 {
                            fact("Unreadable", "\(Format.count(result.statistics.permissionDenied)) folders")
                        }
                        fact("Duration", Format.duration(result.duration))
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .toolbar {
            // Always declared here: the toolbar's sidebar section is the run of items before the
            // tracking separator, so when the column collapses these slide with the separator
            // to the leading edge instead of being removed and re-added elsewhere.
            // The welcome screen has nothing to go back from and no legend to show.
            if session.phase != .idle || session.isEditingPalette {
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.flexible)
                }
                ToolbarItem(placement: .automatic) { NavigationButtons() }
            }
        }
    }

    private func swatch(_ rgb: SIMD3<Float>, _ title: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(.sRGB, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.15)))
                .frame(width: 14, height: 14)
            Text(title)
                .lineLimit(1)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

struct FullDiskAccessBanner: View {
    @Environment(ScanSession.self) private var session

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            Text("\(Format.count(session.result?.statistics.permissionDenied ?? 0)) folders couldn't be read. Grant Layland Full Disk Access to include them, then rescan.")
                .lineLimit(2)
            Spacer()
            Button("Open Privacy Settings") { session.openFullDiskAccessSettings() }
            Button {
                session.showsFullDiskAccessHint = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
}
