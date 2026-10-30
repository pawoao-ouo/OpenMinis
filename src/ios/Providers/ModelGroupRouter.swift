import Foundation
import os.log

private let logger = AppLogger(category: "ModelGroupRouter")

/// Resolves which ModelEntry to use from a ModelGroup based on the routing strategy.
@MainActor
enum ModelGroupRouter {

    /// Resolve the initial model entry for a session from a group.
    /// - Parameters:
    ///   - group: The model group to resolve from.
    ///   - sessionId: Used for deterministic load-balance hashing.
    ///   - store: The provider config store to look up entries.
    /// - Returns: The resolved ModelEntry id, or nil if no enabled member is available.
    static func resolve(group: ModelGroup, sessionId: String, store: ProviderConfigStore) -> String? {
        let available = availableEntryIds(group: group, store: store)
        logger.info("🔀ROUTE resolve group=\(group.name) strategy=\(group.strategy.rawValue) members=\(group.memberEntryIds) available=\(available)")
        guard !available.isEmpty else {
            logger.warning("🔀ROUTE resolve: no available entries")
            return nil
        }

        switch group.strategy {
        case .fallback:
            logger.info("🔀ROUTE resolve fallback → \(available.first!)")
            return available.first

        case .loadBalance:
            let index = stableIndex(for: sessionId, count: available.count)
            logger.info("🔀ROUTE resolve loadBalance index=\(index) → \(available[index])")
            return available[index]
        }
    }

    /// Stable FNV-1a hash of the session id, reduced modulo `count`.
    /// `String.hashValue` is randomised per process launch, so a session
    /// would be re-pinned to a different member after every restart despite
    /// the documented "deterministic" contract; `abs(hashValue)` also traps
    /// when hashValue == Int.min. Same algorithm as the sync layer's
    /// stableContentHash (ChatStoreSyncHydrators).
    private static func stableIndex(for sessionId: String, count: Int) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in sessionId.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(count))
    }

    /// Get the next fallback entry after the current one failed.
    /// Cycles forward from the current entry, wrapping around to entries before it,
    /// so that one full round of all available entries is attempted per reasoning turn.
    /// Returns nil if no more fallbacks are available.
    static func nextFallback(
        group: ModelGroup,
        currentEntryId: String,
        store: ProviderConfigStore
    ) -> String? {
        let available = availableEntryIds(group: group, store: store)
        logger.info("🔀ROUTE nextFallback current=\(currentEntryId) available=\(available)")
        guard let currentIdx = available.firstIndex(of: currentEntryId) else {
            // Current entry not found in available list — try first available
            logger.warning("🔀ROUTE nextFallback: current entry not in available list, falling back to first=\(available.first ?? "nil")")
            return available.first
        }

        // Try remaining entries after current, then wrap around to entries before current.
        // This ensures each reasoning turn can cycle through all providers exactly once.
        let remaining = available[(currentIdx + 1)...]
        if let next = remaining.first {
            logger.info("🔀ROUTE nextFallback: currentIdx=\(currentIdx) → next=\(next)")
            return next
        }

        let before = available[..<currentIdx]
        if let wrapped = before.first {
            logger.info("🔀ROUTE nextFallback: wrap-around → \(wrapped)")
            return wrapped
        }

        logger.info("🔀ROUTE nextFallback: no more entries (single entry group)")
        return nil
    }

    /// Returns group members that were filtered out (unavailable) with reasons.
    static func unavailableMembers(
        group: ModelGroup, store: ProviderConfigStore
    ) -> [(model: String, instance: String, reason: String)] {
        var result: [(model: String, instance: String, reason: String)] = []
        for entryId in group.memberEntryIds {
            guard let entry = store.entry(for: entryId) else {
                logger.warning("🔀ROUTE unavailable: entry \(entryId) not found in store")
                result.append((model: entryId, instance: "", reason: AppLocalized("Model no longer exists")))
                continue
            }
            guard let inst = store.instance(for: entry.providerInstanceId) else {
                logger.warning("🔀ROUTE unavailable: instance \(entry.providerInstanceId) not found for entry \(entryId)")
                result.append((model: entry.model.displayName, instance: entry.providerInstanceId, reason: AppLocalized("Provider no longer exists")))
                continue
            }
            let label = inst.label
            if entry.isHidden {
                result.append((model: entry.model.displayName, instance: label, reason: AppLocalized("Hidden")))
            } else if !inst.isEnabled {
                result.append((model: entry.model.displayName, instance: label, reason: AppLocalized("Disabled")))
            } else if !inst.hasAnyCredential {
                result.append((model: entry.model.displayName, instance: label, reason: AppLocalized("Not logged in")))
            }
        }
        return result
    }

    // MARK: - Private

    /// Filter group members to those that are enabled, whose provider instance
    /// is enabled, AND whose instance has a usable credential. The credential
    /// gate is what stops a no-token OAuth instance — common after iCloud
    /// sync brings the instance metadata across without bringing its
    /// per-device OAuth tokens — from winning the fallback race and producing
    /// a 403 `OAuth authentication is currently not allowed for this
    /// organization`. The factory would still build a provider for it, but
    /// the request would fail immediately and waste a fallback slot.
    ///
    /// Internal (not private): the Q3 ask card screens its recommended pick
    /// through this same predicate, so a recommendation can never point at
    /// a member the router itself would reject.
    static func availableEntryIds(group: ModelGroup, store: ProviderConfigStore) -> [String] {
        group.memberEntryIds.filter { entryId in
            guard let entry = store.entry(for: entryId) else {
                logger.warning("🔀ROUTE filter: entry \(entryId) not found in store")
                return false
            }
            guard !entry.isHidden else {
                logger.info("🔀ROUTE filter: entry \(entryId) is hidden")
                return false
            }
            guard let instance = store.instance(for: entry.providerInstanceId) else {
                logger.warning("🔀ROUTE filter: instance \(entry.providerInstanceId) not found for entry \(entryId)")
                return false
            }
            guard instance.isEnabled else {
                logger.info("🔀ROUTE filter: instance \(instance.label) (\(instance.id)) disabled for entry \(entryId)")
                return false
            }
            guard instance.hasAnyCredential else {
                logger.info("🔀ROUTE filter: instance \(instance.label) (\(instance.id)) has no credential for entry \(entryId)")
                return false
            }
            return true
        }
    }
}

// MARK: - [T-wire-image-output] Image Output group resolver

/// Resolves image-generation runs to the user's configured Image Output group.
///
/// Mirrors `VisionGroupResolver.candidates`: per-member resolution with a
/// modality filter, because `ModelGroupRouter.resolve` has no modality
/// screening and could hand an image job to a text-only member. Availability
/// itself reuses the router's own predicate
/// (`ModelGroupRouter.availableEntryIds`) — the same gate the shipped
/// default/sub/scheduled-helper slots use — and only the `.imageOutput`
/// filter is added on top. Deliberately lives in this file rather than a
/// new one: a new Swift file plus a hand-edited pbxproj entry is the
/// highest-risk combination in this repo's history, and nothing here needs
/// a file of its own.
@MainActor
enum ImageOutputGroupResolver {

    /// Outcome of resolving the Image Output pointer. The three cases exist
    /// so the caller can tell "nothing configured" (silent, current
    /// behaviour) from "configured but unusable" (Q4: fall back flagged,
    /// never stall, never silently substitute) without re-deriving it from
    /// the pointer — the same distinction `ModelTierResolver` draws by
    /// checking the pointer after `configuredGroup` returns nil.
    enum Resolution {
        /// No Image Output group is configured (pointer nil or dangling).
        case unset
        /// A group is configured but holds no usable image-output member.
        case unroutable(groupName: String, reason: String)
        /// A usable image-output member, in the group's own order/strategy.
        case resolved(entry: ModelEntry, groupName: String)
    }

    /// Resolve the Image Output pointer for one run. `sessionId` only
    /// stabilises `.loadBalance` rotation within a session, mirroring
    /// `ModelGroupRouter.resolve`.
    static func resolve(sessionId: String) -> Resolution {
        let store = ProviderConfigStore.shared
        guard let gid = store.imageOutputGroupId, let group = store.group(for: gid) else {
            return .unset
        }
        let members = candidates(seed: stableSeed(for: sessionId))
        guard let first = members.first else {
            return .unroutable(groupName: group.name, reason: unroutableReason(group: group, store: store))
        }
        return .resolved(entry: first, groupName: group.name)
    }

    /// Every usable image-output member of the configured Image Output
    /// group, in the group's own order. `.loadBalance` groups are rotated
    /// by `seed` so repeated calls spread across members; `.fallback`
    /// groups keep author order and the caller walks the list on failure —
    /// the same contract as `VisionGroupResolver.candidates`.
    static func candidates(seed: Int = 0) -> [ModelEntry] {
        let store = ProviderConfigStore.shared
        guard let gid = store.imageOutputGroupId, let group = store.group(for: gid) else { return [] }

        let available = Set(ModelGroupRouter.availableEntryIds(group: group, store: store))
        var members = group.memberEntryIds.compactMap { entryId -> ModelEntry? in
            guard available.contains(entryId),
                  let entry = store.entry(for: entryId),
                  entry.model.capabilities.supportedModalities.contains(.imageOutput) else { return nil }
            return entry
        }

        if group.strategy == .loadBalance, members.count > 1 {
            let offset = seed % members.count
            members = Array(members[offset...] + members[..<offset])
        }
        return members
    }

    /// One sentence saying why a configured group cannot serve an image
    /// run, so the Q4 fallback note can tell the user what to fix.
    private static func unroutableReason(group: ModelGroup, store: ProviderConfigStore) -> String {
        let ids = group.memberEntryIds
        guard !ids.isEmpty else { return "the group has no members" }
        let available = Set(ModelGroupRouter.availableEntryIds(group: group, store: store))
        let noCapability = ids.filter { id in
            available.contains(id)
                && !(store.entry(for: id)?.model.capabilities.supportedModalities.contains(.imageOutput) ?? false)
        }.count
        let unavailable = ids.filter { !available.contains($0) }.count
        switch (noCapability, unavailable) {
        case (0, 0):
            return "no usable member"
        case (_, 0):
            return "none of its \(ids.count) member(s) declare image-output capability"
        case (0, _):
            return "all \(ids.count) member(s) are unavailable (hidden, disabled, or not logged in)"
        default:
            return "\(noCapability) member(s) declare no image-output capability and "
                + "\(unavailable) are unavailable (hidden, disabled, or not logged in)"
        }
    }

    /// Non-negative FNV-1a seed. `String.hashValue` is randomised per
    /// process launch, so it cannot pin a session to a member across
    /// restarts; the mask keeps the value non-negative so the rotation
    /// offset in `candidates` can never trap on `Int.min`.
    private static func stableSeed(for sessionId: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in sessionId.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash & 0x7FFF_FFFF_FFFF_FFFF)
    }
}

// MARK: - [T-wire-judge] Judge group resolver

/// Resolves judge runs to the user's configured Judge group.
///
/// Mirrors `ImageOutputGroupResolver` in shape (three-case Resolution,
/// per-member resolution, group order/strategy honored) but deliberately
/// has NO modality filter: no `.judge` bit exists in `ModelModality`
/// (verified by grep: the bits are text/image/pdf/audio/video in/out
/// only, and no model anywhere declares judge capability), and a judge
/// call is a plain chat-text prompt — the caller writes its own judging
/// prompt and any group member reachable through the chat runtime can
/// run it. Availability reuses the router's own predicate
/// (`ModelGroupRouter.availableEntryIds`) — the same gate the shipped
/// slots use. A member whose provider cannot be built at call time is
/// handled by the judge runner (flagged pool fallback), not here, so
/// this resolver never needs provider knowledge. Deliberately lives in
/// this file rather than a new one: a new Swift file plus a hand-edited
/// pbxproj entry is the highest-risk combination in this repo's history,
/// and nothing here needs a file of its own.
@MainActor
enum JudgeGroupResolver {

    /// Outcome of resolving the Judge pointer. The three cases exist so
    /// the caller can tell "nothing configured" (plain error) from
    /// "configured but unusable" (Q4: fall back flagged, never stall,
    /// never silently substitute) without re-deriving it from the pointer
    /// — the same distinction `ModelTierResolver` draws.
    enum Resolution {
        /// No Judge group is configured (pointer nil or dangling).
        case unset
        /// A group is configured but holds no usable member.
        case unroutable(groupName: String, reason: String)
        /// A usable member, in the group's own order/strategy.
        case resolved(entry: ModelEntry, groupName: String)
    }

    /// Resolve the Judge pointer for one run. `sessionId` only stabilises
    /// `.loadBalance` rotation within a session, mirroring
    /// `ModelGroupRouter.resolve`.
    static func resolve(sessionId: String) -> Resolution {
        let store = ProviderConfigStore.shared
        guard let gid = store.judgeGroupId, let group = store.group(for: gid) else {
            return .unset
        }
        let members = candidates(seed: stableSeed(for: sessionId))
        guard let first = members.first else {
            return .unroutable(groupName: group.name, reason: unroutableReason(group: group, store: store))
        }
        return .resolved(entry: first, groupName: group.name)
    }

    /// Every usable member of the configured Judge group, in the group's
    /// own order. `.loadBalance` groups are rotated by `seed` so repeated
    /// calls spread across members; `.fallback` groups keep author order
    /// and the caller walks the list on failure — the same contract as
    /// `VisionGroupResolver.candidates`.
    static func candidates(seed: Int = 0) -> [ModelEntry] {
        let store = ProviderConfigStore.shared
        guard let gid = store.judgeGroupId, let group = store.group(for: gid) else { return [] }

        let available = Set(ModelGroupRouter.availableEntryIds(group: group, store: store))
        var members = group.memberEntryIds.compactMap { entryId -> ModelEntry? in
            guard available.contains(entryId),
                  let entry = store.entry(for: entryId) else { return nil }
            return entry
        }

        if group.strategy == .loadBalance, members.count > 1 {
            let offset = seed % members.count
            members = Array(members[offset...] + members[..<offset])
        }
        return members
    }

    /// One sentence saying why a configured group cannot serve a judge
    /// run, so the Q4 fallback note can tell the user what to fix.
    private static func unroutableReason(group: ModelGroup, store: ProviderConfigStore) -> String {
        let ids = group.memberEntryIds
        guard !ids.isEmpty else { return "the group has no members" }
        let available = Set(ModelGroupRouter.availableEntryIds(group: group, store: store))
        let unavailable = ids.filter { !available.contains($0) }.count
        guard unavailable > 0 else { return "no usable member" }
        return "all \(ids.count) member(s) are unavailable (hidden, disabled, or not logged in)"
    }

    /// Non-negative FNV-1a seed, same algorithm as
    /// `ImageOutputGroupResolver.stableSeed` (duplicated rather than
    /// shared: the two resolvers must stay independently movable, and
    /// the function is six lines).
    private static func stableSeed(for sessionId: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in sessionId.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash & 0x7FFF_FFFF_FFFF_FFFF)
    }
}

// MARK: - [T-wire-video] Video Output group resolver

/// Resolves video-generation runs to the user's configured Video Output group.
///
/// Mirrors `ImageOutputGroupResolver` in shape (three-case Resolution,
/// per-member resolution, group order/strategy honored) with the
/// `.videoOutput` modality filter: the bit exists (`LLMTypes.swift`,
/// 1 << 8) and catalogs tag video models with it (keyword mapping for
/// video-gen / video-generation / veo / sora, plus OpenAI / OpenRouter /
/// ModelsDev taggers), so a video job must not land on a member that
/// declares no video-output capability. Availability reuses the router's
/// own predicate (`ModelGroupRouter.availableEntryIds`) — the same gate
/// the shipped slots use. Deliberately lives in this file rather than a
/// new one: a new Swift file plus a hand-edited pbxproj entry is the
/// highest-risk combination in this repo's history, and nothing here
/// needs a file of its own.
///
/// RESOLUTION ONLY — no execution path exists behind this resolver yet.
/// No provider in the tree implements video generation (no generateVideo
/// function, no video endpoint, no polling; the only video-adjacent code
/// is catalog modality tagging and the bridge's --output extension
/// validation). A tool definition, AI disclosure, and row ungrey are
/// deliberately withheld until a real provider video call exists:
/// disclosing a tool that can never produce video would be a dead
/// button, and a greyed slot must stay hidden from the AI.
@MainActor
enum VideoGroupResolver {

    /// Outcome of resolving the Video Output pointer. The three cases
    /// exist so a future caller can tell "nothing configured" (discovery
    /// flow) from "configured but unusable" (Q4: fall back flagged,
    /// never stall, never silently substitute) without re-deriving it
    /// from the pointer — the same distinction `ModelTierResolver`
    /// draws.
    enum Resolution {
        /// No Video Output group is configured (pointer nil or dangling).
        case unset
        /// A group is configured but holds no usable video-output member.
        case unroutable(groupName: String, reason: String)
        /// A usable video-output member, in the group's own order/strategy.
        case resolved(entry: ModelEntry, groupName: String)
    }

    /// Resolve the Video Output pointer for one run. `sessionId` only
    /// stabilises `.loadBalance` rotation within a session, mirroring
    /// `ModelGroupRouter.resolve`.
    static func resolve(sessionId: String) -> Resolution {
        let store = ProviderConfigStore.shared
        guard let gid = store.videoOutputGroupId, let group = store.group(for: gid) else {
            return .unset
        }
        let members = candidates(seed: stableSeed(for: sessionId))
        guard let first = members.first else {
            return .unroutable(groupName: group.name, reason: unroutableReason(group: group, store: store))
        }
        return .resolved(entry: first, groupName: group.name)
    }

    /// Every usable video-output member of the configured Video Output
    /// group, in the group's own order. `.loadBalance` groups are rotated
    /// by `seed` so repeated calls spread across members; `.fallback`
    /// groups keep author order and the caller walks the list on failure —
    /// the same contract as `VisionGroupResolver.candidates`.
    static func candidates(seed: Int = 0) -> [ModelEntry] {
        let store = ProviderConfigStore.shared
        guard let gid = store.videoOutputGroupId, let group = store.group(for: gid) else { return [] }

        let available = Set(ModelGroupRouter.availableEntryIds(group: group, store: store))
        var members = group.memberEntryIds.compactMap { entryId -> ModelEntry? in
            guard available.contains(entryId),
                  let entry = store.entry(for: entryId),
                  entry.model.capabilities.supportedModalities.contains(.videoOutput) else { return nil }
            return entry
        }

        if group.strategy == .loadBalance, members.count > 1 {
            let offset = seed % members.count
            members = Array(members[offset...] + members[..<offset])
        }
        return members
    }

    /// One sentence saying why a configured group cannot serve a video
    /// run, so a future Q4 fallback note can tell the user what to fix.
    private static func unroutableReason(group: ModelGroup, store: ProviderConfigStore) -> String {
        let ids = group.memberEntryIds
        guard !ids.isEmpty else { return "the group has no members" }
        let available = Set(ModelGroupRouter.availableEntryIds(group: group, store: store))
        let noCapability = ids.filter { id in
            available.contains(id)
                && !(store.entry(for: id)?.model.capabilities.supportedModalities.contains(.videoOutput) ?? false)
        }.count
        let unavailable = ids.filter { !available.contains($0) }.count
        switch (noCapability, unavailable) {
        case (0, 0):
            return "no usable member"
        case (_, 0):
            return "none of its \(ids.count) member(s) declare video-output capability"
        case (0, _):
            return "all \(ids.count) member(s) are unavailable (hidden, disabled, or not logged in)"
        default:
            return "\(noCapability) member(s) declare no video-output capability and "
                + "\(unavailable) are unavailable (hidden, disabled, or not logged in)"
        }
    }

    /// Non-negative FNV-1a seed, same algorithm as
    /// `ImageOutputGroupResolver.stableSeed` (duplicated rather than
    /// shared: the resolvers must stay independently movable, and
    /// the function is six lines).
    private static func stableSeed(for sessionId: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in sessionId.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash & 0x7FFF_FFFF_FFFF_FFFF)
    }
}
