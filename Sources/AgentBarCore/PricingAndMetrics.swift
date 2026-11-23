import Foundation

public struct LongInputRates: Codable, Hashable, Sendable {
    public static let threshold = 272_000
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double
}

public struct ModelPriceRule: Codable, Hashable, Identifiable, Sendable {
    public var id: String { modelPrefix }
    public var modelPrefix: String
    public var inputPerMillionUSD: Double
    public var outputPerMillionUSD: Double
    public var cacheReadPerMillionUSD: Double
    public var cacheWritePerMillionUSD: Double
    public var defaultContextWindow: Int
    public var over272k: LongInputRates?

    public init(
        modelPrefix: String,
        inputPerMillionUSD: Double,
        outputPerMillionUSD: Double,
        cacheReadPerMillionUSD: Double,
        cacheWritePerMillionUSD: Double,
        defaultContextWindow: Int
    ) {
        self.modelPrefix = modelPrefix
        self.inputPerMillionUSD = inputPerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
        self.cacheReadPerMillionUSD = cacheReadPerMillionUSD
        self.cacheWritePerMillionUSD = cacheWritePerMillionUSD
        self.defaultContextWindow = defaultContextWindow
    }
}

public struct PricingSyncStatus: Sendable, Equatable {
    public var activeModelCount: Int
    public var syncedModelCount: Int
    public var source: String
    public var lastSyncedAt: Date?
    public var lastCheckedAt: Date?
    public var usedNotModified304: Bool
    public var errorMessage: String?

    public init(
        activeModelCount: Int,
        syncedModelCount: Int,
        source: String,
        lastSyncedAt: Date? = nil,
        lastCheckedAt: Date? = nil,
        usedNotModified304: Bool = false,
        errorMessage: String? = nil
    ) {
        self.activeModelCount = activeModelCount
        self.syncedModelCount = syncedModelCount
        self.source = source
        self.lastSyncedAt = lastSyncedAt
        self.lastCheckedAt = lastCheckedAt
        self.usedNotModified304 = usedNotModified304
        self.errorMessage = errorMessage
    }
}

struct PersistedPricingCatalogCache: Codable, Sendable {
    var formatVersion: Int? = 2
    var source: String
    var etag: String?
    var lastSyncedAt: Date
    var lastCheckedAt: Date
    var rules: [ModelPriceRule]
}

final class PricingCatalogStore: @unchecked Sendable {
    private let lock = NSLock()
    private var didBootstrap = false
    private var userCustomRules: [ModelPriceRule] = []
    private var remoteRules: [ModelPriceRule] = []
    private var bundledRules: [ModelPriceRule] = []
    private var cachedETag: String?
    private var cachedSource: String = "内置价格表"
    private var lastSyncedAt: Date?
    private var lastCheckedAt: Date?

    private var exactIndex: [String: ModelPriceRule] = [:]
    private var sortedPrefixRules: [(canonicalPrefix: String, rule: ModelPriceRule)] = []
    private var sortedCustomRules: [ModelPriceRule] = []

    static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("AgentBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var remoteCacheURL: URL {
        appSupportDirectory.appendingPathComponent("pricing-catalog-cache.json")
    }

    static var customRulesURL: URL {
        appSupportDirectory.appendingPathComponent("custom-pricing-rules.json")
    }

    func ensureBootstrapped() {
        lock.lock()
        defer { lock.unlock() }
        guard !didBootstrap else { return }
        didBootstrap = true
        bundledRules = Self.loadBundledRules()
        if let cache = Self.loadRemoteCache() {
            remoteRules = cache.rules
            if cache.formatVersion != 2, cache.source == "models.dev",
               let bundled = bundledRules.first(where: { $0.over272k != nil }),
               let index = remoteRules.firstIndex(where: { $0.modelPrefix == bundled.modelPrefix }),
               remoteRules[index].inputPerMillionUSD == bundled.inputPerMillionUSD,
               remoteRules[index].outputPerMillionUSD == bundled.outputPerMillionUSD,
               remoteRules[index].cacheReadPerMillionUSD == bundled.cacheReadPerMillionUSD,
               remoteRules[index].cacheWritePerMillionUSD == bundled.cacheWritePerMillionUSD {
                remoteRules[index].over272k = bundled.over272k
            }
            cachedETag = cache.formatVersion == 2 ? cache.etag : nil
            cachedSource = cache.source
            lastSyncedAt = cache.lastSyncedAt
            lastCheckedAt = cache.formatVersion == 2 ? cache.lastCheckedAt : nil
        } else if !bundledRules.isEmpty {
            cachedSource = "内置快照"
        }
        userCustomRules = Self.loadCustomRules()
        rebuildIndicesLocked()
    }

    private static func loadBundledRules() -> [ModelPriceRule] {
        var candidates: [URL] = []
        if let bundleURL = Bundle.main.url(forResource: "default-pricing", withExtension: "json") {
            candidates.append(bundleURL)
        }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(execDir.appendingPathComponent("../Resources/default-pricing.json").standardizedFileURL)
        }
        for url in candidates {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let cache = try? Self.makeJSONDecoder().decode(PersistedPricingCatalogCache.self, from: data),
               !cache.rules.isEmpty {
                return cache.rules
            }
            if let arr = try? JSONDecoder().decode([ModelPriceRule].self, from: data), !arr.isEmpty {
                return arr
            }
        }
        return []
    }

    private static func loadRemoteCache() -> PersistedPricingCatalogCache? {
        guard let data = try? Data(contentsOf: remoteCacheURL) else { return nil }
        return try? makeJSONDecoder().decode(PersistedPricingCatalogCache.self, from: data)
    }

    private static func loadCustomRules() -> [ModelPriceRule] {
        guard let data = try? Data(contentsOf: customRulesURL) else { return [] }
        return (try? JSONDecoder().decode([ModelPriceRule].self, from: data)) ?? []
    }

    private static func makeJSONDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    private static func makeJSONEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return enc
    }

    private func rebuildIndicesLocked() {
        sortedCustomRules = userCustomRules.sorted { $0.modelPrefix.count > $1.modelPrefix.count }

        // Priority among catalog layers: remote synced > bundled JSON snapshot > compiled defaults
        var mergedByCanonical: [String: ModelPriceRule] = [:]
        for layer in [remoteRules, bundledRules.filter { $0.over272k != nil }, bundledRules, PricingCatalog.defaults] {
            for rule in layer {
                let key = PricingCatalog.canonicalModelKey(rule.modelPrefix)
                guard !key.isEmpty else { continue }
                if mergedByCanonical[key] == nil {
                    mergedByCanonical[key] = rule
                }
            }
        }
        exactIndex = mergedByCanonical
        sortedPrefixRules = mergedByCanonical
            .map { (canonicalPrefix: $0.key, rule: $0.value) }
            .sorted { lhs, rhs in
                if lhs.canonicalPrefix.count != rhs.canonicalPrefix.count {
                    return lhs.canonicalPrefix.count > rhs.canonicalPrefix.count
                }
                return lhs.canonicalPrefix < rhs.canonicalPrefix
            }
    }

    func lookup(rawModel: String) -> ModelPriceRule? {
        ensureBootstrapped()
        lock.lock()
        defer { lock.unlock() }

        let trimmedLower = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedLower.isEmpty else { return nil }

        let canonical = PricingCatalog.canonicalModelKey(trimmedLower)
        // 1. User custom overrides take highest priority (supports gateway prefix like "internal/" -> $0)
        for custom in sortedCustomRules {
            let prefixLower = custom.modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !prefixLower.isEmpty else { continue }
            if trimmedLower.hasPrefix(prefixLower) || trimmedLower.contains(prefixLower) {
                return custom
            }
            let customCanon = PricingCatalog.canonicalModelKey(prefixLower)
            if !customCanon.isEmpty && PricingCatalog.matchesPrefixBoundary(modelKey: canonical, prefixKey: customCanon) {
                return custom
            }
        }

        guard !canonical.isEmpty else { return nil }
        // 2. Exact match on canonical model ID
        if let exact = exactIndex[canonical] {
            return exact
        }
        // 3. Exact match after stripping trailing release date suffix (-YYYYMMDD or -YYMMDD)
        let strippedDate = PricingCatalog.stripTrailingDateStamp(canonical)
        if strippedDate != canonical, let exactNoDate = exactIndex[strippedDate] {
            return exactNoDate
        }
        // 4. Longest boundary-aware prefix match
        for item in sortedPrefixRules {
            if PricingCatalog.matchesPrefixBoundary(modelKey: canonical, prefixKey: item.canonicalPrefix) {
                return item.rule
            }
        }
        return nil
    }

    func getCustomRules() -> [ModelPriceRule] {
        ensureBootstrapped()
        lock.lock()
        defer { lock.unlock() }
        return userCustomRules
    }

    func setCustomRules(_ rules: [ModelPriceRule]) {
        ensureBootstrapped()
        lock.lock()
        userCustomRules = rules
        rebuildIndicesLocked()
        lock.unlock()
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: Self.customRulesURL, options: .atomic)
        }
    }

    func currentSnapshotInfo() -> (etag: String?, lastCheckedAt: Date?, status: PricingSyncStatus) {
        ensureBootstrapped()
        lock.lock()
        defer { lock.unlock() }
        let status = PricingSyncStatus(
            activeModelCount: exactIndex.count,
            syncedModelCount: remoteRules.count,
            source: cachedSource,
            lastSyncedAt: lastSyncedAt,
            lastCheckedAt: lastCheckedAt
        )
        return (cachedETag, lastCheckedAt, status)
    }

    func recordNotModifiedCheck(now: Date = Date()) -> PricingSyncStatus {
        ensureBootstrapped()
        lock.lock()
        lastCheckedAt = now
        let cacheToSave: PersistedPricingCatalogCache? = !remoteRules.isEmpty ? PersistedPricingCatalogCache(
            source: cachedSource,
            etag: cachedETag,
            lastSyncedAt: lastSyncedAt ?? now,
            lastCheckedAt: now,
            rules: remoteRules
        ) : nil
        let status = PricingSyncStatus(
            activeModelCount: exactIndex.count,
            syncedModelCount: remoteRules.count,
            source: cachedSource,
            lastSyncedAt: lastSyncedAt,
            lastCheckedAt: lastCheckedAt,
            usedNotModified304: true
        )
        lock.unlock()
        if let cacheToSave, let data = try? Self.makeJSONEncoder().encode(cacheToSave) {
            try? data.write(to: Self.remoteCacheURL, options: .atomic)
        }
        return status
    }

    func updateRemoteCatalog(
        rules: [ModelPriceRule],
        source: String,
        etag: String?,
        now: Date = Date()
    ) -> PricingSyncStatus {
        ensureBootstrapped()
        lock.lock()
        remoteRules = rules
        cachedSource = source
        cachedETag = etag
        lastSyncedAt = now
        lastCheckedAt = now
        rebuildIndicesLocked()
        let status = PricingSyncStatus(
            activeModelCount: exactIndex.count,
            syncedModelCount: remoteRules.count,
            source: cachedSource,
            lastSyncedAt: now,
            lastCheckedAt: now
        )
        lock.unlock()

        let payload = PersistedPricingCatalogCache(
            source: source,
            etag: etag,
            lastSyncedAt: now,
            lastCheckedAt: now,
            rules: rules
        )
        if let data = try? Self.makeJSONEncoder().encode(payload) {
            try? data.write(to: Self.remoteCacheURL, options: .atomic)
        }
        return status
    }
}

public enum PricingCatalog {
    fileprivate static let store = PricingCatalogStore()

    /// Compiled 2026-11 baseline catalog used offline before or without remote sync.
    public static let defaults: [ModelPriceRule] = [
        // Anthropic Claude 5.x / 4.x / 3.x & Fable
        ModelPriceRule(modelPrefix: "claude-opus-5-5", inputPerMillionUSD: 4.0, outputPerMillionUSD: 20.0, cacheReadPerMillionUSD: 0.2, cacheWritePerMillionUSD: 5.0, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "claude-opus-5", inputPerMillionUSD: 5.0, outputPerMillionUSD: 25.0, cacheReadPerMillionUSD: 0.5, cacheWritePerMillionUSD: 6.25, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "claude-opus-4-6", inputPerMillionUSD: 5.0, outputPerMillionUSD: 25.0, cacheReadPerMillionUSD: 0.5, cacheWritePerMillionUSD: 6.25, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "claude-opus-4-7", inputPerMillionUSD: 5.0, outputPerMillionUSD: 25.0, cacheReadPerMillionUSD: 0.5, cacheWritePerMillionUSD: 6.25, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "claude-opus-4-8", inputPerMillionUSD: 5.0, outputPerMillionUSD: 25.0, cacheReadPerMillionUSD: 0.5, cacheWritePerMillionUSD: 6.25, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "claude-opus-4-5", inputPerMillionUSD: 5.0, outputPerMillionUSD: 25.0, cacheReadPerMillionUSD: 0.5, cacheWritePerMillionUSD: 6.25, defaultContextWindow: 200_000),
        ModelPriceRule(modelPrefix: "claude-opus-4", inputPerMillionUSD: 15.0, outputPerMillionUSD: 75.0, cacheReadPerMillionUSD: 1.5, cacheWritePerMillionUSD: 18.75, defaultContextWindow: 200_000),
        ModelPriceRule(modelPrefix: "claude-3-opus", inputPerMillionUSD: 15.0, outputPerMillionUSD: 75.0, cacheReadPerMillionUSD: 1.5, cacheWritePerMillionUSD: 18.75, defaultContextWindow: 200_000),
        ModelPriceRule(
            modelPrefix: "claude-opus",
            inputPerMillionUSD: 5.0,
            outputPerMillionUSD: 25.0,
            cacheReadPerMillionUSD: 0.5,
            cacheWritePerMillionUSD: 6.25,
            defaultContextWindow: 1_000_000
        ),
        ModelPriceRule(modelPrefix: "claude-fable-5-2", inputPerMillionUSD: 8.0, outputPerMillionUSD: 40.0, cacheReadPerMillionUSD: 0.2, cacheWritePerMillionUSD: 10.0, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "claude-fable-5-1", inputPerMillionUSD: 10.0, outputPerMillionUSD: 50.0, cacheReadPerMillionUSD: 0.25, cacheWritePerMillionUSD: 12.5, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "claude-fable", inputPerMillionUSD: 10.0, outputPerMillionUSD: 50.0, cacheReadPerMillionUSD: 1.0, cacheWritePerMillionUSD: 12.5, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "claude-sonnet-5-5", inputPerMillionUSD: 2.0, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 0.1, cacheWritePerMillionUSD: 2.5, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "claude-sonnet-5", inputPerMillionUSD: 2.0, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 0.2, cacheWritePerMillionUSD: 2.5, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "claude-sonnet-4", inputPerMillionUSD: 3.0, outputPerMillionUSD: 15.0, cacheReadPerMillionUSD: 0.3, cacheWritePerMillionUSD: 3.75, defaultContextWindow: 200_000),
        ModelPriceRule(modelPrefix: "claude-3-5-sonnet", inputPerMillionUSD: 3.0, outputPerMillionUSD: 15.0, cacheReadPerMillionUSD: 0.3, cacheWritePerMillionUSD: 3.75, defaultContextWindow: 200_000),
        ModelPriceRule(modelPrefix: "claude-3-7-sonnet", inputPerMillionUSD: 3.0, outputPerMillionUSD: 15.0, cacheReadPerMillionUSD: 0.3, cacheWritePerMillionUSD: 3.75, defaultContextWindow: 200_000),
        ModelPriceRule(
            modelPrefix: "claude-sonnet",
            inputPerMillionUSD: 2.0,
            outputPerMillionUSD: 10.0,
            cacheReadPerMillionUSD: 0.1,
            cacheWritePerMillionUSD: 2.5,
            defaultContextWindow: 1_000_000
        ),
        ModelPriceRule(modelPrefix: "claude-haiku-5-5", inputPerMillionUSD: 0.1, outputPerMillionUSD: 0.5, cacheReadPerMillionUSD: 0.01, cacheWritePerMillionUSD: 0.125, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "claude-haiku-4-5", inputPerMillionUSD: 1.0, outputPerMillionUSD: 5.0, cacheReadPerMillionUSD: 0.1, cacheWritePerMillionUSD: 1.25, defaultContextWindow: 200_000),
        ModelPriceRule(modelPrefix: "claude-3-5-haiku", inputPerMillionUSD: 0.8, outputPerMillionUSD: 4.0, cacheReadPerMillionUSD: 0.08, cacheWritePerMillionUSD: 1.0, defaultContextWindow: 200_000),
        ModelPriceRule(
            modelPrefix: "claude-haiku",
            inputPerMillionUSD: 0.8,
            outputPerMillionUSD: 4.0,
            cacheReadPerMillionUSD: 0.08,
            cacheWritePerMillionUSD: 1.0,
            defaultContextWindow: 200_000
        ),
        // OpenAI GPT-6.x / GPT-5.x / Codex / o-series / GPT-4.x
        ModelPriceRule(modelPrefix: "gpt-6.2-astra", inputPerMillionUSD: 8.0, outputPerMillionUSD: 40.0, cacheReadPerMillionUSD: 0.4, cacheWritePerMillionUSD: 10.0, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-6.2-sol", inputPerMillionUSD: 2.0, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 0.1, cacheWritePerMillionUSD: 2.5, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-6.1-terra", inputPerMillionUSD: 1.0, outputPerMillionUSD: 5.0, cacheReadPerMillionUSD: 0.05, cacheWritePerMillionUSD: 1.25, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-6.1-sol", inputPerMillionUSD: 2.0, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 0.1, cacheWritePerMillionUSD: 2.5, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-6-astra", inputPerMillionUSD: 10.0, outputPerMillionUSD: 50.0, cacheReadPerMillionUSD: 1.0, cacheWritePerMillionUSD: 12.5, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-6-sol", inputPerMillionUSD: 2.0, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 0.2, cacheWritePerMillionUSD: 2.5, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-6-luna", inputPerMillionUSD: 0.1, outputPerMillionUSD: 0.5, cacheReadPerMillionUSD: 0.01, cacheWritePerMillionUSD: 0.125, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-6", inputPerMillionUSD: 2.0, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 0.1, cacheWritePerMillionUSD: 2.5, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-5.6-sol", inputPerMillionUSD: 4.0, outputPerMillionUSD: 20.0, cacheReadPerMillionUSD: 0.4, cacheWritePerMillionUSD: 5.0, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-5.6-terra", inputPerMillionUSD: 2.0, outputPerMillionUSD: 12.0, cacheReadPerMillionUSD: 0.2, cacheWritePerMillionUSD: 2.5, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-5.6-luna", inputPerMillionUSD: 0.2, outputPerMillionUSD: 1.2, cacheReadPerMillionUSD: 0.02, cacheWritePerMillionUSD: 0.25, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-5.6", inputPerMillionUSD: 4.0, outputPerMillionUSD: 20.0, cacheReadPerMillionUSD: 0.4, cacheWritePerMillionUSD: 5.0, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-5.5-pro", inputPerMillionUSD: 30.0, outputPerMillionUSD: 180.0, cacheReadPerMillionUSD: 30.0, cacheWritePerMillionUSD: 30.0, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-5.5", inputPerMillionUSD: 5.0, outputPerMillionUSD: 30.0, cacheReadPerMillionUSD: 0.5, cacheWritePerMillionUSD: 5.0, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-5.4-pro", inputPerMillionUSD: 30.0, outputPerMillionUSD: 180.0, cacheReadPerMillionUSD: 30.0, cacheWritePerMillionUSD: 30.0, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-5.4-mini", inputPerMillionUSD: 0.75, outputPerMillionUSD: 4.5, cacheReadPerMillionUSD: 0.075, cacheWritePerMillionUSD: 0.75, defaultContextWindow: 400_000),
        ModelPriceRule(modelPrefix: "gpt-5.4-nano", inputPerMillionUSD: 0.2, outputPerMillionUSD: 1.25, cacheReadPerMillionUSD: 0.02, cacheWritePerMillionUSD: 0.2, defaultContextWindow: 400_000),
        ModelPriceRule(modelPrefix: "gpt-5.4", inputPerMillionUSD: 2.5, outputPerMillionUSD: 15.0, cacheReadPerMillionUSD: 0.25, cacheWritePerMillionUSD: 2.5, defaultContextWindow: 1_050_000),
        ModelPriceRule(modelPrefix: "gpt-5.3-codex", inputPerMillionUSD: 1.75, outputPerMillionUSD: 14.0, cacheReadPerMillionUSD: 0.175, cacheWritePerMillionUSD: 1.75, defaultContextWindow: 400_000),
        ModelPriceRule(modelPrefix: "gpt-5.2-pro", inputPerMillionUSD: 21.0, outputPerMillionUSD: 168.0, cacheReadPerMillionUSD: 21.0, cacheWritePerMillionUSD: 21.0, defaultContextWindow: 400_000),
        ModelPriceRule(modelPrefix: "gpt-5.2", inputPerMillionUSD: 1.75, outputPerMillionUSD: 14.0, cacheReadPerMillionUSD: 0.175, cacheWritePerMillionUSD: 1.75, defaultContextWindow: 400_000),
        ModelPriceRule(modelPrefix: "gpt-5.1", inputPerMillionUSD: 1.25, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 0.125, cacheWritePerMillionUSD: 1.25, defaultContextWindow: 400_000),
        ModelPriceRule(modelPrefix: "gpt-5-pro", inputPerMillionUSD: 15.0, outputPerMillionUSD: 120.0, cacheReadPerMillionUSD: 15.0, cacheWritePerMillionUSD: 15.0, defaultContextWindow: 400_000),
        ModelPriceRule(modelPrefix: "gpt-5-mini", inputPerMillionUSD: 0.25, outputPerMillionUSD: 2.0, cacheReadPerMillionUSD: 0.025, cacheWritePerMillionUSD: 0.25, defaultContextWindow: 400_000),
        ModelPriceRule(modelPrefix: "gpt-5-nano", inputPerMillionUSD: 0.05, outputPerMillionUSD: 0.4, cacheReadPerMillionUSD: 0.005, cacheWritePerMillionUSD: 0.05, defaultContextWindow: 400_000),
        ModelPriceRule(
            modelPrefix: "gpt-5",
            inputPerMillionUSD: 1.25,
            outputPerMillionUSD: 10.0,
            cacheReadPerMillionUSD: 0.125,
            cacheWritePerMillionUSD: 1.25,
            defaultContextWindow: 400_000
        ),
        ModelPriceRule(
            modelPrefix: "codex",
            inputPerMillionUSD: 1.5,
            outputPerMillionUSD: 6.0,
            cacheReadPerMillionUSD: 0.375,
            cacheWritePerMillionUSD: 1.5,
            defaultContextWindow: 258_400
        ),
        ModelPriceRule(modelPrefix: "o3-pro", inputPerMillionUSD: 20.0, outputPerMillionUSD: 80.0, cacheReadPerMillionUSD: 20.0, cacheWritePerMillionUSD: 20.0, defaultContextWindow: 200_000),
        ModelPriceRule(modelPrefix: "o3-mini", inputPerMillionUSD: 1.1, outputPerMillionUSD: 4.4, cacheReadPerMillionUSD: 0.55, cacheWritePerMillionUSD: 1.1, defaultContextWindow: 200_000),
        ModelPriceRule(modelPrefix: "o3", inputPerMillionUSD: 2.0, outputPerMillionUSD: 8.0, cacheReadPerMillionUSD: 0.5, cacheWritePerMillionUSD: 2.0, defaultContextWindow: 200_000),
        ModelPriceRule(modelPrefix: "o4-mini", inputPerMillionUSD: 1.1, outputPerMillionUSD: 4.4, cacheReadPerMillionUSD: 0.275, cacheWritePerMillionUSD: 1.1, defaultContextWindow: 200_000),
        ModelPriceRule(modelPrefix: "gpt-4.1-mini", inputPerMillionUSD: 0.4, outputPerMillionUSD: 1.6, cacheReadPerMillionUSD: 0.1, cacheWritePerMillionUSD: 0.4, defaultContextWindow: 1_047_576),
        ModelPriceRule(modelPrefix: "gpt-4.1-nano", inputPerMillionUSD: 0.1, outputPerMillionUSD: 0.4, cacheReadPerMillionUSD: 0.025, cacheWritePerMillionUSD: 0.1, defaultContextWindow: 1_047_576),
        ModelPriceRule(modelPrefix: "gpt-4.1", inputPerMillionUSD: 2.0, outputPerMillionUSD: 8.0, cacheReadPerMillionUSD: 0.5, cacheWritePerMillionUSD: 2.0, defaultContextWindow: 1_047_576),
        ModelPriceRule(modelPrefix: "gpt-4o-mini", inputPerMillionUSD: 0.15, outputPerMillionUSD: 0.6, cacheReadPerMillionUSD: 0.075, cacheWritePerMillionUSD: 0.15, defaultContextWindow: 128_000),
        ModelPriceRule(modelPrefix: "gpt-4o", inputPerMillionUSD: 2.5, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 1.25, cacheWritePerMillionUSD: 2.5, defaultContextWindow: 128_000),
        // Google Gemini 4 / 3.x / 2.5
        ModelPriceRule(modelPrefix: "gemini-4-neon", inputPerMillionUSD: 3.0, outputPerMillionUSD: 15.0, cacheReadPerMillionUSD: 0.15, cacheWritePerMillionUSD: 3.0, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "gemini-4-hydrogen", inputPerMillionUSD: 1.5, outputPerMillionUSD: 7.5, cacheReadPerMillionUSD: 0.075, cacheWritePerMillionUSD: 1.5, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "gemini-4-carbon", inputPerMillionUSD: 2.0, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 0.1, cacheWritePerMillionUSD: 2.0, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "gemini-4-argon", inputPerMillionUSD: 2.0, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 0.1, cacheWritePerMillionUSD: 2.0, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "gemini-4", inputPerMillionUSD: 2.0, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 0.1, cacheWritePerMillionUSD: 2.0, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "gemini-3.8-flash", inputPerMillionUSD: 0.75, outputPerMillionUSD: 3.75, cacheReadPerMillionUSD: 0.075, cacheWritePerMillionUSD: 0.75, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "gemini-3.7-flash", inputPerMillionUSD: 0.75, outputPerMillionUSD: 3.75, cacheReadPerMillionUSD: 0.075, cacheWritePerMillionUSD: 0.75, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "gemini-3-flash", inputPerMillionUSD: 0.5, outputPerMillionUSD: 3.0, cacheReadPerMillionUSD: 0.05, cacheWritePerMillionUSD: 0.5, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "gemini-2.5-pro", inputPerMillionUSD: 1.25, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 0.125, cacheWritePerMillionUSD: 1.25, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "gemini-2.5-flash-lite", inputPerMillionUSD: 0.1, outputPerMillionUSD: 0.4, cacheReadPerMillionUSD: 0.01, cacheWritePerMillionUSD: 0.1, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "gemini-2.5-flash", inputPerMillionUSD: 0.3, outputPerMillionUSD: 2.5, cacheReadPerMillionUSD: 0.03, cacheWritePerMillionUSD: 0.3, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "gemini", inputPerMillionUSD: 1.25, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 0.125, cacheWritePerMillionUSD: 1.25, defaultContextWindow: 1_048_576),
        // DeepSeek V4 / V3 / R1
        ModelPriceRule(modelPrefix: "deepseek-v4-pro", inputPerMillionUSD: 0.66, outputPerMillionUSD: 1.98, cacheReadPerMillionUSD: 0.022, cacheWritePerMillionUSD: 0.66, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "deepseek-v4.1-flash", inputPerMillionUSD: 0.15, outputPerMillionUSD: 0.6, cacheReadPerMillionUSD: 0.003, cacheWritePerMillionUSD: 0.15, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "deepseek-v4-flash", inputPerMillionUSD: 0.15, outputPerMillionUSD: 0.6, cacheReadPerMillionUSD: 0.003, cacheWritePerMillionUSD: 0.15, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "deepseek-flash", inputPerMillionUSD: 0.15, outputPerMillionUSD: 0.6, cacheReadPerMillionUSD: 0.003, cacheWritePerMillionUSD: 0.15, defaultContextWindow: 1_048_576),
        ModelPriceRule(
            modelPrefix: "deepseek",
            inputPerMillionUSD: 0.27,
            outputPerMillionUSD: 1.10,
            cacheReadPerMillionUSD: 0.07,
            cacheWritePerMillionUSD: 0.27,
            defaultContextWindow: 128_000
        ),
        // Moonshot Kimi K3 / K2.x
        ModelPriceRule(modelPrefix: "kimi-k3.1-pro-highspeed", inputPerMillionUSD: 4.0, outputPerMillionUSD: 20.0, cacheReadPerMillionUSD: 0.2, cacheWritePerMillionUSD: 4.0, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "kimi-k3.1-pro", inputPerMillionUSD: 2.0, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 0.2, cacheWritePerMillionUSD: 2.0, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "kimi-k3", inputPerMillionUSD: 3.0, outputPerMillionUSD: 15.0, cacheReadPerMillionUSD: 0.3, cacheWritePerMillionUSD: 3.0, defaultContextWindow: 1_048_576),
        ModelPriceRule(modelPrefix: "kimi-k2.7-code-highspeed", inputPerMillionUSD: 1.9, outputPerMillionUSD: 8.0, cacheReadPerMillionUSD: 0.38, cacheWritePerMillionUSD: 1.9, defaultContextWindow: 262_144),
        ModelPriceRule(modelPrefix: "kimi-k2.7-code", inputPerMillionUSD: 0.95, outputPerMillionUSD: 4.0, cacheReadPerMillionUSD: 0.19, cacheWritePerMillionUSD: 0.95, defaultContextWindow: 262_144),
        ModelPriceRule(modelPrefix: "kimi-k2.6", inputPerMillionUSD: 0.95, outputPerMillionUSD: 4.0, cacheReadPerMillionUSD: 0.16, cacheWritePerMillionUSD: 0.95, defaultContextWindow: 262_144),
        ModelPriceRule(modelPrefix: "kimi", inputPerMillionUSD: 2.0, outputPerMillionUSD: 10.0, cacheReadPerMillionUSD: 0.2, cacheWritePerMillionUSD: 2.0, defaultContextWindow: 262_144),
        // Zhipu / Z.ai GLM-5.x / 4.x
        ModelPriceRule(modelPrefix: "glm-5.3-flashx", inputPerMillionUSD: 0.30, outputPerMillionUSD: 1.05, cacheReadPerMillionUSD: 0.085, cacheWritePerMillionUSD: 0.0, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "glm-5.3-flash", inputPerMillionUSD: 0.12, outputPerMillionUSD: 0.42, cacheReadPerMillionUSD: 0.034, cacheWritePerMillionUSD: 0.0, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "glm-5.3", inputPerMillionUSD: 1.20, outputPerMillionUSD: 4.18, cacheReadPerMillionUSD: 0.30, cacheWritePerMillionUSD: 0.0, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "glm-5.2", inputPerMillionUSD: 1.20, outputPerMillionUSD: 4.18, cacheReadPerMillionUSD: 0.30, cacheWritePerMillionUSD: 0.0, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "glm-5.1", inputPerMillionUSD: 0.90, outputPerMillionUSD: 3.59, cacheReadPerMillionUSD: 0.19, cacheWritePerMillionUSD: 0.0, defaultContextWindow: 200_000),
        ModelPriceRule(modelPrefix: "glm-5", inputPerMillionUSD: 0.60, outputPerMillionUSD: 2.69, cacheReadPerMillionUSD: 0.15, cacheWritePerMillionUSD: 0.0, defaultContextWindow: 204_800),
        ModelPriceRule(modelPrefix: "glm-4.7-flashx", inputPerMillionUSD: 0.075, outputPerMillionUSD: 0.45, cacheReadPerMillionUSD: 0.015, cacheWritePerMillionUSD: 0.0, defaultContextWindow: 200_000),
        ModelPriceRule(modelPrefix: "glm-4.7", inputPerMillionUSD: 0.45, outputPerMillionUSD: 2.09, cacheReadPerMillionUSD: 0.09, cacheWritePerMillionUSD: 0.0, defaultContextWindow: 204_800),
        ModelPriceRule(modelPrefix: "glm-4.6", inputPerMillionUSD: 0.60, outputPerMillionUSD: 2.20, cacheReadPerMillionUSD: 0.11, cacheWritePerMillionUSD: 0.0, defaultContextWindow: 204_800),
        ModelPriceRule(modelPrefix: "glm-4.5", inputPerMillionUSD: 0.60, outputPerMillionUSD: 2.20, cacheReadPerMillionUSD: 0.11, cacheWritePerMillionUSD: 0.0, defaultContextWindow: 131_072),
        ModelPriceRule(modelPrefix: "glm", inputPerMillionUSD: 0.60, outputPerMillionUSD: 2.20, cacheReadPerMillionUSD: 0.11, cacheWritePerMillionUSD: 0.0, defaultContextWindow: 200_000),
        // Doubao / Volcengine Seed
        ModelPriceRule(modelPrefix: "doubao-seed-2-1-pro", inputPerMillionUSD: 0.89, outputPerMillionUSD: 4.45, cacheReadPerMillionUSD: 0.18, cacheWritePerMillionUSD: 0.89, defaultContextWindow: 1_024_000),
        ModelPriceRule(modelPrefix: "doubao-seed-2-1-turbo", inputPerMillionUSD: 0.45, outputPerMillionUSD: 2.23, cacheReadPerMillionUSD: 0.09, cacheWritePerMillionUSD: 0.45, defaultContextWindow: 256_000),
        ModelPriceRule(
            modelPrefix: "doubao",
            inputPerMillionUSD: 0.15,
            outputPerMillionUSD: 0.60,
            cacheReadPerMillionUSD: 0.03,
            cacheWritePerMillionUSD: 0.15,
            defaultContextWindow: 128_000
        ),
        // xAI Grok
        ModelPriceRule(modelPrefix: "grok-4.7", inputPerMillionUSD: 2.0, outputPerMillionUSD: 6.0, cacheReadPerMillionUSD: 0.5, cacheWritePerMillionUSD: 2.0, defaultContextWindow: 500_000),
        ModelPriceRule(modelPrefix: "grok-4.6", inputPerMillionUSD: 2.0, outputPerMillionUSD: 6.0, cacheReadPerMillionUSD: 0.5, cacheWritePerMillionUSD: 2.0, defaultContextWindow: 500_000),
        ModelPriceRule(modelPrefix: "grok-4.5", inputPerMillionUSD: 2.0, outputPerMillionUSD: 6.0, cacheReadPerMillionUSD: 0.3, cacheWritePerMillionUSD: 2.0, defaultContextWindow: 500_000),
        ModelPriceRule(modelPrefix: "grok-4.3", inputPerMillionUSD: 1.25, outputPerMillionUSD: 2.5, cacheReadPerMillionUSD: 0.2, cacheWritePerMillionUSD: 1.25, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "grok-4.20", inputPerMillionUSD: 1.25, outputPerMillionUSD: 2.5, cacheReadPerMillionUSD: 0.2, cacheWritePerMillionUSD: 1.25, defaultContextWindow: 1_000_000),
        ModelPriceRule(
            modelPrefix: "grok",
            inputPerMillionUSD: 2.0,
            outputPerMillionUSD: 6.0,
            cacheReadPerMillionUSD: 0.5,
            cacheWritePerMillionUSD: 2.0,
            defaultContextWindow: 500_000
        ),
        // Qwen & MiniMax
        ModelPriceRule(modelPrefix: "qwen3.6-flash", inputPerMillionUSD: 0.18, outputPerMillionUSD: 1.03, cacheReadPerMillionUSD: 0.04, cacheWritePerMillionUSD: 0.18, defaultContextWindow: 1_000_000),
        ModelPriceRule(modelPrefix: "qwen", inputPerMillionUSD: 0.4, outputPerMillionUSD: 1.6, cacheReadPerMillionUSD: 0.1, cacheWritePerMillionUSD: 0.4, defaultContextWindow: 262_144),
        ModelPriceRule(modelPrefix: "minimax-m2.7", inputPerMillionUSD: 0.29, outputPerMillionUSD: 1.20, cacheReadPerMillionUSD: 0.06, cacheWritePerMillionUSD: 0.29, defaultContextWindow: 204_800),
        ModelPriceRule(modelPrefix: "minimax", inputPerMillionUSD: 0.29, outputPerMillionUSD: 1.20, cacheReadPerMillionUSD: 0.06, cacheWritePerMillionUSD: 0.29, defaultContextWindow: 204_800)
    ]

    public static let fallbackDefaultRule = ModelPriceRule(
        modelPrefix: "default",
        inputPerMillionUSD: 2.0,
        outputPerMillionUSD: 8.0,
        cacheReadPerMillionUSD: 0.2,
        cacheWritePerMillionUSD: 2.5,
        defaultContextWindow: 200_000
    )

    /// Normalizes gateway prefixes (`provider/model:latest`), Bedrock/Vertex wrappers, and version separators (`5.5` -> `5-5`, `glm-53` -> `glm-5-3`).
    public static func canonicalModelKey(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return "" }
        if let atHostRange = s.range(of: " @ ") {
            s = String(s[..<atHostRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let lastSlash = s.lastIndex(of: "/") {
            s = String(s[s.index(after: lastSlash)...])
        }
        if let openBracket = s.lastIndex(of: "["), s.hasSuffix("]") {
            let inside = s[s.index(after: openBracket)..<s.index(before: s.endIndex)]
            if !inside.isEmpty, inside.allSatisfy({ $0.isNumber || $0 == "m" || $0 == "k" }) {
                s = String(s[..<openBracket])
            }
        }
        var strippedSuffix = true
        while strippedSuffix {
            strippedSuffix = false
            for suffix in [":latest", ":free", ":beta", ":exacto", ":thinking", ":1m", ":200k", "-v1:0", "-v2:0"] {
                if s.hasSuffix(suffix) {
                    s.removeLast(suffix.count)
                    strippedSuffix = true
                }
            }
        }
        for marker in [".anthropic.", ":anthropic.", ".openai.", ":openai.", ".google.", ":google."] {
            if let r = s.range(of: marker) {
                s = String(s[r.upperBound...])
                break
            }
        }
        for prefix in ["us.anthropic.", "eu.anthropic.", "global.anthropic.", "apac.anthropic.", "anthropic."] {
            if s.hasPrefix(prefix) {
                s.removeFirst(prefix.count)
                break
            }
        }
        if let atIdx = s.lastIndex(of: "@") {
            let tail = s[s.index(after: atIdx)...]
            if tail.count == 8 && tail.allSatisfy(\.isNumber) {
                s = String(s[..<atIdx])
            }
        }
        // Convert compact two-digit GLM aliases like `glm-53` or `glm-47-flash` into `glm-5-3` / `glm-4-7-flash`
        if s.hasPrefix("glm-"), s.count >= 6 {
            let chars = Array(s)
            if chars[4].isNumber && chars[5].isNumber && (chars.count == 6 || chars[6] == "-") {
                let rest = chars.count > 6 ? String(chars[6...]) : ""
                s = "glm-\(chars[4])-\(chars[5])\(rest)"
            }
        }
        // Unify dot between digits with hyphen (`claude-opus-5.5` == `claude-opus-5-5`, `gpt-6.2-astra` == `gpt-6-2-astra`)
        var unified: [Character] = []
        let chars = Array(s)
        unified.reserveCapacity(chars.count)
        for idx in chars.indices {
            if chars[idx] == ".",
               idx > 0, idx + 1 < chars.count,
               chars[idx - 1].isNumber, chars[idx + 1].isNumber {
                unified.append("-")
            } else {
                unified.append(chars[idx])
            }
        }
        return String(unified)
    }

    static func stripTrailingDateStamp(_ key: String) -> String {
        guard let dashIdx = key.lastIndex(of: "-") else { return key }
        let tail = key[key.index(after: dashIdx)...]
        if (tail.count == 8 && tail.hasPrefix("20") && tail.allSatisfy(\.isNumber))
            || (tail.count == 6 && tail.allSatisfy(\.isNumber)) {
            return String(key[..<dashIdx])
        }
        return key
    }

    static func matchesPrefixBoundary(modelKey: String, prefixKey: String) -> Bool {
        if modelKey == prefixKey { return true }
        guard modelKey.hasPrefix(prefixKey) else { return false }
        let nextIdx = modelKey.index(modelKey.startIndex, offsetBy: prefixKey.count)
        let nextChar = modelKey[nextIdx]
        return nextChar == "-" || nextChar == ":" || nextChar == "_"
    }

    public static var customOverrideRules: [ModelPriceRule] {
        get { store.getCustomRules() }
        set { store.setCustomRules(newValue) }
    }

    public static var currentSyncStatus: PricingSyncStatus {
        store.currentSnapshotInfo().status
    }

    public static func rule(
        for model: String?,
        provider: String? = nil,
        customRules: [ModelPriceRule]? = nil
    ) -> ModelPriceRule? {
        let combined = qualifiedModelKey(model: model, provider: provider)
        guard let raw = combined?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let explicitRules = customRules {
            return matchExplicitRules(rawModel: raw, rules: explicitRules)
        }
        return store.lookup(rawModel: raw)
    }

    private static func matchExplicitRules(rawModel: String, rules: [ModelPriceRule]) -> ModelPriceRule? {
        let lower = rawModel.lowercased()
        let canonical = canonicalModelKey(lower)
        let strippedDate = stripTrailingDateStamp(canonical)
        let indexed = rules.map { (canon: canonicalModelKey($0.modelPrefix), rule: $0) }
        if let exact = indexed.first(where: { !$0.canon.isEmpty && $0.canon == canonical }) {
            return exact.rule
        }
        if strippedDate != canonical,
           let exactNoDate = indexed.first(where: { !$0.canon.isEmpty && $0.canon == strippedDate }) {
            return exactNoDate.rule
        }
        let sorted = indexed.sorted { $0.canon.count > $1.canon.count }
        for item in sorted where !item.canon.isEmpty {
            if matchesPrefixBoundary(modelKey: canonical, prefixKey: item.canon) {
                return item.rule
            }
        }
        return rules
            .sorted { $0.modelPrefix.count > $1.modelPrefix.count }
            .first { lower.contains($0.modelPrefix.lowercased()) }
    }

    public static func estimatedCostUSD(
        usage: TokenUsage,
        model: String?,
        rules: [ModelPriceRule]? = nil
    ) -> Double? {
        guard usage.totalTokens > 0 else { return nil }
        let matched = rule(for: model, customRules: rules) ?? fallbackDefaultRule
        return costForRule(usage: usage, rule: matched)
    }

    public static func estimatedCostUSD(
        for session: AgentSession,
        rules: [ModelPriceRule]? = nil
    ) -> Double? {
        guard session.usage.totalTokens > 0 else { return nil }
        return computeScopedCost(
            totalUsage: session.usage,
            perModelUsages: session.modelUsages,
            longInputs: session.longInputUsages,
            fallbackModel: qualifiedModelKey(model: session.model, provider: session.provider),
            provider: session.provider,
            rules: rules
        )
    }

    public static func estimatedTodayCostUSD(
        for session: AgentSession,
        dayCutoff: Date = Calendar.current.startOfDay(for: Date()),
        demoMode: Bool = false,
        rules: [ModelPriceRule]? = nil
    ) -> Double? {
        if demoMode {
            return estimatedCostUSD(for: session, rules: rules)
        }
        let today = session.effectiveTodayUsage(dayCutoff: dayCutoff, demoMode: false)
        guard today.totalTokens > 0 else { return nil }
        let perModel = session.todayUsage != nil ? session.todayModelUsages : session.modelUsages
        return computeScopedCost(
            totalUsage: today,
            perModelUsages: perModel,
            longInputs: session.todayUsage != nil ? session.todayLongInputUsages : session.longInputUsages,
            fallbackModel: qualifiedModelKey(model: session.model, provider: session.provider),
            provider: session.provider,
            rules: rules
        )
    }

    private static func qualifiedModelKey(model: String?, provider: String?) -> String? {
        guard let m = model?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else {
            return provider
        }
        if m.contains("/") { return m }
        if let p = provider?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            return "\(p)/\(m)"
        }
        return m
    }

    private static func computeScopedCost(
        totalUsage: TokenUsage,
        perModelUsages: [String: TokenUsage]?,
        longInputs: [String: TokenUsage]?,
        fallbackModel: String?,
        provider: String?,
        rules: [ModelPriceRule]?
    ) -> Double {
        guard let perModelUsages, !perModelUsages.isEmpty else {
            let matched = rule(for: fallbackModel, customRules: rules) ?? fallbackDefaultRule
            return costForRule(usage: totalUsage, rule: matched)
        }
        var sumCost = 0.0
        var attributed = TokenUsage()
        for (modelName, modelUsage) in perModelUsages where modelUsage.totalTokens > 0 {
            let lookupName = qualifiedModelKey(model: modelName, provider: provider)
            let matched = rule(for: lookupName, customRules: rules) ?? fallbackDefaultRule
            sumCost += costForRule(usage: modelUsage, rule: matched)
            if let long = longInputs?[modelName], let tier = matched.over272k,
               canonicalModelKey(modelName) == canonicalModelKey(matched.modelPrefix) {
                let covered = modelUsage.subtractingClamped(modelUsage.subtractingClamped(long))
                let tierCost = (Double(covered.input) * tier.input + Double(covered.output) * tier.output
                    + Double(covered.cacheRead) * tier.cacheRead + Double(covered.cacheWrite) * tier.cacheWrite) / 1_000_000
                sumCost += tierCost - costForRule(usage: covered, rule: matched)
            }
            attributed = attributed.adding(modelUsage)
        }
        let remainder = totalUsage.subtractingClamped(attributed)
        if remainder.totalTokens > 0 {
            let matched = rule(for: fallbackModel, customRules: rules) ?? fallbackDefaultRule
            sumCost += costForRule(usage: remainder, rule: matched)
        }
        return sumCost
    }

    private static func costForRule(usage: TokenUsage, rule: ModelPriceRule) -> Double {
        let m = 1_000_000.0
        let inputCost = (Double(usage.input) / m) * rule.inputPerMillionUSD
        let outputCost = (Double(usage.output) / m) * rule.outputPerMillionUSD
        let cacheReadCost = (Double(usage.cacheRead) / m) * rule.cacheReadPerMillionUSD
        let cacheWriteCost = (Double(usage.cacheWrite) / m) * rule.cacheWritePerMillionUSD
        return inputCost + outputCost + cacheReadCost + cacheWriteCost
    }

    public static func defaultContextWindow(for model: String?) -> Int {
        rule(for: model)?.defaultContextWindow ?? 200_000
    }
}

public enum PricingCatalogSyncService {
    public static let modelsDevEndpoint = URL(string: "https://models.dev/api.json")!
    public static let openRouterEndpoint = URL(string: "https://openrouter.ai/api/v1/models")!

    private static let authoritativeProviders: [String] = [
        "anthropic",
        "openai",
        "google",
        "deepseek",
        "moonshotai",
        "moonshotai-cn",
        "zhipuai",
        "zai",
        "xai",
        "volcengine",
        "alibaba",
        "alibaba-cn",
        "qwen",
        "minimax",
        "minimax-cn",
        "mistral",
        "cohere",
        "perplexity",
        "stepfun",
        "meta",
        "google-vertex",
        "amazon-bedrock"
    ]

    private static let cloudAggregatorProviders: Set<String> = [
        "volcengine",
        "alibaba",
        "alibaba-cn",
        "google-vertex",
        "amazon-bedrock"
    ]

    private static let skippedProviderKeywords: [String] = [
        "coding-plan",
        "copilot",
        "free",
        "puter"
    ]

    public static func syncIfNeeded(maxAgeHours: Double = 24) async -> PricingSyncStatus {
        let info = PricingCatalog.store.currentSnapshotInfo()
        if let lastChecked = info.lastCheckedAt,
           Date().timeIntervalSince(lastChecked) < maxAgeHours * 3600,
           info.status.syncedModelCount > 0 {
            return info.status
        }
        return await syncNow()
    }

    public static func syncNow() async -> PricingSyncStatus {
        let info = PricingCatalog.store.currentSnapshotInfo()
        do {
            var req = URLRequest(url: modelsDevEndpoint, timeoutInterval: 18)
            req.setValue("AgentBar/0.2", forHTTPHeaderField: "User-Agent")
            req.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
            if let etag = info.etag, !etag.isEmpty, info.status.syncedModelCount > 0 {
                req.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                if http.statusCode == 304 {
                    return PricingCatalog.store.recordNotModifiedCheck()
                }
                if (200..<300).contains(http.statusCode) {
                    let parsed = parseModelsDevJSON(data)
                    if !parsed.isEmpty {
                        let newETag = http.value(forHTTPHeaderField: "ETag")
                        return PricingCatalog.store.updateRemoteCatalog(
                            rules: parsed,
                            source: "models.dev",
                            etag: newETag
                        )
                    }
                }
            }
        } catch {
            // Fall through to OpenRouter public API fallback
        }

        do {
            var fallbackReq = URLRequest(url: openRouterEndpoint, timeoutInterval: 18)
            fallbackReq.setValue("AgentBar/0.2", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: fallbackReq)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                let parsed = parseOpenRouterJSON(data)
                if !parsed.isEmpty {
                    return PricingCatalog.store.updateRemoteCatalog(
                        rules: parsed,
                        source: "openrouter.ai",
                        etag: nil
                    )
                }
            }
            var errStatus = PricingCatalog.store.currentSnapshotInfo().status
            errStatus.errorMessage = "远端价格源返回异常状态"
            return errStatus
        } catch {
            var errStatus = PricingCatalog.store.currentSnapshotInfo().status
            errStatus.errorMessage = error.localizedDescription
            return errStatus
        }
    }

    /// Parses `https://models.dev/api.json` from authoritative first-party and cloud providers so third-party resellers cannot shadow official model pricing.
    public static func parseModelsDevJSON(_ data: Data) -> [ModelPriceRule] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        let orderedProviders = authoritativeProviders.filter { root[$0] != nil }
        let providersToScan = orderedProviders.isEmpty ? root.keys.sorted() : orderedProviders

        var seenCanonical: Set<String> = []
        var result: [ModelPriceRule] = []

        for providerID in providersToScan {
            let lowerProv = providerID.lowercased()
            if skippedProviderKeywords.contains(where: { lowerProv.contains($0) }) {
                continue
            }
            guard let provObj = root[providerID] as? [String: Any],
                  let modelsObj = provObj["models"] as? [String: Any] else {
                continue
            }
            for modelID in modelsObj.keys.sorted() {
                guard let m = modelsObj[modelID] as? [String: Any],
                      let cost = m["cost"] as? [String: Any] else {
                    continue
                }
                let input = Self.doubleValue(cost["input"]) ?? 0
                let output = Self.doubleValue(cost["output"]) ?? 0
                guard input > 0 || output > 0 else { continue }
                let cacheRead = Self.doubleValue(cost["cache_read"]) ?? input
                let cacheWrite = Self.doubleValue(cost["cache_write"]) ?? input
                let limitObj = m["limit"] as? [String: Any]
                let rawCtx = Self.intValue(limitObj?["context"]) ?? 200_000
                let ctx = rawCtx > 0 ? rawCtx : 200_000

                let bareID = modelID.split(separator: "/").last.map(String.init) ?? modelID
                if bareID.contains(":") { continue }
                let bareLower = bareID.lowercased()
                if cloudAggregatorProviders.contains(lowerProv),
                   (bareLower.hasPrefix("deepseek-") || bareLower.hasPrefix("claude-") || bareLower.hasPrefix("gpt-")) {
                    continue
                }
                let canon = PricingCatalog.canonicalModelKey(bareID)
                guard !canon.isEmpty, seenCanonical.insert(canon).inserted else { continue }

                var rule = ModelPriceRule(
                    modelPrefix: bareID.lowercased(),
                    inputPerMillionUSD: input,
                    outputPerMillionUSD: output,
                    cacheReadPerMillionUSD: cacheRead,
                    cacheWritePerMillionUSD: cacheWrite,
                    defaultContextWindow: ctx
                )
                if providerID == "openai", bareLower == "gpt-6.2-astra",
                   let tiers = cost["tiers"] as? [[String: Any]] {
                    rule.over272k = tiers.compactMap { item -> LongInputRates? in
                        guard let tier = item["tier"] as? [String: Any], tier["type"] as? String == "context",
                              tier["size"] as? Int == LongInputRates.threshold,
                              let input = doubleValue(item["input"]), let output = doubleValue(item["output"]),
                              let read = doubleValue(item["cache_read"]), let write = doubleValue(item["cache_write"]),
                              [input, output, read, write].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
                        return LongInputRates(input: input, output: output, cacheRead: read, cacheWrite: write)
                    }.first
                }
                result.append(rule)
            }
        }
        return result
    }

    /// Fallback parser for `https://openrouter.ai/api/v1/models` (per-token USD strings -> per-1M USD).
    public static func parseOpenRouterJSON(_ data: Data) -> [ModelPriceRule] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else {
            return []
        }
        var seenCanonical: Set<String> = []
        var result: [ModelPriceRule] = []

        for item in items {
            guard let rawID = item["id"] as? String,
                  !rawID.contains(":"),
                  let pricing = item["pricing"] as? [String: Any] else {
                continue
            }
            let promptPerTok = Self.doubleValue(pricing["prompt"]) ?? 0
            let compPerTok = Self.doubleValue(pricing["completion"]) ?? 0
            let input = promptPerTok * 1_000_000.0
            let output = compPerTok * 1_000_000.0
            guard input > 0 || output > 0 else { continue }
            let cacheRead = (Self.doubleValue(pricing["input_cache_read"]).map { $0 * 1_000_000.0 }) ?? input
            let cacheWrite = (Self.doubleValue(pricing["input_cache_write"]).map { $0 * 1_000_000.0 }) ?? input
            let rawCtx = Self.intValue(item["context_length"]) ?? 200_000
            let ctx = rawCtx > 0 ? rawCtx : 200_000

            let bareID = rawID.split(separator: "/").last.map(String.init) ?? rawID
            let canon = PricingCatalog.canonicalModelKey(bareID)
            guard !canon.isEmpty, seenCanonical.insert(canon).inserted else { continue }

            result.append(ModelPriceRule(
                modelPrefix: bareID.lowercased(),
                inputPerMillionUSD: input,
                outputPerMillionUSD: output,
                cacheReadPerMillionUSD: cacheRead,
                cacheWritePerMillionUSD: cacheWrite,
                defaultContextWindow: ctx
            ))
        }
        return result
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

public enum FormattingHelpers {
    public static func compactTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            let val = Double(count) / 1_000.0
            return val >= 100 ? String(format: "%.0fk", val) : String(format: "%.1fk", val)
        } else {
            return "\(count)"
        }
    }

    public static func memoryString(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024.0)
        }
        return String(format: "%.0f MB", mb)
    }

    public static func relativeDuration(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds) 秒前"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) 分钟前"
        }
        let hours = minutes / 60
        let remMin = minutes % 60
        if hours < 24 {
            return remMin > 0 ? "\(hours) 小时 \(remMin) 分" : "\(hours) 小时前"
        }
        return "\(hours / 24) 天前"
    }

    public static func elapsedString(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds) 秒"
        }
        let minutes = seconds / 60
        let remSec = seconds % 60
        if minutes < 60 {
            return "\(minutes) 分 \(String(format: "%02d", remSec)) 秒"
        }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    public static func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    public static func providerDisplay(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.contains("anthropic") { return "Anthropic" }
        if lower.contains("openai") { return "OpenAI" }
        if lower.contains("deepseek") { return "DeepSeek" }
        if lower.contains("volces") || lower.contains("ark") || lower.contains("doubao") { return "火山方舟" }
        if lower.contains("bedrock") || lower.contains("amazonaws") { return "AWS Bedrock" }
        if lower.contains("vertex") || lower.contains("aiplatform.googleapis") { return "Vertex AI" }
        if lower.contains("x.ai") || lower.contains("grok") { return "xAI" }
        return raw
    }
}
