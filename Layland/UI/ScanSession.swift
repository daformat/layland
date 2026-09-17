import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// UI-facing state for one window: the current scan, the resulting tree, and the treemap's
/// zoom/selection state.
@MainActor
@Observable
final class ScanSession {
    enum Phase: Equatable {
        case idle
        case scanning
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress = ScanProgress()
    private(set) var elapsed: TimeInterval = 0
    private(set) var result: ScanResult?
    private(set) var rootPath: String?
    /// Bumped whenever the tree is mutated in place (e.g. after trashing an item).
    private(set) var treeVersion = 0

    var zoomRoot: Int32 = FileTree.rootIndex
    var selection: Int32?
    var hovered: Int32?
    var sizeMode: SizeMode = .logical
    /// Gap between cells in device pixels (View ▸ Cell Margin). Persisted.
    var cellMargin: Int = UserDefaults.standard.integer(forKey: "cellMargin") {
        didSet { UserDefaults.standard.set(cellMargin, forKey: "cellMargin") }
    }
    /// View ▸ Color Palette. Persisted.
    var paletteSelection = PaletteSelection(storageKey: UserDefaults.standard.string(forKey: "paletteScheme") ?? "") {
        didSet { UserDefaults.standard.set(paletteSelection.storageKey, forKey: "paletteScheme") }
    }
    /// The live working copy behind `PaletteSelection.custom`. Persisted.
    var customColors: [UInt32] = ScanSession.loadCustomColors() {
        didSet { UserDefaults.standard.set(customColors.map { Int($0) }, forKey: "customPalette") }
    }
    /// Palettes saved from the editor. Persisted.
    var userPalettes: [UserPalette] = ScanSession.loadUserPalettes() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(userPalettes), forKey: "userPalettes") }
    }

    /// View ▸ Color By. Persisted.
    var colorMode: ColorMode = ColorMode(rawValue: UserDefaults.standard.string(forKey: "colorMode") ?? "") ?? .fileType {
        didSet { UserDefaults.standard.set(colorMode.rawValue, forKey: "colorMode") }
    }
    /// View ▸ Show Legend. Persisted; on by default.
    var showsLegend: Bool = UserDefaults.standard.object(forKey: "showsLegend") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsLegend, forKey: "showsLegend") }
    }
    /// Mirrors the split view: true while the sidebar column is actually on screen.
    var sidebarVisible = false
    /// View ▸ Cushion Strength. Persisted.
    var cushionStrength: CushionStrength = CushionStrength(rawValue: UserDefaults.standard.string(forKey: "cushionStrength") ?? "") ?? .normal {
        didSet { UserDefaults.standard.set(cushionStrength.rawValue, forKey: "cushionStrength") }
    }
    /// View ▸ Show Free Space. Persisted.
    var showsVolume: Bool = UserDefaults.standard.bool(forKey: "showsVolume") {
        didSet { UserDefaults.standard.set(showsVolume, forKey: "showsVolume") }
    }

    /// Folders scanned most recently, newest first, for the welcome screen. Persisted.
    private(set) var recentFolders: [String] = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? [] {
        didSet { UserDefaults.standard.set(recentFolders, forKey: "recentFolders") }
    }
    static let maxRecentFolders = 10

    var paletteSpec: PaletteSpec { PaletteSpec(mode: colorMode, colors: colors(for: paletteSelection)) }

    /// Everything the treemap view needs besides the tree itself.
    var treemapConfiguration: TreemapView.Configuration {
        var volume: TreemapLayout.VolumeInfo?
        if showsVolume, !isEditingPalette, let result, result.volumeSize > 0 {
            volume = TreemapLayout.VolumeInfo(size: result.volumeSize, free: result.freeSpace)
        }
        return TreemapView.Configuration(
            root: zoomRoot, sizeMode: sizeMode, margin: cellMargin, palette: paletteSpec,
            referenceTime: (isEditingPalette ? Date() : result?.date ?? Date()).timeIntervalSince1970,
            volume: volume, shape: cushionStrength.shape, version: treeVersion
        )
    }

    // MARK: License

    let licensing = Licensing()
    /// The free tier shows names, paths and actions for folders at most this many levels below
    /// the scanned folder. Files and deeper folders need a license: their names are exactly
    /// what it sells. The map itself is never limited.
    static let freeDepth = 2
    /// Opens the license window; installed by the app, which can open windows.
    @ObservationIgnored var openLicenseWindow: (() -> Void)?
    /// Why the window was opened, for its headline; nil when opened from the menu.
    private(set) var unlockReason: String?

    /// True when `node`'s details are hidden because this copy isn't unlocked.
    func isLocked(_ node: Int32) -> Bool {
        guard node > FileTree.rootIndex, !isEditingPalette, !licensing.isUnlocked, let tree = displayedTree else { return false }
        return !tree[node].isDirectory || tree.depth(node) > Self.freeDepth
    }

    /// The deepest folder containing `node` whose name the free tier still shows.
    func freeAncestor(of node: Int32) -> Int32 {
        guard let tree = displayedTree else { return node }
        var current = tree[node].parent
        while current > FileTree.rootIndex, isLocked(current) {
            current = tree[current].parent
        }
        return max(current, FileTree.rootIndex)
    }

    func requestUnlock(_ reason: String?) {
        unlockReason = reason
        openLicenseWindow?()
    }

    /// The licence changed (activated, removed, lapsed): redo what the free tier withheld.
    func licenseDidChange() {
        scheduleSearch()
    }

    // MARK: Search

    /// The toolbar search field. Matching runs off the main thread, debounced.
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    private(set) var searchMatches: [Int32]?
    private(set) var searchPosition: Int?
    private var searchTask: Task<Void, Never>?

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !searchIsLocked, let tree = displayedTree else {
            searchMatches = nil
            searchPosition = nil
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) { tree.search(query).filter { !tree.isRemoved($0) } }.value
            guard !Task.isCancelled, let self, self.displayedTree === tree else { return }
            searchMatches = matches
            searchPosition = nil
        }
    }

    /// Search needs a license: it would point straight at the locked items.
    var searchIsLocked: Bool {
        !licensing.isUnlocked && !isEditingPalette && !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Selects the next match (wrapping), zooming out to the scan root if it is not in view.
    func selectNextMatch() {
        if searchIsLocked {
            requestUnlock("Search needs a license.")
            return
        }
        guard let searchMatches, !searchMatches.isEmpty, let tree = displayedTree else { return }
        let next = ((searchPosition ?? -1) + 1) % searchMatches.count
        searchPosition = next
        let node = searchMatches[next]
        if node != zoomRoot, !tree.isAncestor(zoomRoot, of: node) {
            zoomRoot = FileTree.rootIndex
        }
        selection = node
    }

    // MARK: Quick Look

    /// Bumped to toggle the Quick Look panel from the menu.
    private(set) var quickLookRequest = 0

    func toggleQuickLook() {
        guard let selection, !isEditingPalette else { return }
        if isLocked(selection) {
            requestUnlock(Self.lockedItemReason)
            return
        }
        quickLookRequest += 1
    }

    // MARK: Files

    /// Where the current result was loaded from, if it came from a `.layland` file.
    private(set) var loadedFrom: URL?

    func colors(for selection: PaletteSelection) -> [UInt32] {
        switch selection {
        case let .builtIn(scheme): TreemapPalette.presetColors[scheme]!
        case let .user(id): userPalettes.first { $0.id == id }?.colors ?? customColors
        case .custom: customColors
        }
    }

    func title(for selection: PaletteSelection) -> String {
        switch selection {
        case let .builtIn(scheme): scheme.title
        case let .user(id): userPalettes.first { $0.id == id }?.name ?? "Deleted preset"
        case .custom: "Custom"
        }
    }

    private static func loadCustomColors() -> [UInt32] {
        if let stored = UserDefaults.standard.array(forKey: "customPalette") as? [Int], stored.count == TreemapPalette.fileSlotCount {
            return stored.map { UInt32(clamping: $0) }
        }
        return TreemapPalette.presetColors[PaletteScheme.fallback]!
    }

    private static func loadUserPalettes() -> [UserPalette] {
        guard let data = UserDefaults.standard.data(forKey: "userPalettes"),
              let palettes = try? JSONDecoder().decode([UserPalette].self, from: data)
        else { return [] }
        return palettes.filter { $0.colors.count == TreemapPalette.fileSlotCount }
    }

    /// True while the palette editor window is open: the treemap then shows `SampleTree`.
    private(set) var isEditingPalette = false
    private var savedNavigation: (zoomRoot: Int32, selection: Int32?)?
    var pendingTrash: Int32?
    /// Set by the confirmation's "Don't ask again" checkbox. Persisted.
    var skipsTrashConfirmation: Bool = UserDefaults.standard.bool(forKey: "skipsTrashConfirmation") {
        didSet { UserDefaults.standard.set(skipsTrashConfirmation, forKey: "skipsTrashConfirmation") }
    }
    var errorMessage: String?
    var showsFullDiskAccessHint = false

    /// A finished scan whose map is drawing behind the scanning screen, so it appears fully
    /// drawn; `mapDidRender()` (or a timeout) reveals it.
    private(set) var isPreparingMap = false
    private var revealTask: Task<Void, Never>?
    private var scanner: DiskScanner?
    private var scanTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    var tree: FileTree? { result?.tree }
    /// What the treemap shows: sample data while editing the palette, else the scan.
    var displayedTree: FileTree? { isEditingPalette ? SampleTree.shared : result?.tree }
    var isScanning: Bool { phase == .scanning }
    /// The node the status bar describes: what the mouse is over, else the selection.
    var focusNode: Int32? { hovered ?? selection }

    // MARK: Scanning

    func scan(path: String) {
        scanner?.cancel()
        scanTask?.cancel()
        progressTask?.cancel()

        stopPreparingMap()

        let scanner = DiskScanner(rootPath: path)
        self.scanner = scanner
        rootPath = scanner.rootPath
        noteRecentFolder(scanner.rootPath)
        phase = .scanning
        progress = ScanProgress()
        elapsed = 0
        result = nil
        selection = nil
        hovered = nil
        zoomRoot = FileTree.rootIndex
        showsFullDiskAccessHint = false

        let started = Date()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                progress = scanner.progress()
                elapsed = Date().timeIntervalSince(started)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        scanTask = Task { [weak self] in
            do {
                let result = try await scanner.runAsync()
                guard let self, self.scanner === scanner else { return }
                finish(result)
            } catch {
                guard let self, self.scanner === scanner else { return }
                progressTask?.cancel()
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func finish(_ result: ScanResult) {
        progressTask?.cancel()
        self.result = result
        loadedFrom = nil
        treeVersion += 1
        showsFullDiskAccessHint = result.statistics.permissionDenied > 0
        isPreparingMap = true
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.mapDidRender() }
        }
        scheduleSearch()
    }

    /// The treemap view has drawn the current tree: swap the scanning screen for it.
    func mapDidRender() {
        guard isPreparingMap else { return }
        stopPreparingMap()
        phase = .finished
    }

    private func stopPreparingMap() {
        isPreparingMap = false
        revealTask?.cancel()
        revealTask = nil
    }

    func saveScan() {
        guard let result else { return }
        guard licensing.isUnlocked else {
            requestUnlock("Saving scans needs a license.")
            return
        }
        Task {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(exportedAs: ScanArchive.typeIdentifier)]
            panel.nameFieldStringValue = (result.tree.rootPath as NSString).lastPathComponent.isEmpty
                ? "Scan.\(ScanArchive.fileExtension)"
                : "\((result.tree.rootPath as NSString).lastPathComponent).\(ScanArchive.fileExtension)"
            panel.canCreateDirectories = true
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do {
                try await Task.detached(priority: .userInitiated) { try ScanArchive.write(result, to: url) }.value
                loadedFrom = url
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openScan() {
        guard licensing.isUnlocked else {
            requestUnlock("Opening saved scans needs a license.")
            return
        }
        Task {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(exportedAs: ScanArchive.typeIdentifier)]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Open"
            guard await panel.begin() == .OK, let url = panel.url else { return }
            load(url: url)
        }
    }

    /// Shows a scan saved with `saveScan()`.
    func load(url: URL) {
        guard licensing.isUnlocked else {
            requestUnlock("Opening saved scans needs a license.")
            return
        }
        scanner?.cancel()
        scanTask?.cancel()
        progressTask?.cancel()
        stopPreparingMap()
        phase = .scanning
        progress = ScanProgress(currentPath: url.path)
        elapsed = 0
        result = nil
        selection = nil
        hovered = nil
        zoomRoot = FileTree.rootIndex
        scanTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { try ScanArchive.read(from: url) }.value
                guard let self else { return }
                rootPath = result.tree.rootPath
                finish(result)
                loadedFrom = url
                showsFullDiskAccessHint = false
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func rescan() {
        guard let rootPath else { return }
        scan(path: rootPath)
    }

    /// Back to the welcome screen; drops the current tree and stops any scan in progress.
    func reset() {
        scanner?.cancel()
        scanner = nil
        scanTask?.cancel()
        progressTask?.cancel()
        stopPreparingMap()
        result = nil
        loadedFrom = nil
        selection = nil
        hovered = nil
        zoomRoot = FileTree.rootIndex
        showsFullDiskAccessHint = false
        searchText = ""
        phase = .idle
    }

    func cancelScan() {
        scanner?.cancel()
    }

    private func noteRecentFolder(_ path: String) {
        recentFolders = Array(([path] + recentFolders.filter { $0 != path }).prefix(Self.maxRecentFolders))
    }

    func clearRecentFolders() {
        recentFolders = []
    }

    func scanHomeFolder() {
        scan(path: NSHomeDirectory())
    }

    func scanStartupDisk() {
        scan(path: "/")
    }

    func chooseFolder() {
        Task {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = false
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            panel.treatsFilePackagesAsDirectories = true
            panel.prompt = "Scan"
            panel.message = "Choose a folder to scan"
            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
            if await panel.begin() == .OK, let url = panel.url {
                scan(path: url.path)
            }
        }
    }

    // MARK: Navigation

    func zoom(to node: Int32) {
        guard let tree = displayedTree, tree[node].isDirectory else { return }
        zoomRoot = node
    }

    func zoomOut() {
        guard let tree = displayedTree else { return }
        let parent = tree[zoomRoot].parent
        if parent >= 0 { zoomRoot = parent }
    }

    var canZoomOut: Bool { displayedTree != nil && zoomRoot != FileTree.rootIndex }

    func zoomIntoSelection() {
        guard let selection else { return }
        open(selection)
    }

    /// ⌘[ — select the folder containing the selection (not above the zoom root).
    func selectEnclosingFolder() {
        guard let tree = displayedTree, let selection, selection != zoomRoot else { return }
        let parent = tree[selection].parent
        if parent >= 0 { self.selection = parent }
    }

    /// ⌘] — select the largest item inside the selected folder.
    func selectLargestChild() {
        guard let tree = displayedTree, let selection, tree[selection].isDirectory,
              let largest = tree.orderedChildren(of: selection, by: sizeMode).first, tree[largest].size(sizeMode) > 0
        else { return }
        self.selection = largest
    }

    /// Double-click behaviour: zoom into a directory, or into a file's parent.
    func open(_ node: Int32) {
        guard let tree = displayedTree else { return }
        let target = tree[node].isDirectory ? node : tree[node].parent
        guard target >= 0, target != zoomRoot, tree[target].childCount > 0 else { return }
        zoomRoot = target
        selection = node
    }

    // MARK: Actions on items

    /// Free space and "elsewhere on volume" cells use negative indices and have no file behind them.
    var canRevealSelection: Bool {
        guard let selection else { return false }
        return selection >= 0 && !isEditingPalette
    }

    static let lockedItemReason = "File names, and folders more than \(freeDepth) levels deep, need a license."

    func revealInFinder(_ node: Int32) {
        guard let tree, !isEditingPalette else { return }
        if isLocked(node) {
            requestUnlock(Self.lockedItemReason)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([tree.url(node)])
    }

    /// Real items only: not the free-space cells, and not the scanned folder itself.
    var canTrashSelection: Bool {
        guard let selection else { return false }
        return selection > FileTree.rootIndex && !isEditingPalette
    }

    /// Asks before moving `node` to the Trash, unless the user turned the question off.
    func requestTrash(_ node: Int32) {
        guard node > FileTree.rootIndex, !isEditingPalette else { return }
        if isLocked(node) {
            requestUnlock(Self.lockedItemReason)
            return
        }
        pendingTrash = node
        if skipsTrashConfirmation { confirmTrash() }
    }

    func confirmTrash() {
        guard let tree, !isEditingPalette, let node = pendingTrash else { return }
        pendingTrash = nil
        do {
            try FileManager.default.trashItem(at: tree.url(node), resultingItemURL: nil)
            tree.markDeleted(node)
            treeVersion += 1
            if let selection, tree.isRemoved(selection) { self.selection = nil }
            if let hovered, tree.isRemoved(hovered) { self.hovered = nil }
            scheduleSearch()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Palette editing

    func beginPaletteEditing() {
        guard !isEditingPalette else { return }
        savedNavigation = (zoomRoot, selection)
        searchMatches = nil
        searchPosition = nil
        zoomRoot = FileTree.rootIndex
        selection = nil
        hovered = nil
        // Edit whatever is currently shown: copy it into the working palette first.
        if paletteSelection != .custom {
            customColors = colors(for: paletteSelection)
            paletteSelection = .custom
        }
        isEditingPalette = true
    }

    func endPaletteEditing() {
        guard isEditingPalette else { return }
        isEditingPalette = false
        hovered = nil
        if let savedNavigation, tree != nil {
            zoomRoot = savedNavigation.zoomRoot
            selection = savedNavigation.selection
        } else {
            zoomRoot = FileTree.rootIndex
            selection = nil
        }
        savedNavigation = nil
        scheduleSearch()
    }

    func loadCustomPalette(from selection: PaletteSelection) {
        customColors = colors(for: selection)
        paletteSelection = .custom
    }

    /// Saves the working palette under `name` and selects it.
    func saveUserPalette(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let palette = UserPalette(id: UUID(), name: trimmed.isEmpty ? "Untitled" : trimmed, colors: customColors)
        userPalettes.append(palette)
        paletteSelection = .user(palette.id)
    }

    func deleteUserPalette(_ id: UUID) {
        userPalettes.removeAll { $0.id == id }
        if paletteSelection == .user(id) { paletteSelection = .custom }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
