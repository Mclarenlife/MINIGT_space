import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @StateObject private var store = CollectionStore()
    @AppStorage("minigt.selectedTheme") private var selectedThemeRaw = AppTheme.system.rawValue
    @AppStorage("minigt.completedOnboardingInstallMarker") private var completedOnboardingInstallMarker = ""
    @AppStorage("minigt.keyboardWarmupInstallMarker") private var keyboardWarmupInstallMarker = ""
    @State private var isShowingInitialization = false
    @State private var hasRequestedCatalogLoad = false

    private var selectedTheme: AppTheme {
        AppTheme(rawValue: selectedThemeRaw) ?? .system
    }

    private var needsOnboarding: Bool {
        completedOnboardingInstallMarker != InstallIdentity.current
    }

    private var showsOnboarding: Bool {
        needsOnboarding && isShowingInitialization == false
    }

    var body: some View {
        ZStack {
            if isShowingInitialization {
                InitializationScreen(progress: initializationProgress)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if showsOnboarding {
                OnboardingView {
                    beginInitializationGate()
                }
                .transition(.opacity)
            } else {
                MainTabView()
                    .transition(.opacity)

                if isShowingInitialization || (store.isCatalogLoading && store.models.isEmpty) {
                    InitializationOverlay(progress: initializationProgress)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
        }
            .animation(.easeInOut(duration: 0.22), value: isShowingInitialization)
            .animation(.easeInOut(duration: 0.22), value: needsOnboarding)
            .environmentObject(store)
            .environment(\.themeContext, ThemeContext(theme: selectedTheme))
            .preferredColorScheme(selectedTheme.preferredColorScheme)
            .tint(selectedTheme.palette.accent)
            .task {
                guard hasRequestedCatalogLoad == false else { return }
                hasRequestedCatalogLoad = true
                guard needsOnboarding == false else { return }

                await Task.yield()
                try? await Task.sleep(for: .milliseconds(320))
                store.startLoadingCatalog()
            }
    }

    private var initializationProgress: Double {
        if store.isCatalogLoading {
            return store.catalogLoadingProgress
        }
        return store.models.isEmpty ? 0.08 : 1
    }

    private func beginInitializationGate() {
        guard isShowingInitialization == false else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            isShowingInitialization = true
        }

        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(280))
            store.startLoadingCatalog()
            let shouldWarmKeyboard = keyboardWarmupInstallMarker != InstallIdentity.current
            async let minimumDisplay: Void = Task.sleep(for: .seconds(1))
            async let keyboardWarmup: Void = shouldWarmKeyboard ? KeyboardWarmupCoordinator.warmUp() : ()

            while store.isCatalogLoading {
                try? await Task.sleep(for: .milliseconds(80))
            }

            _ = try? await minimumDisplay
            await keyboardWarmup
            if shouldWarmKeyboard {
                keyboardWarmupInstallMarker = InstallIdentity.current
            }

            completedOnboardingInstallMarker = InstallIdentity.current
            withAnimation(.easeInOut(duration: 0.22)) {
                isShowingInitialization = false
            }
        }
    }
}

private enum InstallIdentity {
    static let current: String = {
        let bundlePath = Bundle.main.bundleURL.path
        let executablePath = Bundle.main.executablePath ?? bundlePath
        let attributes = try? FileManager.default.attributesOfItem(atPath: executablePath)
        let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(bundlePath)|\(Int(modifiedAt))"
    }()
}

private struct OnboardingView: View {
    @Environment(\.themeContext) private var theme
    @State private var selectedIndex = 0

    var completion: () -> Void

    private let features = [
        OnboardingFeature(symbolName: "shippingbox", title: "完整产品库", message: "按编号、品牌、分类和发行状态整理 MINIGT 车型。"),
        OnboardingFeature(symbolName: "sparkles", title: "点亮收藏", message: "记录已入手模型、价格、渠道和拆封状态。"),
        OnboardingFeature(symbolName: "chart.pie", title: "收藏进度", message: "查看总进度、品牌进度和分类进度。")
    ]

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 20)

                TabView(selection: $selectedIndex) {
                    ForEach(features.indices, id: \.self) { index in
                        let feature = features[index]

                        VStack(spacing: 18) {
                            Image(systemName: feature.symbolName)
                                .font(.system(size: 48, weight: .semibold))
                                .foregroundStyle(theme.palette.accent)

                            VStack(spacing: 8) {
                                Text(feature.title)
                                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                                    .foregroundStyle(theme.palette.primaryText)
                                Text(feature.message)
                                    .font(.body)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(theme.palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 28)
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(maxHeight: 360)

                Spacer(minLength: 12)

                Button {
                    if selectedIndex < features.count - 1 {
                        withAnimation(.snappy) {
                            selectedIndex += 1
                        }
                    } else {
                        completion()
                    }
                } label: {
                    Text(buttonTitle)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(theme.palette.accent)
                .padding(.horizontal, 28)

                Spacer(minLength: 28)
            }
        }
    }

    private var buttonTitle: String {
        if selectedIndex < features.count - 1 {
            return "下一步"
        }
        return "进入 MINIGT Space"
    }
}

private struct OnboardingFeature {
    var symbolName: String
    var title: String
    var message: String
}

@MainActor
private enum KeyboardWarmupCoordinator {
    static func warmUp() async {
        await warmUpKeyboard(type: .default, timeout: 4.0)
        try? await Task.sleep(for: .milliseconds(120))
        await warmUpKeyboard(type: .decimalPad, timeout: 2.0)
    }

    private static func warmUpKeyboard(type: UIKeyboardType, timeout: TimeInterval) async {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else {
            try? await Task.sleep(for: .milliseconds(250))
            return
        }

        let textField = UITextField(frame: CGRect(x: -4, y: -4, width: 1, height: 1))
        textField.alpha = 0.01
        textField.keyboardType = type
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        window.addSubview(textField)

        await withCheckedContinuation { continuation in
            var didResume = false
            var observer: NSObjectProtocol?

            let finish: () -> Void = {
                guard didResume == false else { return }
                didResume = true
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                textField.resignFirstResponder()
                textField.removeFromSuperview()
                continuation.resume()
            }

            observer = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidShowNotification,
                object: nil,
                queue: .main
            ) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: finish)
            }

            textField.becomeFirstResponder()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                finish()
            }
        }
    }
}

private struct InitializationOverlay: View {
    @Environment(\.themeContext) private var theme
    var progress: Double

    var body: some View {
        ZStack {
            theme.palette.background.opacity(0.58).ignoresSafeArea()

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(theme.palette.elevated.opacity(0.9), lineWidth: 7)
                        .frame(width: 58, height: 58)

                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .scaleEffect(1.12)
                }
                .tint(theme.palette.accent)

                VStack(spacing: 5) {
                    Text("正在初始化")
                        .font(.headline)
                        .foregroundStyle(theme.palette.primaryText)

                    Text("正在整理产品库，请稍等片刻。")
                        .font(.caption)
                        .foregroundStyle(theme.palette.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(width: 236)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.palette.elevated.opacity(0.8), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 14)
        }
    }
}

private struct InitializationScreen: View {
    @Environment(\.themeContext) private var theme
    var progress: Double

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()

            InitializationOverlay(progress: progress)
        }
    }
}

private struct MainTabView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    Label("库", systemImage: "shippingbox")
                }

            CollectionTabView()
                .tabItem {
                    Label("藏品", systemImage: "sparkles")
                }

            StatsView()
                .tabItem {
                    Label("统计", systemImage: "chart.pie")
                }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
    }
}

// MARK: - Domain

enum ModelStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case released
    case upcoming

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .released: "Released"
        case .upcoming: "Pre-Order"
        }
    }

    nonisolated var symbolName: String {
        switch self {
        case .released: "checkmark.seal.fill"
        case .upcoming: "calendar.badge.clock"
        }
    }
}

enum PurchaseChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case online
    case offline
    case vending
    case exhibition

    var id: String { rawValue }

    var title: String {
        switch self {
        case .online: "线上店铺"
        case .offline: "线下店铺"
        case .vending: "自动贩卖机"
        case .exhibition: "展会"
        }
    }
}

enum SceneCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case garage
    case track
    case street
    case desk
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .garage: "车库"
        case .track: "赛道"
        case .street: "街头"
        case .desk: "桌面"
        case .custom: "自定义"
        }
    }
}

struct MiniGTBrand: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    var name: String
    var logoPath: String?
    var sortOrder: Int
}

struct MiniGTCategory: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    var name: String
    var parentId: Int?
    var level: Int
    var sortOrder: Int
}

struct MiniGTModel: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    var name: String
    var brandId: Int
    var categoryId: Int
    var story: String
    var releaseYear: Int?
    var scale: String
    var modelNumber: String?
    var status: ModelStatus
    var releaseDate: Date?
    var createdAt: Date
    var primaryColorHex: String
    var accentColorHex: String
}

struct ModelImage: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    var modelId: Int
    var imagePath: String
    var isPrimary: Bool
    var sortOrder: Int
}

struct CollectionEntry: Identifiable, Codable, Hashable, Sendable {
    var id: Int { modelId }
    var modelId: Int
    var collectedDate: Date
    var price: Double?
    var channel: PurchaseChannel
    var isUnboxed: Bool
    var hasDefect: Bool
}

struct DisplayScene: Identifiable, Codable, Hashable, Sendable {
    var id: Int
    var name: String
    var imagePath: String
    var category: SceneCategory
    var primaryColorHex: String
    var secondaryColorHex: String
}

struct ScenePlacement: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var sceneId: Int
    var modelId: Int
    var x: Double
    var y: Double
    var rotation: Double
    var scale: Double
}

struct CatalogData: Codable, Sendable {
    var brands: [MiniGTBrand]
    var categories: [MiniGTCategory]
    var models: [MiniGTModel]
}

struct PersistedAppState: Codable, Sendable {
    var catalog: CatalogData
    var collections: [CollectionEntry]
    var scenes: [DisplayScene]
    var placements: [ScenePlacement]
}

private struct InitialStoreState: Sendable {
    var catalog: CatalogData
    var scenes: [DisplayScene]
    var collections: [Int: CollectionEntry]
    var placements: [ScenePlacement]

    nonisolated static func load(storageURL: URL, fallbackCatalog: CatalogData, fallbackScenes: [DisplayScene]) -> InitialStoreState {
        let catalog = ProductCatalogRemoteSource.loadCachedCatalog() ?? ProductCSVLoader.loadBundledCatalog() ?? fallbackCatalog
        guard let snapshot = AppStatePersistence.load(from: storageURL) else {
            return InitialStoreState(
                catalog: catalog,
                scenes: fallbackScenes,
                collections: [:],
                placements: []
            )
        }

        let modelIds = Set(catalog.models.map(\.id))
        let collections = snapshot.collections.reduce(into: [Int: CollectionEntry]()) { result, entry in
            guard modelIds.contains(entry.modelId) else { return }
            result[entry.modelId] = entry
        }
        let placements = snapshot.placements.filter { modelIds.contains($0.modelId) }

        return InitialStoreState(
            catalog: catalog,
            scenes: snapshot.scenes.isEmpty ? fallbackScenes : snapshot.scenes,
            collections: collections,
            placements: placements
        )
    }
}

private enum AppStatePersistence {
    nonisolated static func load(from url: URL) -> PersistedAppState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode(PersistedAppState.self, from: data)
    }

    nonisolated static func save(_ snapshot: PersistedAppState, to url: URL) {
        do {
            let data = try makeEncoder().encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("Failed to persist MINIGT state: \(error)")
        }
    }

    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Store

@MainActor
final class CollectionStore: ObservableObject {
    @Published private(set) var brands: [MiniGTBrand]
    @Published private(set) var categories: [MiniGTCategory]
    @Published private(set) var models: [MiniGTModel]
    @Published private(set) var scenes: [DisplayScene]
    @Published private(set) var isCatalogLoading: Bool
    @Published private(set) var catalogLoadingProgress: Double
    @Published var collections: [Int: CollectionEntry] {
        didSet { persistIfReady() }
    }
    @Published var placements: [ScenePlacement] {
        didSet { persistIfReady() }
    }

    private let storageURL: URL
    private var isReadyToPersist = false
    private var hasStartedCatalogLoading = false
    private var progressTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var catalogRefreshTask: Task<Void, Never>?

    init(storageURL: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        self.storageURL = storageURL ?? documents?.appendingPathComponent("minigt_collection_state.json") ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("minigt_collection_state.json")
        brands = []
        categories = []
        models = []
        scenes = SeedCatalog.scenes
        collections = [:]
        placements = []
        isCatalogLoading = false
        catalogLoadingProgress = 0
    }

    func startLoadingCatalog() {
        guard hasStartedCatalogLoading == false else { return }
        hasStartedCatalogLoading = true
        isCatalogLoading = true
        catalogLoadingProgress = 0.08
        startProgressTicker()
        Task {
            await loadInitialState()
        }
    }

    private func loadInitialState() async {
        let storageURL = storageURL
        let fallbackCatalog = SeedCatalog.catalog
        let fallbackScenes = SeedCatalog.scenes
        catalogLoadingProgress = max(catalogLoadingProgress, 0.18)

        let initialState = await Task.detached(priority: .userInitiated) {
            InitialStoreState.load(storageURL: storageURL, fallbackCatalog: fallbackCatalog, fallbackScenes: fallbackScenes)
        }.value

        catalogLoadingProgress = max(catalogLoadingProgress, 0.88)
        isReadyToPersist = false

        brands = initialState.catalog.brands
        categories = initialState.catalog.categories
        models = initialState.catalog.models
        scenes = initialState.scenes
        collections = initialState.collections
        placements = initialState.placements

        isReadyToPersist = true
        progressTask?.cancel()
        progressTask = nil
        catalogLoadingProgress = 1
        isCatalogLoading = false
        refreshCatalogFromOSSIfNeeded(force: false, delay: 8)
    }

    private func startProgressTicker() {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            while let self, self.isCatalogLoading {
                try? await Task.sleep(for: .milliseconds(80))
                guard Task.isCancelled == false else { return }

                if self.catalogLoadingProgress < 0.72 {
                    self.catalogLoadingProgress = min(0.72, self.catalogLoadingProgress + 0.018)
                } else if self.catalogLoadingProgress < 0.9 {
                    self.catalogLoadingProgress = min(0.9, self.catalogLoadingProgress + 0.006)
                }
            }
        }
    }

    var releasedModels: [MiniGTModel] {
        models.filter { $0.status == .released }
    }

    var upcomingModels: [MiniGTModel] {
        models
            .filter { $0.status == .upcoming }
            .sorted {
                let lhsDate = $0.releaseDate ?? .distantFuture
                let rhsDate = $1.releaseDate ?? .distantFuture
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
                return $0.id < $1.id
            }
    }

    var collectedModels: [MiniGTModel] {
        models.filter { collections[$0.id] != nil }
    }

    var totalSpent: Double {
        collections.values.compactMap(\.price).reduce(0, +)
    }

    var firstCollectedDate: Date? {
        collections.values.map(\.collectedDate).min()
    }

    var overallProgress: Double {
        guard releasedModels.isEmpty == false else { return 0 }
        let releasedCollected = releasedModels.filter { collections[$0.id] != nil }.count
        return Double(releasedCollected) / Double(releasedModels.count)
    }

    func brand(for model: MiniGTModel) -> MiniGTBrand? {
        brands.first { $0.id == model.brandId }
    }

    func category(for model: MiniGTModel) -> MiniGTCategory? {
        categories.first { $0.id == model.categoryId }
    }

    func isCollected(_ model: MiniGTModel) -> Bool {
        collections[model.id] != nil
    }

    func collect(_ entry: CollectionEntry) {
        collections[entry.modelId] = entry
    }

    func removeCollection(modelId: Int) {
        collections.removeValue(forKey: modelId)
        placements.removeAll { $0.modelId == modelId }
    }

    func models(matching query: String, brandId: Int?, categoryId: Int?, includeUpcoming: Bool = true, onlyCollected: Bool = false) -> [MiniGTModel] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let categoryIds = categoryId.map { descendantCategoryIds(from: $0) }

        return models
            .filter { includeUpcoming || $0.status == .released }
            .filter { onlyCollected == false || collections[$0.id] != nil }
            .filter { model in
                guard normalizedQuery.isEmpty == false else { return true }
                let brand = brand(for: model)?.name.lowercased() ?? ""
                let number = model.modelNumber?.lowercased() ?? ""
                return model.name.lowercased().contains(normalizedQuery)
                    || brand.contains(normalizedQuery)
                    || number.contains(normalizedQuery)
            }
            .filter { model in
                guard let brandId else { return true }
                return model.brandId == brandId
            }
            .filter { model in
                guard let categoryIds else { return true }
                return categoryIds.contains(model.categoryId)
            }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status == .released
                }
                return lhs.id < rhs.id
            }
    }

    func progressForBrand(_ brand: MiniGTBrand) -> (owned: Int, total: Int, progress: Double) {
        let brandModels = releasedModels.filter { $0.brandId == brand.id }
        let owned = brandModels.filter { collections[$0.id] != nil }.count
        return (owned, brandModels.count, Self.ratio(owned, brandModels.count))
    }

    func progressForCategory(_ category: MiniGTCategory) -> (owned: Int, total: Int, progress: Double) {
        let ids = descendantCategoryIds(from: category.id)
        let categoryModels = releasedModels.filter { ids.contains($0.categoryId) }
        let owned = categoryModels.filter { collections[$0.id] != nil }.count
        return (owned, categoryModels.count, Self.ratio(owned, categoryModels.count))
    }

    func uncollectedModelsForBrand(_ brand: MiniGTBrand) -> [MiniGTModel] {
        releasedModels.filter { $0.brandId == brand.id && collections[$0.id] == nil }
    }

    func uncollectedModelsForCategory(_ category: MiniGTCategory) -> [MiniGTModel] {
        let ids = descendantCategoryIds(from: category.id)
        return releasedModels.filter { ids.contains($0.categoryId) && collections[$0.id] == nil }
    }

    func descendants(of category: MiniGTCategory) -> [MiniGTCategory] {
        categories
            .filter { $0.parentId == category.id }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func rootCategories() -> [MiniGTCategory] {
        categories
            .filter { $0.parentId == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func addPlacement(modelId: Int, to sceneId: Int) {
        let count = placements.filter { $0.sceneId == sceneId }.count
        let next = ScenePlacement(
            id: UUID(),
            sceneId: sceneId,
            modelId: modelId,
            x: min(0.78, 0.28 + Double(count % 4) * 0.14),
            y: min(0.78, 0.54 + Double(count / 4) * 0.08),
            rotation: 0,
            scale: 1
        )
        placements.append(next)
    }

    func updatePlacement(_ placement: ScenePlacement) {
        guard let index = placements.firstIndex(where: { $0.id == placement.id }) else { return }
        placements[index] = placement
    }

    func removePlacement(_ placement: ScenePlacement) {
        placements.removeAll { $0.id == placement.id }
    }

    func placements(for sceneId: Int) -> [ScenePlacement] {
        placements.filter { $0.sceneId == sceneId }
    }

    func model(id: Int) -> MiniGTModel? {
        models.first { $0.id == id }
    }

    func exportJSON() -> String {
        let snapshot = makeSnapshot()
        let encoder = AppStatePersistence.makeEncoder()
        guard let data = try? encoder.encode(snapshot) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func importCatalog(from data: Data, replaceExisting: Bool) throws {
        let decoder = AppStatePersistence.makeDecoder()

        if let snapshot = try? decoder.decode(PersistedAppState.self, from: data) {
            brands = snapshot.catalog.brands
            categories = snapshot.catalog.categories
            models = snapshot.catalog.models
            scenes = snapshot.scenes
            collections = Dictionary(uniqueKeysWithValues: snapshot.collections.map { ($0.modelId, $0) })
            placements = snapshot.placements
            save()
            return
        }

        let catalog = try decoder.decode(CatalogData.self, from: data)
        if replaceExisting {
            brands = catalog.brands
            categories = catalog.categories
            models = catalog.models
        } else {
            merge(catalog)
        }
        save()
    }

    func resetCollections() {
        collections = [:]
        placements = []
    }

    func refreshCatalogFromOSS() {
        refreshCatalogFromOSSIfNeeded(force: true, delay: 0)
    }

    func resetDemoData() {
        let catalog = ProductCatalogRemoteSource.loadCachedCatalog() ?? Self.loadBundledCatalog()
        isReadyToPersist = false
        applyCatalog(catalog)
        scenes = SeedCatalog.scenes
        collections = [:]
        placements = []
        isReadyToPersist = true
        save()
        refreshCatalogFromOSSIfNeeded(force: true, delay: 0)
    }

    private func refreshCatalogFromOSSIfNeeded(force: Bool, delay: TimeInterval) {
        catalogRefreshTask?.cancel()
        catalogRefreshTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard Task.isCancelled == false else { return }
            }
            let refreshedCatalog = await ProductCatalogRemoteSource.refreshIfNeeded(force: force)
            guard let self, let refreshedCatalog else { return }
            applyRemoteCatalog(refreshedCatalog)
        }
    }

    private func applyRemoteCatalog(_ catalog: CatalogData) {
        isReadyToPersist = false
        applyCatalog(catalog)
        isReadyToPersist = true
        save()
    }

    private func applyCatalog(_ catalog: CatalogData) {
        let modelIds = Set(catalog.models.map(\.id))
        brands = catalog.brands
        categories = catalog.categories
        models = catalog.models
        collections = collections.filter { modelIds.contains($0.key) }
        placements = placements.filter { modelIds.contains($0.modelId) }
    }

    private func descendantCategoryIds(from id: Int) -> Set<Int> {
        var result: Set<Int> = [id]
        var cursor = [id]

        while let current = cursor.popLast() {
            let children = categories.filter { $0.parentId == current }.map(\.id)
            result.formUnion(children)
            cursor.append(contentsOf: children)
        }

        return result
    }

    private func merge(_ catalog: CatalogData) {
        let existingBrandIds = Set(brands.map(\.id))
        brands.append(contentsOf: catalog.brands.filter { existingBrandIds.contains($0.id) == false })
        brands.sort { $0.sortOrder < $1.sortOrder }

        let existingCategoryIds = Set(categories.map(\.id))
        categories.append(contentsOf: catalog.categories.filter { existingCategoryIds.contains($0.id) == false })
        categories.sort { $0.sortOrder < $1.sortOrder }

        let existingModelIds = Set(models.map(\.id))
        models.append(contentsOf: catalog.models.filter { existingModelIds.contains($0.id) == false })
        models.sort { $0.id < $1.id }
    }

    private func persistIfReady() {
        guard isReadyToPersist else { return }
        save()
    }

    private func save() {
        let snapshot = makeSnapshot()
        let storageURL = storageURL

        saveTask?.cancel()
        saveTask = Task.detached(priority: .utility) {
            guard Task.isCancelled == false else { return }
            AppStatePersistence.save(snapshot, to: storageURL)
        }
    }

    private func makeSnapshot() -> PersistedAppState {
        PersistedAppState(
            catalog: CatalogData(brands: brands, categories: categories, models: models),
            collections: collections.values.sorted { $0.modelId < $1.modelId },
            scenes: scenes,
            placements: placements
        )
    }

    private static func loadBundledCatalog() -> CatalogData {
        ProductCSVLoader.loadBundledCatalog() ?? SeedCatalog.catalog
    }

    private static func ratio(_ owned: Int, _ total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(owned) / Double(total)
    }

}

// MARK: - Theme

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case lightMinimal
    case darkMinimal
    case darkRacing
    case garage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .lightMinimal: "极简白卡风"
        case .darkMinimal: "极简黑卡风"
        case .darkRacing: "暗黑赛车风"
        case .garage: "车库工业风"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .lightMinimal: .light
        case .darkMinimal, .darkRacing, .garage: .dark
        }
    }

    var palette: AppPalette {
        switch self {
        case .system:
            AppPalette(
                background: Color(.systemBackground),
                surface: Color(.secondarySystemBackground),
                elevated: Color(.tertiarySystemBackground),
                primaryText: Color(.label),
                secondaryText: Color(.secondaryLabel),
                accent: Color(hex: "#D6A642"),
                success: Color(hex: "#30C86A"),
                warning: Color(hex: "#F39A32"),
                danger: Color(hex: "#FF4D4F")
            )
        case .lightMinimal:
            AppPalette(
                background: Color(hex: "#F6F7F9"),
                surface: .white,
                elevated: Color(hex: "#ECEFF3"),
                primaryText: Color(hex: "#111318"),
                secondaryText: Color(hex: "#667085"),
                accent: Color(hex: "#B8842F"),
                success: Color(hex: "#1F9D55"),
                warning: Color(hex: "#E17A20"),
                danger: Color(hex: "#D92D20")
            )
        case .darkMinimal:
            AppPalette(
                background: Color(hex: "#0F1115"),
                surface: Color(hex: "#181B21"),
                elevated: Color(hex: "#242832"),
                primaryText: Color(hex: "#F4F6F8"),
                secondaryText: Color(hex: "#A4ACB9"),
                accent: Color(hex: "#D6A642"),
                success: Color(hex: "#38D46D"),
                warning: Color(hex: "#F5A524"),
                danger: Color(hex: "#FF6266")
            )
        case .darkRacing:
            AppPalette(
                background: Color(hex: "#090A0C"),
                surface: Color(hex: "#15171C"),
                elevated: Color(hex: "#22262E"),
                primaryText: Color(hex: "#F7F8FA"),
                secondaryText: Color(hex: "#A8B0BC"),
                accent: Color(hex: "#E63B2E"),
                success: Color(hex: "#2FD076"),
                warning: Color(hex: "#F7B955"),
                danger: Color(hex: "#FF4D4F")
            )
        case .garage:
            AppPalette(
                background: Color(hex: "#11100E"),
                surface: Color(hex: "#1D1A16"),
                elevated: Color(hex: "#2A251E"),
                primaryText: Color(hex: "#F2EEE7"),
                secondaryText: Color(hex: "#B5A999"),
                accent: Color(hex: "#D09343"),
                success: Color(hex: "#6AC17B"),
                warning: Color(hex: "#F0A33A"),
                danger: Color(hex: "#EE5D4E")
            )
        }
    }
}

struct AppPalette {
    var background: Color
    var surface: Color
    var elevated: Color
    var primaryText: Color
    var secondaryText: Color
    var accent: Color
    var success: Color
    var warning: Color
    var danger: Color
}

struct ThemeContext {
    var theme: AppTheme
    var palette: AppPalette { theme.palette }
}

private struct ThemeContextKey: EnvironmentKey {
    static let defaultValue = ThemeContext(theme: .system)
}

extension EnvironmentValues {
    var themeContext: ThemeContext {
        get { self[ThemeContextKey.self] }
        set { self[ThemeContextKey.self] = newValue }
    }
}

// MARK: - Library

private enum LibraryLayout: String, CaseIterable {
    case grid
    case list
}

private enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case descending
    case ascending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .descending: "倒序排列"
        case .ascending: "正序排列"
        }
    }

    var symbolName: String {
        switch self {
        case .descending: "arrow.down"
        case .ascending: "arrow.up"
        }
    }

    func sortsBefore(_ lhs: MiniGTModel, _ rhs: MiniGTModel) -> Bool {
        let lhsNumber = numberValue(for: lhs)
        let rhsNumber = numberValue(for: rhs)

        if lhsNumber != rhsNumber {
            return self == .ascending ? lhsNumber < rhsNumber : lhsNumber > rhsNumber
        }

        return self == .ascending ? lhs.id < rhs.id : lhs.id > rhs.id
    }

    private func numberValue(for model: MiniGTModel) -> Int {
        let digits = model.modelNumber?.filter(\.isNumber) ?? ""
        return Int(digits) ?? model.id
    }
}

private struct LibraryView: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.themeContext) private var theme
    @State private var query = ""
    @State private var selectedBrandId: Int?
    @State private var selectedCategoryId: Int?
    @State private var layout: LibraryLayout = .grid
    @State private var sortOrder: LibrarySortOrder = .descending
    @State private var showsFilters = false
    @State private var glowModelId: Int?

    private var filteredModels: [MiniGTModel] {
        store.models(matching: query, brandId: selectedBrandId, categoryId: selectedCategoryId)
            .sorted(by: sortOrder.sortsBefore)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.palette.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        LibraryHeader(
                            total: store.models.count,
                            collected: store.collectedModels.count,
                            progress: store.overallProgress
                        )

                        FilterSummary(
                            brand: store.brands.first { $0.id == selectedBrandId }?.name,
                            category: store.categories.first { $0.id == selectedCategoryId }?.name,
                            clearAction: clearFilters
                        )

                        if layout == .grid {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 164), spacing: 12)], spacing: 12) {
                                ForEach(filteredModels) { model in
                                    NavigationLink {
                                        ModelDetailView(model: model, glowModelId: $glowModelId)
                                    } label: {
                                        ModelCard(model: model, isGlowing: glowModelId == model.id)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(filteredModels) { model in
                                    NavigationLink {
                                        ModelDetailView(model: model, glowModelId: $glowModelId)
                                    } label: {
                                        ModelRow(model: model)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("MINIGT 库")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索车型、品牌、编号")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        UpcomingModelsView()
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("即将发布")

                    Button {
                        withAnimation(.snappy) {
                            layout = layout == .grid ? .list : .grid
                        }
                    } label: {
                        Image(systemName: layout == .grid ? "list.bullet" : "square.grid.2x2")
                    }
                    .accessibilityLabel("切换布局")

                    Button {
                        showsFilters = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("筛选")
                }
            }
            .sheet(isPresented: $showsFilters) {
                FilterSheet(
                    selectedBrandId: $selectedBrandId,
                    selectedCategoryId: $selectedCategoryId,
                    sortOrder: $sortOrder
                )
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func clearFilters() {
        selectedBrandId = nil
        selectedCategoryId = nil
    }
}

private struct LibraryHeader: View {
    @Environment(\.themeContext) private var theme
    var total: Int
    var collected: Int
    var progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("收藏进度")
                        .font(.caption)
                        .foregroundStyle(theme.palette.secondaryText)
                    Text("\(collected) / \(total)")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle(theme.palette.primaryText)
                }

                Spacer()

                ProgressRing(progress: progress, lineWidth: 8)
                    .frame(width: 72, height: 72)
            }

            HStack(spacing: 8) {
                StatusPill(title: "已点亮 \(collected)", color: theme.palette.accent, symbolName: "sparkles")
                StatusPill(title: "待收 \(max(total - collected, 0))", color: theme.palette.secondaryText, symbolName: "circle")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.palette.elevated.opacity(0.75), lineWidth: 1)
        )
    }
}

private struct FilterSummary: View {
    @Environment(\.themeContext) private var theme
    var brand: String?
    var category: String?
    var clearAction: () -> Void

    var body: some View {
        if brand != nil || category != nil {
            HStack(spacing: 8) {
                if let brand {
                    StatusPill(title: brand, color: theme.palette.accent, symbolName: "tag")
                }
                if let category {
                    StatusPill(title: category, color: theme.palette.warning, symbolName: "line.3.horizontal.decrease")
                }
                Spacer()
                Button(action: clearAction) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.palette.secondaryText)
            }
        }
    }
}

private struct FilterSheet: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeContext) private var theme
    @Binding var selectedBrandId: Int?
    @Binding var selectedCategoryId: Int?
    @Binding var sortOrder: LibrarySortOrder

    var body: some View {
        NavigationStack {
            List {
                Section("品牌") {
                    FilterOptionRow(title: "全部品牌", isSelected: selectedBrandId == nil) {
                        selectedBrandId = nil
                    }

                    ForEach(store.brands.sorted { $0.sortOrder < $1.sortOrder }) { brand in
                        FilterOptionRow(title: brand.name, isSelected: selectedBrandId == brand.id) {
                            selectedBrandId = brand.id
                        }
                    }
                }

                Section("分类") {
                    FilterOptionRow(title: "全部分类", isSelected: selectedCategoryId == nil) {
                        selectedCategoryId = nil
                    }

                    ForEach(store.rootCategories()) { root in
                        FilterOptionRow(title: root.name, isSelected: selectedCategoryId == root.id) {
                            selectedCategoryId = root.id
                        }

                        ForEach(store.descendants(of: root)) { child in
                            FilterOptionRow(title: "  \(child.name)", isSelected: selectedCategoryId == child.id) {
                                selectedCategoryId = child.id
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.palette.background)
            .navigationTitle("筛选")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("重置") {
                        selectedBrandId = nil
                        selectedCategoryId = nil
                        sortOrder = .descending
                    }
                }
                ToolbarItem(placement: .principal) {
                    Menu {
                        ForEach(LibrarySortOrder.allCases) { order in
                            Button {
                                sortOrder = order
                            } label: {
                                Label(order.title, systemImage: sortOrder == order ? "checkmark" : order.symbolName)
                            }
                        }
                    } label: {
                        Label(sortOrder.title, systemImage: sortOrder.symbolName)
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("排序")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct FilterOptionRow: View {
    @Environment(\.themeContext) private var theme
    var title: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(theme.palette.primaryText)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.palette.accent)
                }
            }
        }
    }
}

private struct ModelCard: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.themeContext) private var theme
    var model: MiniGTModel
    var isGlowing = false

    private static let artworkHeight: CGFloat = 112
    private static let nameHeight: CGFloat = 62

    private var isCollected: Bool {
        store.isCollected(model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .topTrailing) {
                CarArtworkView(model: model)
                    .frame(height: Self.artworkHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                StatusTag(status: model.status)
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2...3)
                    .foregroundStyle(theme.palette.primaryText)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: Self.nameHeight, maxHeight: Self.nameHeight, alignment: .topLeading)

                Text(store.brand(for: model)?.name ?? "未录入品牌")
                    .font(.subheadline)
                    .foregroundStyle(theme.palette.secondaryText)
                    .lineLimit(1)
            }

            HStack {
                Label(model.modelNumber ?? model.scale, systemImage: "number")
                    .font(.caption)
                    .foregroundStyle(theme.palette.secondaryText)
                    .lineLimit(1)

                Spacer()

                Image(systemName: isCollected ? "sparkles" : "circle")
                    .foregroundStyle(isCollected ? theme.palette.accent : theme.palette.secondaryText.opacity(0.55))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isCollected ? theme.palette.accent.opacity(0.55) : theme.palette.elevated, lineWidth: 1)
        }
        .overlay {
            if isGlowing || isCollected {
                GlowOverlay(isActive: isGlowing)
            }
        }
    }
}

private struct ModelRow: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.themeContext) private var theme
    var model: MiniGTModel

    var body: some View {
        HStack(spacing: 12) {
            CarArtworkView(model: model)
                .frame(width: 96, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(model.name)
                    .font(.headline)
                    .foregroundStyle(theme.palette.primaryText)
                    .lineLimit(2)
                Text("\(store.brand(for: model)?.name ?? "未录入品牌") · \(store.category(for: model)?.name ?? model.scale)")
                    .font(.subheadline)
                    .foregroundStyle(theme.palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                StatusTag(status: model.status)
                Image(systemName: store.isCollected(model) ? "sparkles" : "circle")
                    .foregroundStyle(store.isCollected(model) ? theme.palette.accent : theme.palette.secondaryText.opacity(0.55))
            }
        }
        .padding(10)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ModelDetailView: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeContext) private var theme
    var model: MiniGTModel
    @Binding var glowModelId: Int?
    @State private var showsCollectionForm = false
    @State private var showsRemoveConfirmation = false
    @State private var localGlow = false

    private var collectionEntry: CollectionEntry? {
        store.collections[model.id]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    CarArtworkView(model: model)
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if localGlow {
                        GlowOverlay(isActive: true)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        StatusTag(status: model.status)
                        Spacer()
                        if store.isCollected(model) {
                            StatusPill(title: "已点亮", color: theme.palette.accent, symbolName: "sparkles")
                        }
                    }

                    Text(model.name)
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .foregroundStyle(theme.palette.primaryText)

                    Text(store.brand(for: model)?.name ?? "未录入品牌")
                        .font(.headline)
                        .foregroundStyle(theme.palette.secondaryText)
                }

                DetailInfoGrid(model: model, collection: collectionEntry)

                VStack(alignment: .leading, spacing: 8) {
                    Text("故事")
                        .font(.headline)
                        .foregroundStyle(theme.palette.primaryText)
                    Text(model.story)
                        .font(.body)
                        .foregroundStyle(theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let collectionEntry {
                    CollectionReceipt(entry: collectionEntry)
                }
            }
            .padding()
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("模型详情")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    if store.isCollected(model) {
                        showsRemoveConfirmation = true
                    } else {
                        showsCollectionForm = true
                    }
                } label: {
                    Label(store.isCollected(model) ? "取消点亮" : "点亮收藏", systemImage: store.isCollected(model) ? "xmark.circle" : "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(store.isCollected(model) ? theme.palette.danger : theme.palette.accent)
            }
            .padding()
            .background(.regularMaterial)
        }
        .sheet(isPresented: $showsCollectionForm) {
            CollectionFormView(model: model) {
                glowModelId = model.id
                localGlow = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    glowModelId = nil
                    localGlow = false
                }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("取消点亮", isPresented: $showsRemoveConfirmation) {
            Button("删除收藏记录", role: .destructive) {
                store.removeCollection(modelId: model.id)
            }
        } message: {
            Text("会同时移除该模型在展示场景中的摆放。")
        }
    }
}

private struct DetailInfoGrid: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.themeContext) private var theme
    var model: MiniGTModel
    var collection: CollectionEntry?

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            DetailInfoTile(title: "比例", value: model.scale, symbolName: "ruler")
            DetailInfoTile(title: "编号", value: model.modelNumber ?? "未录入", symbolName: "number")
            DetailInfoTile(title: "年份", value: model.releaseYear.map(String.init) ?? "待定", symbolName: "calendar")
            DetailInfoTile(title: "分类", value: store.category(for: model)?.name ?? "未分类", symbolName: "square.grid.2x2")
            if let collection {
                DetailInfoTile(title: "入手价", value: collection.price.map { Currency.format($0) } ?? "未录入", symbolName: "yensign.circle")
                DetailInfoTile(title: "渠道", value: collection.channel.title, symbolName: "bag")
            }
        }
        .foregroundStyle(theme.palette.primaryText)
    }
}

private struct DetailInfoTile: View {
    @Environment(\.themeContext) private var theme
    var title: String
    var value: String
    var symbolName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(theme.palette.accent)
            Text(title)
                .font(.caption)
                .foregroundStyle(theme.palette.secondaryText)
            Text(value)
                .font(.headline)
                .foregroundStyle(theme.palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CollectionReceipt: View {
    @Environment(\.themeContext) private var theme
    var entry: CollectionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("收藏记录")
                .font(.headline)
                .foregroundStyle(theme.palette.primaryText)

            HStack {
                ReceiptLine(title: "日期", value: entry.collectedDate.formatted(date: .abbreviated, time: .omitted))
                ReceiptLine(title: "状态", value: entry.isUnboxed ? "已拆封" : "未拆封")
                ReceiptLine(title: "瑕疵", value: entry.hasDefect ? "有瑕疵" : "无瑕疵")
            }
        }
        .padding(14)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ReceiptLine: View {
    @Environment(\.themeContext) private var theme
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(theme.palette.secondaryText)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CollectionFormView: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeContext) private var theme
    var model: MiniGTModel
    var completion: () -> Void

    @State private var collectedDate = Date()
    @State private var priceText = ""
    @State private var channel: PurchaseChannel = .online
    @State private var isUnboxed = true
    @State private var hasDefect = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("收藏日期", selection: $collectedDate, displayedComponents: .date)

                    TextField("收藏价格（可选）", text: $priceText)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    Picker("购入渠道", selection: $channel) {
                        ForEach(PurchaseChannel.allCases) { channel in
                            Text(channel.title).tag(channel)
                        }
                    }
                }

                Section {
                    Picker("拆封状态", selection: $isUnboxed) {
                        Text("已拆封").tag(true)
                        Text("未拆封").tag(false)
                    }
                    .pickerStyle(.segmented)

                    Picker("瑕疵情况", selection: $hasDefect) {
                        Text("无瑕疵").tag(false)
                        Text("有瑕疵").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.palette.background)
            .navigationTitle("点亮收藏")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确认点亮") {
                        let price = Double(priceText.replacingOccurrences(of: ",", with: "."))
                        store.collect(CollectionEntry(
                            modelId: model.id,
                            collectedDate: collectedDate,
                            price: price,
                            channel: channel,
                            isUnboxed: isUnboxed,
                            hasDefect: hasDefect
                        ))
                        dismiss()
                        completion()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct UpcomingModelsView: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.themeContext) private var theme

    var body: some View {
        List(store.upcomingModels) { model in
            NavigationLink {
                ModelDetailView(model: model, glowModelId: .constant(nil))
            } label: {
                HStack(spacing: 12) {
                    CarArtworkView(model: model)
                        .frame(width: 92, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.name)
                            .font(.headline)
                        Text(model.releaseDate?.formatted(date: .abbreviated, time: .omitted) ?? "发布日期待定")
                            .font(.subheadline)
                            .foregroundStyle(theme.palette.secondaryText)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.palette.background)
        .navigationTitle("即将发布")
    }
}

// MARK: - Collection Tab

private enum CollectionMode: String, CaseIterable, Identifiable {
    case cards
    case scene

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cards: "卡片"
        case .scene: "展示"
        }
    }
}

private struct CollectionTabView: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.themeContext) private var theme
    @State private var mode: CollectionMode = .cards
    @State private var query = ""

    private var models: [MiniGTModel] {
        store.models(matching: query, brandId: nil, categoryId: nil, onlyCollected: true)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.palette.background.ignoresSafeArea()

                VStack(spacing: 14) {
                    Picker("藏品模式", selection: $mode) {
                        ForEach(CollectionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    if mode == .cards {
                        collectionGrid
                    } else {
                        SceneEditorView()
                    }
                }
            }
            .navigationTitle("我的藏品")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: mode == .cards ? "搜索已收藏模型" : "搜索")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
        }
    }

    private var collectionGrid: some View {
        ScrollView {
            if models.isEmpty {
                EmptyStateView(
                    symbolName: "sparkles",
                    title: "还没有点亮的模型",
                    message: "从库里进入模型详情，点亮后会出现在这里。"
                )
                .padding(.top, 56)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 164), spacing: 12)], spacing: 12) {
                    ForEach(models) { model in
                        NavigationLink {
                            ModelDetailView(model: model, glowModelId: .constant(nil))
                        } label: {
                            ModelCard(model: model)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
    }
}

private struct SceneEditorView: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.themeContext) private var theme
    @State private var selectedSceneId: Int = SeedCatalog.scenes.first?.id ?? 1
    @State private var selectedPlacementId: UUID?

    private var selectedScene: DisplayScene {
        store.scenes.first { $0.id == selectedSceneId } ?? store.scenes[0]
    }

    private var selectedPlacement: ScenePlacement? {
        store.placements.first { $0.id == selectedPlacementId }
    }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.scenes) { scene in
                        Button {
                            selectedSceneId = scene.id
                            selectedPlacementId = nil
                        } label: {
                            Label(scene.name, systemImage: scene.category == .track ? "flag.checkered" : "rectangle.on.rectangle")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(
                                    selectedSceneId == scene.id ? theme.palette.accent.opacity(0.22) : theme.palette.surface,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }

            GeometryReader { proxy in
                ZStack {
                    SceneBackground(scene: selectedScene)

                    ForEach(store.placements(for: selectedScene.id)) { placement in
                        if let model = store.model(id: placement.modelId) {
                            PlacementView(
                                placement: placement,
                                model: model,
                                canvasSize: proxy.size,
                                isSelected: selectedPlacementId == placement.id,
                                onSelect: { selectedPlacementId = placement.id },
                                onUpdate: store.updatePlacement
                            )
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.palette.elevated, lineWidth: 1)
                )
                .padding(.horizontal)
            }
            .frame(minHeight: 280)

            if let selectedPlacement {
                PlacementControls(placement: selectedPlacement)
                    .padding(.horizontal)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("选择模型")
                        .font(.headline)
                        .foregroundStyle(theme.palette.primaryText)
                    Spacer()
                    if let selectedPlacement {
                        Button(role: .destructive) {
                            store.removePlacement(selectedPlacement)
                            selectedPlacementId = nil
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.collectedModels) { model in
                            Button {
                                store.addPlacement(modelId: model.id, to: selectedScene.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    CarArtworkView(model: model)
                                        .frame(width: 124, height: 74)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    Text(model.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(theme.palette.primaryText)
                                        .lineLimit(1)
                                }
                                .padding(8)
                                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }
        }
        .overlay {
            if store.collectedModels.isEmpty {
                EmptyStateView(
                    symbolName: "sparkles",
                    title: "先点亮一台车",
                    message: "收藏后就能在场景里摆放和调整。"
                )
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct SceneBackground: View {
    var scene: DisplayScene

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: scene.primaryColorHex), Color(hex: scene.secondaryColorHex)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack {
                Spacer()
                Rectangle()
                    .fill(.black.opacity(0.18))
                    .frame(height: 76)
            }

            ForEach(0..<8) { index in
                Rectangle()
                    .fill(.white.opacity(index.isMultiple(of: 2) ? 0.16 : 0.06))
                    .frame(width: 1)
                    .rotationEffect(.degrees(-18))
                    .offset(x: CGFloat(index - 4) * 58)
            }

            VStack(alignment: .leading) {
                Text(scene.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(scene.category.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

private struct PlacementView: View {
    @Environment(\.themeContext) private var theme
    var placement: ScenePlacement
    var model: MiniGTModel
    var canvasSize: CGSize
    var isSelected: Bool
    var onSelect: () -> Void
    var onUpdate: (ScenePlacement) -> Void

    var body: some View {
        CarTokenView(model: model)
            .frame(width: 106 * placement.scale, height: 58 * placement.scale)
            .rotationEffect(.degrees(placement.rotation))
            .position(x: canvasSize.width * placement.x, y: canvasSize.height * placement.y)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.palette.accent, lineWidth: 2)
                        .frame(width: 114 * placement.scale, height: 66 * placement.scale)
                        .position(x: canvasSize.width * placement.x, y: canvasSize.height * placement.y)
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        onSelect()
                        var updated = placement
                        updated.x = clamp(Double(value.location.x / max(canvasSize.width, 1)), min: 0.08, max: 0.92)
                        updated.y = clamp(Double(value.location.y / max(canvasSize.height, 1)), min: 0.12, max: 0.9)
                        onUpdate(updated)
                    }
            )
            .onTapGesture(perform: onSelect)
    }
}

private struct PlacementControls: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.themeContext) private var theme
    var placement: ScenePlacement

    @State private var rotation: Double = 0
    @State private var scale: Double = 1

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "rotate.right")
                    .foregroundStyle(theme.palette.accent)
                Slider(value: $rotation, in: -30...30, step: 1) {
                    Text("旋转")
                }
            }
            HStack {
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(theme.palette.accent)
                Slider(value: $scale, in: 0.7...1.35, step: 0.05) {
                    Text("缩放")
                }
            }
        }
        .padding(12)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            rotation = placement.rotation
            scale = placement.scale
        }
        .onChange(of: placement.id) { _, _ in
            rotation = placement.rotation
            scale = placement.scale
        }
        .onChange(of: rotation) { _, newValue in
            update(rotation: newValue, scale: scale)
        }
        .onChange(of: scale) { _, newValue in
            update(rotation: rotation, scale: newValue)
        }
    }

    private func update(rotation: Double, scale: Double) {
        var updated = placement
        updated.rotation = rotation
        updated.scale = scale
        store.updatePlacement(updated)
    }
}

// MARK: - Stats

private enum StatsProgressKind {
    case overall
    case brand
    case category
}

private struct StatsProgressSummary {
    var title: String
    var detail: String
    var progress: Double
}

private struct StatsView: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.themeContext) private var theme
    @State private var progressKind: StatsProgressKind = .overall
    @State private var selectedProgressBrandId: Int?
    @State private var selectedProgressCategoryId: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedProgress.title)
                                    .font(.headline)
                                    .foregroundStyle(theme.palette.primaryText)
                                Text(selectedProgress.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(theme.palette.secondaryText)
                            }

                            Spacer()

                            Menu {
                                Button {
                                    progressKind = .overall
                                } label: {
                                    Label("总进度", systemImage: progressKind == .overall ? "checkmark" : "chart.pie")
                                }

                                Section("品牌进度") {
                                    ForEach(store.brands.sorted { $0.sortOrder < $1.sortOrder }) { brand in
                                        Button {
                                            progressKind = .brand
                                            selectedProgressBrandId = brand.id
                                        } label: {
                                            Label(brand.name, systemImage: isSelectedProgressBrand(brand) ? "checkmark" : "tag")
                                        }
                                    }
                                }

                                Section("分类进度") {
                                    ForEach(categoryDisplayRows) { row in
                                        Button {
                                            progressKind = .category
                                            selectedProgressCategoryId = row.category.id
                                        } label: {
                                            Label(categoryMenuTitle(for: row), systemImage: isSelectedProgressCategory(row.category) ? "checkmark" : "square.grid.2x2")
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.headline)
                                    .foregroundStyle(theme.palette.accent)
                                    .frame(width: 36, height: 36)
                                    .background(theme.palette.surface, in: Circle())
                            }
                            .accessibilityLabel("选择进度")
                        }

                        ProgressRing(progress: selectedProgress.progress, lineWidth: 14)
                            .frame(width: 148, height: 148)

                        Text("\(Int((selectedProgress.progress * 100).rounded()))%")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .foregroundStyle(theme.palette.primaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    HStack(spacing: 12) {
                        StatTile(title: "总投入", value: Currency.format(store.totalSpent), symbolName: "yensign.circle")
                        StatTile(title: "入坑时间", value: entryDurationText, symbolName: "clock")
                    }

                    ProgressSection(title: "品牌进度") {
                        ForEach(store.brands.sorted { $0.sortOrder < $1.sortOrder }) { brand in
                            let progress = store.progressForBrand(brand)
                            NavigationLink {
                                ModelSubsetView(title: "\(brand.name) 未收藏", models: store.uncollectedModelsForBrand(brand))
                            } label: {
                                ProgressBarRow(title: brand.name, owned: progress.owned, total: progress.total, progress: progress.progress)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    ProgressSection(title: "分类进度") {
                        ForEach(categoryDisplayRows) { row in
                            let progress = store.progressForCategory(row.category)
                            NavigationLink {
                                ModelSubsetView(title: "\(row.category.name) 未收藏", models: store.uncollectedModelsForCategory(row.category))
                            } label: {
                                ProgressBarRow(title: row.category.name, owned: progress.owned, total: progress.total, progress: progress.progress)
                                    .padding(.leading, row.indent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .background(theme.palette.background.ignoresSafeArea())
            .navigationTitle("统计")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var selectedProgress: StatsProgressSummary {
        switch progressKind {
        case .overall:
            return overallProgressSummary
        case .brand:
            guard let brand = selectedProgressBrand else { return overallProgressSummary }
            let progress = store.progressForBrand(brand)
            return StatsProgressSummary(
                title: "\(brand.name) 进度",
                detail: "已点亮 \(progress.owned) 台，已出货 \(progress.total) 台",
                progress: progress.progress
            )
        case .category:
            guard let category = selectedProgressCategory else { return overallProgressSummary }
            let progress = store.progressForCategory(category)
            return StatsProgressSummary(
                title: "\(category.name) 进度",
                detail: "已点亮 \(progress.owned) 台，已出货 \(progress.total) 台",
                progress: progress.progress
            )
        }
    }

    private var overallProgressSummary: StatsProgressSummary {
        let releasedCollected = store.releasedModels.filter { store.isCollected($0) }.count
        return StatsProgressSummary(
            title: "总进度",
            detail: "已点亮 \(releasedCollected) 台，已出货 \(store.releasedModels.count) 台",
            progress: store.overallProgress
        )
    }

    private var selectedProgressBrand: MiniGTBrand? {
        let id = selectedProgressBrandId ?? store.brands.sorted { $0.sortOrder < $1.sortOrder }.first?.id
        return store.brands.first { $0.id == id }
    }

    private var selectedProgressCategory: MiniGTCategory? {
        let id = selectedProgressCategoryId ?? categoryDisplayRows.first?.category.id
        return store.categories.first { $0.id == id }
    }

    private func isSelectedProgressBrand(_ brand: MiniGTBrand) -> Bool {
        progressKind == .brand && selectedProgressBrand?.id == brand.id
    }

    private func isSelectedProgressCategory(_ category: MiniGTCategory) -> Bool {
        progressKind == .category && selectedProgressCategory?.id == category.id
    }

    private func categoryMenuTitle(for row: CategoryDisplayRow) -> String {
        String(repeating: "  ", count: Int(row.indent / 16)) + row.category.name
    }

    private var categoryDisplayRows: [CategoryDisplayRow] {
        var rows: [CategoryDisplayRow] = []
        for category in store.rootCategories() {
            appendCategory(category, indent: 0, rows: &rows)
        }
        return rows
    }

    private func appendCategory(_ category: MiniGTCategory, indent: CGFloat, rows: inout [CategoryDisplayRow]) {
        rows.append(CategoryDisplayRow(category: category, indent: indent))
        for child in store.descendants(of: category) {
            appendCategory(child, indent: indent + 16, rows: &rows)
        }
    }

    private var entryDurationText: String {
        guard let first = store.firstCollectedDate else { return "未开始" }
        let components = Calendar.current.dateComponents([.year, .month], from: first, to: Date())
        let years = components.year ?? 0
        let months = components.month ?? 0
        if years == 0 && months == 0 { return "本月" }
        if years == 0 { return "\(months) 个月" }
        return "\(years) 年 \(months) 个月"
    }
}

private struct CategoryDisplayRow: Identifiable {
    var category: MiniGTCategory
    var indent: CGFloat

    var id: Int { category.id }
}

private struct StatTile: View {
    @Environment(\.themeContext) private var theme
    var title: String
    var value: String
    var symbolName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(theme.palette.accent)
            Text(title)
                .font(.caption)
                .foregroundStyle(theme.palette.secondaryText)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(theme.palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ProgressSection<Content: View>: View {
    @Environment(\.themeContext) private var theme
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.palette.primaryText)

            VStack(spacing: 10) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ProgressBarRow: View {
    @Environment(\.themeContext) private var theme
    var title: String
    var owned: Int
    var total: Int
    var progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.palette.primaryText)
                Spacer()
                Text("\(owned)/\(total)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.palette.secondaryText)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.palette.elevated)
                    Capsule()
                        .fill(theme.palette.accent)
                        .frame(width: max(6, proxy.size.width * progress))
                }
            }
            .frame(height: 7)
        }
    }
}

private struct ModelSubsetView: View {
    @Environment(\.themeContext) private var theme
    var title: String
    var models: [MiniGTModel]

    var body: some View {
        List(models) { model in
            NavigationLink {
                ModelDetailView(model: model, glowModelId: .constant(nil))
            } label: {
                ModelRow(model: model)
            }
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .background(theme.palette.background)
        .navigationTitle(title)
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @EnvironmentObject private var store: CollectionStore
    @Environment(\.themeContext) private var theme
    @AppStorage("minigt.selectedTheme") private var selectedThemeRaw = AppTheme.system.rawValue
    @State private var showsExport = false
    @State private var showsImporter = false
    @State private var showsHelp = false
    @State private var showsClearConfirmation = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("主题配色") {
                    Picker("主题", selection: $selectedThemeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                }

                Section("数据管理") {
                    Button {
                        showsExport = true
                    } label: {
                        Label("导出收藏数据", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        showsImporter = true
                    } label: {
                        Label("导入模型数据", systemImage: "tray.and.arrow.down")
                    }

                    Button {
                        store.refreshCatalogFromOSS()
                    } label: {
                        Label("检查产品表更新", systemImage: "arrow.counterclockwise")
                    }

                    Button(role: .destructive) {
                        showsClearConfirmation = true
                    } label: {
                        Label("清空所有收藏记录", systemImage: "trash")
                    }
                }

                Section("帮助") {
                    Button {
                        showsHelp = true
                    } label: {
                        Label("问题反馈", systemImage: "questionmark.circle")
                    }
                }

                Section("关于") {
                    LabeledContent("App 版本", value: "1.0")
                    LabeledContent("模型数据来源", value: "本地手动维护")
                    LabeledContent("数据存储", value: "沙盒 JSON")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.palette.background)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsExport) {
                ExportSheet(json: store.exportJSON())
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showsHelp) {
                HelpSheet()
                    .presentationDetents([.height(260)])
            }
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if hasAccess {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    let data = try Data(contentsOf: url)
                    try store.importCatalog(from: data, replaceExisting: false)
                } catch {
                    importError = error.localizedDescription
                }
            }
            .alert("导入失败", isPresented: Binding(
                get: { importError != nil },
                set: { if $0 == false { importError = nil } }
            )) {
                Button("好", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .confirmationDialog("清空所有收藏记录", isPresented: $showsClearConfirmation) {
                Button("确认清空", role: .destructive) {
                    store.resetCollections()
                }
            } message: {
                Text("模型库会保留，只删除点亮、价格、渠道和场景摆放记录。")
            }
        }
    }
}

private struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeContext) private var theme
    var json: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(json)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.palette.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding()
            }
            .background(theme.palette.background)
            .navigationTitle("导出 JSON")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: json) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

private struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeContext) private var theme

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 44))
                    .foregroundStyle(theme.palette.accent)
                Text("feedback@minigt-space.local")
                    .font(.headline)
                    .textSelection(.enabled)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.palette.surface)
                    .frame(width: 116, height: 116)
                    .overlay {
                        Image(systemName: "qrcode")
                            .font(.system(size: 72))
                            .foregroundStyle(theme.palette.secondaryText)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.palette.background)
            .navigationTitle("问题反馈")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Shared UI

private enum OSSImageProvider {
    private nonisolated static let baseURLString = "https://mini-garage.oss-cn-shenzhen.aliyuncs.com/"
    private nonisolated static let objectPrefix = "MINIGT_imge/"
    private nonisolated static let fileExtensions = ["jpg"]

    nonisolated static func imageURLs(for model: MiniGTModel) -> [URL] {
        guard let modelNumber = model.modelNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              modelNumber.isEmpty == false else {
            return []
        }

        let keys = fileExtensions.map { "\(objectPrefix)\(modelNumber).\($0)" } + ["\(objectPrefix)\(modelNumber)"]

        return unique(keys).compactMap(makeURL)
    }

    private nonisolated static func makeURL(for objectKey: String) -> URL? {
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove(charactersIn: "/?#%")

        guard let encodedKey = objectKey.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            return nil
        }

        return URL(string: baseURLString + encodedKey)
    }

    private nonisolated static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }
}

private actor ProductImageCache {
    static let shared = ProductImageCache()

    private let memoryCache = NSCache<NSURL, UIImage>()
    private let cacheDirectory: URL
    private var missingURLs: Set<URL> = []

    private init() {
        memoryCache.countLimit = 350
        memoryCache.totalCostLimit = 120 * 1024 * 1024

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        cacheDirectory = (caches ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("MINIGTProductImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func image(for url: URL) -> UIImage? {
        let key = url as NSURL
        if let image = memoryCache.object(forKey: key) {
            return image
        }

        let fileURL = cacheFileURL(for: url)
        guard let data = try? Data(contentsOf: fileURL),
              let image = decodedImage(from: data) else {
            return nil
        }

        memoryCache.setObject(image, forKey: key, cost: data.count)
        return image
    }

    func store(_ data: Data, for url: URL) -> UIImage? {
        guard let image = decodedImage(from: data) else { return nil }
        memoryCache.setObject(image, forKey: url as NSURL, cost: data.count)
        try? data.write(to: cacheFileURL(for: url), options: [.atomic])
        return image
    }

    func isKnownMissing(_ url: URL) -> Bool {
        missingURLs.contains(url)
    }

    func markMissing(_ url: URL) {
        missingURLs.insert(url)
    }

    private func cacheFileURL(for url: URL) -> URL {
        let fileName = url.absoluteString.map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        return cacheDirectory.appendingPathComponent(String(fileName))
    }

    private func decodedImage(from data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

@MainActor
private final class ProductImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false

    private var currentURLs: [URL] = []
    private var task: Task<Void, Never>?

    func load(urls: [URL]) {
        guard currentURLs != urls else { return }
        currentURLs = urls
        task?.cancel()
        image = nil
        isLoading = false

        guard urls.isEmpty == false else { return }

        isLoading = true
        task = Task { [weak self, urls] in
            guard let self else { return }

            for url in urls {
                if Task.isCancelled { return }

                if let cachedImage = await ProductImageCache.shared.image(for: url) {
                    guard currentURLs == urls else { return }
                    image = cachedImage
                    isLoading = false
                    return
                }

                guard await ProductImageCache.shared.isKnownMissing(url) == false else { continue }

                do {
                    let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200..<300).contains(httpResponse.statusCode),
                          let downloadedImage = await ProductImageCache.shared.store(data, for: url) else {
                        await ProductImageCache.shared.markMissing(url)
                        continue
                    }

                    guard currentURLs == urls else { return }
                    image = downloadedImage
                    isLoading = false
                    return
                } catch {
                    await ProductImageCache.shared.markMissing(url)
                }
            }

            guard currentURLs == urls else { return }
            isLoading = false
        }
    }

    deinit {
        task?.cancel()
    }
}

private struct RemoteProductImageView<Placeholder: View>: View {
    var model: MiniGTModel
    private let placeholder: () -> Placeholder

    @StateObject private var loader = ProductImageLoader()
    @State private var showsPlaceholder = false

    init(model: MiniGTModel, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.model = model
        self.placeholder = placeholder
    }

    private var urls: [URL] {
        OSSImageProvider.imageURLs(for: model)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = loader.image {
                    let imageSize = remoteImageSize(in: proxy.size, image: image)

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: imageSize.width, height: imageSize.height)
                        .offset(y: -imageLift(in: proxy.size))
                        .transition(.opacity)
                } else {
                    if showsPlaceholder {
                        placeholder()
                            .transition(.opacity)
                    }

                    if loader.isLoading {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.72)
                            .offset(y: -min(proxy.size.height * 0.36, 42))
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(.easeInOut(duration: 0.18), value: loader.image)
        .animation(.easeInOut(duration: 0.18), value: showsPlaceholder)
        .task(id: model.id) {
            showsPlaceholder = urls.isEmpty
            loader.load(urls: urls)
            guard urls.isEmpty == false else { return }

            try? await Task.sleep(for: .seconds(1))
            guard Task.isCancelled == false, loader.image == nil else { return }
            showsPlaceholder = true
        }
    }

    private func remoteImageSize(in container: CGSize, image: UIImage) -> CGSize {
        let rawAspect = image.size.width / max(image.size.height, 1)
        let targetAspect = min(max(rawAspect, 0.8), 2.4)
        let maxWidth = max(container.width, 0)
        let maxHeight = max(container.height, 0)

        var width = maxWidth
        var height = width / targetAspect

        if height > maxHeight {
            height = maxHeight
            width = height * targetAspect
        }

        return CGSize(width: width, height: height)
    }

    private func imageLift(in container: CGSize) -> CGFloat {
        min(max(container.height * 0.11, 8), 22)
    }
}

private struct CarArtworkView: View {
    var model: MiniGTModel

    var body: some View {
        ZStack {
            RemoteProductImageView(model: model) {
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: model.primaryColorHex), Color(hex: model.accentColorHex)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Circle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 140)
                        .blur(radius: 18)
                        .offset(x: 46, y: -32)

                    CarTokenView(model: model)
                        .frame(width: 130, height: 78)
                        .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 8)
                        .offset(y: 14)
                }
            }

            VStack {
                HStack {
                    Text(model.scale)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.2), in: Capsule())
                    Spacer()
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(10)
        }
    }
}

private struct CarTokenView: View {
    var model: MiniGTModel

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let bodyColor = Color(hex: model.primaryColorHex)
            let accent = Color(hex: model.accentColorHex)

            ZStack {
                RoundedRectangle(cornerRadius: height * 0.18, style: .continuous)
                    .fill(.black.opacity(0.2))
                    .frame(width: width * 0.84, height: height * 0.28)
                    .offset(y: height * 0.25)

                Path { path in
                    path.move(to: CGPoint(x: width * 0.1, y: height * 0.58))
                    path.addQuadCurve(to: CGPoint(x: width * 0.26, y: height * 0.38), control: CGPoint(x: width * 0.14, y: height * 0.44))
                    path.addLine(to: CGPoint(x: width * 0.42, y: height * 0.24))
                    path.addQuadCurve(to: CGPoint(x: width * 0.68, y: height * 0.26), control: CGPoint(x: width * 0.52, y: height * 0.14))
                    path.addLine(to: CGPoint(x: width * 0.84, y: height * 0.42))
                    path.addQuadCurve(to: CGPoint(x: width * 0.94, y: height * 0.58), control: CGPoint(x: width * 0.92, y: height * 0.43))
                    path.addLine(to: CGPoint(x: width * 0.9, y: height * 0.72))
                    path.addLine(to: CGPoint(x: width * 0.12, y: height * 0.72))
                    path.closeSubpath()
                }
                .fill(bodyColor)

                Path { path in
                    path.move(to: CGPoint(x: width * 0.33, y: height * 0.39))
                    path.addLine(to: CGPoint(x: width * 0.45, y: height * 0.28))
                    path.addQuadCurve(to: CGPoint(x: width * 0.64, y: height * 0.3), control: CGPoint(x: width * 0.55, y: height * 0.22))
                    path.addLine(to: CGPoint(x: width * 0.76, y: height * 0.43))
                    path.addLine(to: CGPoint(x: width * 0.33, y: height * 0.43))
                    path.closeSubpath()
                }
                .fill(.white.opacity(0.78))

                Rectangle()
                    .fill(accent)
                    .frame(width: width * 0.52, height: max(3, height * 0.08))
                    .offset(x: width * 0.02, y: height * 0.12)

                wheel(at: CGPoint(x: width * 0.28, y: height * 0.7), radius: height * 0.14)
                wheel(at: CGPoint(x: width * 0.75, y: height * 0.7), radius: height * 0.14)
            }
        }
        .aspectRatio(1.8, contentMode: .fit)
    }

    private func wheel(at point: CGPoint, radius: CGFloat) -> some View {
        ZStack {
            Circle().fill(.black)
            Circle().fill(.white.opacity(0.25)).frame(width: radius, height: radius)
        }
        .frame(width: radius * 2, height: radius * 2)
        .position(point)
    }
}

private struct StatusTag: View {
    @Environment(\.themeContext) private var theme
    var status: ModelStatus

    var body: some View {
        Label(status.title, systemImage: status.symbolName)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(status == .released ? theme.palette.success : theme.palette.warning, in: Capsule())
    }
}

private struct StatusPill: View {
    var title: String
    var color: Color
    var symbolName: String

    var body: some View {
        Label(title, systemImage: symbolName)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct GlowOverlay: View {
    var isActive: Bool
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(hex: "#FFD166").opacity(animate ? 0 : 0.72), lineWidth: 2)
                    .scaleEffect(animate ? 1.18 + CGFloat(index) * 0.12 : 0.92)
                    .animation(
                        .easeOut(duration: 1.2).delay(Double(index) * 0.12),
                        value: animate
                    )
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard isActive else { return }
            animate = true
        }
    }
}

private struct ProgressRing: View {
    @Environment(\.themeContext) private var theme
    var progress: Double
    var lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.palette.elevated, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(theme.palette.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text("\(Int((progress * 100).rounded()))%")
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.palette.primaryText)
        }
    }
}

private struct EmptyStateView: View {
    @Environment(\.themeContext) private var theme
    var symbolName: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 42))
                .foregroundStyle(theme.palette.accent)
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.palette.primaryText)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

// MARK: - Product CSV

private struct ProductCatalogRemoteMetadata: Codable, Sendable {
    var eTag: String?
    var lastModified: String?
    var lastCheckedAt: Date?
}

private enum ProductCatalogRemoteSource {
    private nonisolated static let remoteURL = URL(string: "https://mini-garage.oss-cn-shenzhen.aliyuncs.com/products.csv")!
    private nonisolated static let minimumRefreshInterval: TimeInterval = 6 * 60 * 60

    nonisolated static func loadCachedCatalog() -> CatalogData? {
        guard let data = try? Data(contentsOf: cachedCSVURL),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        return ProductCSVLoader.makeCatalog(from: text)
    }

    nonisolated static func refreshIfNeeded(force: Bool) async -> CatalogData? {
        guard shouldRefresh(force: force) else { return nil }

        var metadata = loadMetadata()
        var request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"

        if let eTag = metadata.eTag, eTag.isEmpty == false {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = metadata.lastModified, lastModified.isEmpty == false {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }

            metadata.lastCheckedAt = Date()

            if httpResponse.statusCode == 304 {
                saveMetadata(metadata)
                return nil
            }

            guard (200..<300).contains(httpResponse.statusCode),
                  let text = String(data: data, encoding: .utf8),
                  let catalog = ProductCSVLoader.makeCatalog(from: text) else {
                saveMetadata(metadata)
                return nil
            }

            metadata.eTag = httpResponse.value(forHTTPHeaderField: "ETag") ?? metadata.eTag
            metadata.lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified") ?? metadata.lastModified
            saveCachedCSV(data)
            saveMetadata(metadata)
            return catalog
        } catch {
            return nil
        }
    }

    private nonisolated static func shouldRefresh(force: Bool) -> Bool {
        guard force == false else { return true }
        guard FileManager.default.fileExists(atPath: cachedCSVURL.path) else { return true }
        guard let lastCheckedAt = loadMetadata().lastCheckedAt else { return true }
        return Date().timeIntervalSince(lastCheckedAt) >= minimumRefreshInterval
    }

    private nonisolated static func loadMetadata() -> ProductCatalogRemoteMetadata {
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(ProductCatalogRemoteMetadata.self, from: data) else {
            return ProductCatalogRemoteMetadata()
        }

        return metadata
    }

    private nonisolated static func saveMetadata(_ metadata: ProductCatalogRemoteMetadata) {
        do {
            try ensureCacheDirectory()
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL, options: [.atomic])
        } catch {
            print("Failed to save product catalog metadata: \(error)")
        }
    }

    private nonisolated static func saveCachedCSV(_ data: Data) {
        do {
            try ensureCacheDirectory()
            try data.write(to: cachedCSVURL, options: [.atomic])
        } catch {
            print("Failed to cache product catalog CSV: \(error)")
        }
    }

    private nonisolated static var cacheDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (applicationSupport ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("MINIGTProductCatalog", isDirectory: true)
    }

    private nonisolated static var cachedCSVURL: URL {
        cacheDirectory.appendingPathComponent("products.csv")
    }

    private nonisolated static var metadataURL: URL {
        cacheDirectory.appendingPathComponent("products_metadata.json")
    }

    private nonisolated static func ensureCacheDirectory() throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}

private enum ProductCSVLoader {
    nonisolated static func loadBundledCatalog(bundle: Bundle = .main) -> CatalogData? {
        guard let url = bundle.url(forResource: "products", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        return makeCatalog(from: text)
    }

    nonisolated static func makeCatalog(from text: String) -> CatalogData? {
        let rows = parseRows(text)
        guard let header = rows.first else { return nil }

        var indexes: [String: Int] = [:]
        for (index, value) in header.enumerated() {
            let key = clean(value)
            guard key.isEmpty == false, indexes[key] == nil else { continue }
            indexes[key] = index
        }

        var brands: [MiniGTBrand] = []
        var categories: [MiniGTCategory] = []
        var models: [MiniGTModel] = []
        var brandIdByName: [String: Int] = [:]
        var categoryIdByName: [String: Int] = [:]
        let createdAt = Date.minigt("2026-05-23")

        for row in rows.dropFirst() {
            let number = field("编号", in: row, indexes: indexes)
            let name = field("名称", in: row, indexes: indexes)
            guard number.isEmpty == false, name.isEmpty == false else { continue }

            let brandName = nonEmpty(field("品牌", in: row, indexes: indexes), fallback: "未录入品牌")
            let categoryName = nonEmpty(field("分类", in: row, indexes: indexes), fallback: "未分类")
            let statusText = field("发行状态", in: row, indexes: indexes)

            let brandId = brandIdByName[brandName] ?? {
                let id = brands.count + 1
                brandIdByName[brandName] = id
                brands.append(MiniGTBrand(id: id, name: brandName, logoPath: nil, sortOrder: id))
                return id
            }()

            let categoryId = categoryIdByName[categoryName] ?? {
                let id = categories.count + 1
                categoryIdByName[categoryName] = id
                categories.append(MiniGTCategory(id: id, name: categoryName, parentId: nil, level: 0, sortOrder: id))
                return id
            }()

            let modelId = numericId(from: number) ?? models.count + 1
            let colors = colors(for: modelId)
            let status = modelStatus(from: statusText)

            models.append(MiniGTModel(
                id: modelId,
                name: name,
                brandId: brandId,
                categoryId: categoryId,
                story: "来自 products.csv 的产品记录。编号 \(number)，发行状态 \(status.title)，分类 \(categoryName)。",
                releaseYear: nil,
                scale: "1:64",
                modelNumber: number,
                status: status,
                releaseDate: nil,
                createdAt: createdAt,
                primaryColorHex: colors.primary,
                accentColorHex: colors.accent
            ))
        }

        guard models.isEmpty == false else { return nil }
        return CatalogData(brands: brands, categories: categories, models: models)
    }

    private nonisolated static func field(_ name: String, in row: [String], indexes: [String: Int]) -> String {
        guard let index = indexes[name], index < row.count else { return "" }
        return clean(row[index])
    }

    private nonisolated static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func nonEmpty(_ value: String, fallback: String) -> String {
        value.isEmpty ? fallback : value
    }

    private nonisolated static func numericId(from productNumber: String) -> Int? {
        let digits = productNumber.filter(\.isNumber)
        return Int(digits)
    }

    private nonisolated static func modelStatus(from value: String) -> ModelStatus {
        let normalized = value.lowercased()
        if normalized.contains("released") {
            return .released
        }
        return .upcoming
    }

    private nonisolated static func colors(for modelId: Int) -> (primary: String, accent: String) {
        let palette = [
            ("#C92A2A", "#111827"),
            ("#0EA5E9", "#F8FAFC"),
            ("#F97316", "#111827"),
            ("#1D4ED8", "#EF4444"),
            ("#111827", "#D6A642"),
            ("#FACC15", "#111827"),
            ("#16A34A", "#F8FAFC"),
            ("#7C3AED", "#FDE68A"),
            ("#64748B", "#F97316"),
            ("#F8FAFC", "#DC2626")
        ]
        return palette[abs(modelId) % palette.count]
    }

    private nonisolated static func parseRows(_ text: String) -> [[String]] {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let characters = Array(normalizedText)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isInsideQuotes = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if isInsideQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        isInsideQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    isInsideQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n":
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                case "\r":
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                    if index + 1 < characters.count, characters[index + 1] == "\n" {
                        index += 1
                    }
                default:
                    field.append(character)
                }
            }

            index += 1
        }

        if field.isEmpty == false || row.isEmpty == false {
            row.append(field)
            rows.append(row)
        }

        return rows
    }
}

// MARK: - Seed Data

enum SeedCatalog {
    static let catalog = CatalogData(
        brands: [
            MiniGTBrand(id: 1, name: "Toyota", logoPath: nil, sortOrder: 1),
            MiniGTBrand(id: 2, name: "Nissan", logoPath: nil, sortOrder: 2),
            MiniGTBrand(id: 3, name: "Honda", logoPath: nil, sortOrder: 3),
            MiniGTBrand(id: 4, name: "Lamborghini", logoPath: nil, sortOrder: 4),
            MiniGTBrand(id: 5, name: "Porsche", logoPath: nil, sortOrder: 5),
            MiniGTBrand(id: 6, name: "BMW", logoPath: nil, sortOrder: 6),
            MiniGTBrand(id: 7, name: "McLaren", logoPath: nil, sortOrder: 7)
        ],
        categories: [
            MiniGTCategory(id: 1, name: "轿车", parentId: nil, level: 0, sortOrder: 1),
            MiniGTCategory(id: 2, name: "跑车", parentId: nil, level: 0, sortOrder: 2),
            MiniGTCategory(id: 3, name: "SUV", parentId: nil, level: 0, sortOrder: 3),
            MiniGTCategory(id: 4, name: "赛车", parentId: nil, level: 0, sortOrder: 4),
            MiniGTCategory(id: 5, name: "街车", parentId: nil, level: 0, sortOrder: 5),
            MiniGTCategory(id: 41, name: "GT3", parentId: 4, level: 1, sortOrder: 1),
            MiniGTCategory(id: 42, name: "F1", parentId: 4, level: 1, sortOrder: 2),
            MiniGTCategory(id: 43, name: "WRC", parentId: 4, level: 1, sortOrder: 3),
            MiniGTCategory(id: 44, name: "勒芒", parentId: 4, level: 1, sortOrder: 4)
        ],
        models: [
            MiniGTModel(id: 1, name: "Toyota GR Supra Renaissance Red", brandId: 1, categoryId: 2, story: "A90 Supra 以短轴距、宽轮距和直列六缸回归，MINIGT 版本保留了它紧凑的车身姿态与标志性双气泡车顶。", releaseYear: 2020, scale: "1:64", modelNumber: "MGT001", status: .released, releaseDate: Date.minigt("2020-02-12"), createdAt: Date.minigt("2026-05-22"), primaryColorHex: "#C92A2A", accentColorHex: "#111111"),
            MiniGTModel(id: 2, name: "Nissan GT-R R35 Nismo White", brandId: 2, categoryId: 2, story: "R35 Nismo 是东瀛性能符号之一，白色车身与红色下沿强化了赛道套件的攻击性。", releaseYear: 2019, scale: "1:64", modelNumber: "MGT018", status: .released, releaseDate: Date.minigt("2019-08-21"), createdAt: Date.minigt("2026-05-22"), primaryColorHex: "#F3F4F6", accentColorHex: "#D62828"),
            MiniGTModel(id: 3, name: "Honda Civic Type R Championship White", brandId: 3, categoryId: 5, story: "Type R 的冠军白配色来自 Honda 赛道传统，夸张尾翼和红章是收藏柜里很容易被看见的一台。", releaseYear: 2021, scale: "1:64", modelNumber: "MGT046", status: .released, releaseDate: Date.minigt("2021-04-18"), createdAt: Date.minigt("2026-05-22"), primaryColorHex: "#F8FAFC", accentColorHex: "#C81E1E"),
            MiniGTModel(id: 4, name: "Lamborghini Huracan GT3 EVO Orange", brandId: 4, categoryId: 41, story: "Huracan GT3 EVO 把兰博基尼的楔形线条带进 GT3 赛场，橙色涂装很适合摆进赛道场景。", releaseYear: 2022, scale: "1:64", modelNumber: "MGT092", status: .released, releaseDate: Date.minigt("2022-06-10"), createdAt: Date.minigt("2026-05-22"), primaryColorHex: "#F97316", accentColorHex: "#111827"),
            MiniGTModel(id: 5, name: "Porsche 911 GT3 Touring Shark Blue", brandId: 5, categoryId: 2, story: "没有固定大尾翼的 Touring 版本更克制，鲨蓝色让它在极简白卡风主题下非常跳。", releaseYear: 2023, scale: "1:64", modelNumber: "MGT143", status: .released, releaseDate: Date.minigt("2023-01-15"), createdAt: Date.minigt("2026-05-22"), primaryColorHex: "#0EA5E9", accentColorHex: "#F8FAFC"),
            MiniGTModel(id: 6, name: "BMW M4 GT3 IMSA", brandId: 6, categoryId: 41, story: "M4 GT3 采用大尺寸双肾格栅和宽体空气动力学套件，赛车涂装很适合记录赛事主题收藏。", releaseYear: 2023, scale: "1:64", modelNumber: "MGT177", status: .released, releaseDate: Date.minigt("2023-09-02"), createdAt: Date.minigt("2026-05-22"), primaryColorHex: "#1D4ED8", accentColorHex: "#EF4444"),
            MiniGTModel(id: 7, name: "McLaren Artura Volcano Yellow", brandId: 7, categoryId: 2, story: "Artura 是迈凯伦混动时代的入门超跑，火山黄涂装让车身曲面更有层次。", releaseYear: 2024, scale: "1:64", modelNumber: "MGT201", status: .released, releaseDate: Date.minigt("2024-03-08"), createdAt: Date.minigt("2026-05-22"), primaryColorHex: "#FACC15", accentColorHex: "#111827"),
            MiniGTModel(id: 8, name: "Toyota Land Cruiser 300 Black", brandId: 1, categoryId: 3, story: "Land Cruiser 300 是越野收藏线里稳重的一员，黑色车身适合车库工业风主题。", releaseYear: 2024, scale: "1:64", modelNumber: "MGT219", status: .released, releaseDate: Date.minigt("2024-05-21"), createdAt: Date.minigt("2026-05-22"), primaryColorHex: "#111827", accentColorHex: "#9CA3AF"),
            MiniGTModel(id: 9, name: "Nissan Z Performance Ikazuchi Yellow", brandId: 2, categoryId: 5, story: "新世代 Z 延续长车头短车尾比例，Ikazuchi Yellow 向经典 Z 车系致意。", releaseYear: 2024, scale: "1:64", modelNumber: "MGT230", status: .released, releaseDate: Date.minigt("2024-08-09"), createdAt: Date.minigt("2026-05-22"), primaryColorHex: "#FDE047", accentColorHex: "#111827"),
            MiniGTModel(id: 10, name: "Porsche 963 Hypercar Le Mans", brandId: 5, categoryId: 44, story: "963 回到耐力赛最高组别，红白黑涂装和低矮车身很适合作为勒芒收藏分支的核心。", releaseYear: 2025, scale: "1:64", modelNumber: "MGT260", status: .released, releaseDate: Date.minigt("2025-02-13"), createdAt: Date.minigt("2026-05-22"), primaryColorHex: "#F9FAFB", accentColorHex: "#DC2626"),
            MiniGTModel(id: 11, name: "McLaren 750S Spider Papaya Spark", brandId: 7, categoryId: 2, story: "750S Spider 将 Papaya 配色与开放座舱结合，是迈凯伦展示线里很醒目的一台。", releaseYear: 2026, scale: "1:64", modelNumber: "MGT301", status: .upcoming, releaseDate: Date.minigt("2026-06-28"), createdAt: Date.minigt("2026-05-22"), primaryColorHex: "#F97316", accentColorHex: "#0F172A"),
            MiniGTModel(id: 12, name: "Honda NSX Type S Gotham Gray", brandId: 3, categoryId: 2, story: "NSX Type S 是第二代 NSX 的最终章，哑光灰色让车身折线更冷静。", releaseYear: 2026, scale: "1:64", modelNumber: "MGT309", status: .upcoming, releaseDate: Date.minigt("2026-07-16"), createdAt: Date.minigt("2026-05-22"), primaryColorHex: "#4B5563", accentColorHex: "#EF4444")
        ]
    )

    static let scenes: [DisplayScene] = [
        DisplayScene(id: 1, name: "夜间车库", imagePath: "builtin://garage-night", category: .garage, primaryColorHex: "#1F2937", secondaryColorHex: "#0F172A"),
        DisplayScene(id: 2, name: "发车直道", imagePath: "builtin://track-straight", category: .track, primaryColorHex: "#334155", secondaryColorHex: "#991B1B"),
        DisplayScene(id: 3, name: "城市街角", imagePath: "builtin://street-corner", category: .street, primaryColorHex: "#0F766E", secondaryColorHex: "#1E293B"),
        DisplayScene(id: 4, name: "桌面展台", imagePath: "builtin://desk-showcase", category: .desk, primaryColorHex: "#57534E", secondaryColorHex: "#292524")
    ]
}

// MARK: - Utilities

private enum Currency {
    static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? "¥\(value)"
    }
}

private func clamp<T: Comparable>(_ value: T, min: T, max: T) -> T {
    Swift.max(min, Swift.min(max, value))
}

extension Date {
    nonisolated static func minigt(_ dateString: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dateString) ?? Date()
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)

        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64

        switch cleaned.count {
        case 3:
            red = (int >> 8) * 17
            green = (int >> 4 & 0xF) * 17
            blue = (int & 0xF) * 17
            alpha = 255
        case 6:
            red = int >> 16
            green = int >> 8 & 0xFF
            blue = int & 0xFF
            alpha = 255
        case 8:
            red = int >> 24
            green = int >> 16 & 0xFF
            blue = int >> 8 & 0xFF
            alpha = int & 0xFF
        default:
            red = 0
            green = 0
            blue = 0
            alpha = 255
        }

        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}
