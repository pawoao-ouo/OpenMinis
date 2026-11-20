import CryptoKit
import Foundation
import UIKit

private let logger = AppLogger(category: "AIChatVM")

// MARK: - Request-level image budget + Minis paths + tool-output offload

extension AIChatViewModel {

    // MARK: - Request-level image budget

    /// One image part scoped for budget planning. Mirrors Android's
    /// ImageBudget.BudgetImage so the cross-platform algorithm is
    /// identical. linuxPath optional — missing means "no offload mirror
    /// yet; spill if dropped".
    private struct BudgetImage {
        let data: Data
        let linuxPath: String?
        let mimeType: String
    }

    /// Result of [planRequestBudget]. `droppedIds` are pointer-identity
    /// hashes of `Data` instances; providers can re-derive the same id
    /// from any `Data` they hold a strong reference to.
    private struct RequestBudgetPlan {
        let droppedIds: Set<Int>
        let droppedPaths: [Int: String?]
        let keptBytes: Int
        let elidedBytes: Int
        let droppedCount: Int
        let totalCount: Int
        var mutated: Bool { droppedCount > 0 }
    }

    private static func planRequestBudget(
        _ images: [BudgetImage],
        maxBytes: Int = kRequestImageMaxBytes
    ) -> RequestBudgetPlan {
        guard !images.isEmpty else {
            return RequestBudgetPlan(droppedIds: [], droppedPaths: [:], keptBytes: 0, elidedBytes: 0, droppedCount: 0, totalCount: 0)
        }
        var dropped = Set<Int>()
        var droppedPaths: [Int: String?] = [:]
        var kept = 0
        var elided = 0
        // Walk latest → eldest so most-recent images win the budget.
        for img in images.reversed() {
            let id = ObjectIdentifier(img.data as AnyObject).hashValue
            // Cap-clamp each image's effective size to kPerImageMaxBytes —
            // matches what compressedImageDataUnderBudget would produce.
            let effective = min(img.data.count, kPerImageMaxBytes)
            if kept + effective <= maxBytes {
                kept += effective
            } else {
                dropped.insert(id)
                droppedPaths[id] = img.linuxPath
                elided += effective
            }
        }
        return RequestBudgetPlan(droppedIds: dropped, droppedPaths: droppedPaths, keptBytes: kept, elidedBytes: elided, droppedCount: dropped.count, totalCount: images.count)
    }

    /// Construct the text placeholder a provider emits in place of an
    /// elided image. Same shape as Android's `ImageBudget.elidedImagePlaceholder`.
    static func elidedImagePlaceholder(linuxPath: String?) -> String {
        if let p = linuxPath {
            return "[image elided to fit 25MB request budget. Original at \(p) — re-fetch with `read_image \(p)` if you need to see it.]"
        }
        return "[image elided to fit 25MB request budget. Original bytes no longer addressable; ask the user to re-attach if needed.]"
    }

    /// Lazily persist `data` under a session's `attachments/spillover/<sha1>.<ext>`
    /// directory and return the iSH-visible `/var/minis/attachments/spillover/...`
    /// path. Idempotent — same bytes hash to the same path. Returns nil
    /// if the write fails; the caller falls back to the no-path
    /// placeholder variant.
    private static func ensureSpillover(_ data: Data, mimeType: String, sessionId: String) -> String? {
        guard !data.isEmpty else { return nil }
        let ext: String
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/png":  ext = "png"
        case "image/gif":  ext = "gif"
        case "image/webp": ext = "webp"
        case "image/heic", "image/heif": ext = "heic"
        default: ext = "bin"
        }
        // SHA-1 hex digest via CryptoKit.Insecure (SHA-1 is fine here —
        // we're keying a cache by content, not signing anything).
        let digest = Insecure.SHA1.hash(data: data)
        let sha = digest.map { String(format: "%02x", $0) }.joined()
        let attachmentsRoot = PersonaStore.sessionHostDir(
            for: sessionId,
            personaId: PersonaStore.personaIdForSessionDir(forSessionId: sessionId),
            host: "attachments"
        ).appendingPathComponent("spillover", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: attachmentsRoot, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let file = attachmentsRoot.appendingPathComponent("\(sha).\(ext)")
        if !FileManager.default.fileExists(atPath: file.path) {
            do {
                try data.write(to: file)
            } catch {
                return nil
            }
        }
        return "/var/minis/attachments/spillover/\(sha).\(ext)"
    }

    /// Apply the request-level image budget to a fully-resolved agent
    /// history before passing it to a provider. Images that don't fit
    /// under `kRequestImageMaxBytes` (oldest first) are replaced with
    /// text placeholders that point the model back to the linuxPath
    /// where the bytes are still readable via `read_image`. Returns the
    /// budgeted history; same instance when nothing was elided.
    func applyRequestImageBudget(_ messages: [AgentMessage]) -> [AgentMessage] {
        // Collect every image part in chronological order so the planner
        // can reverse-walk and protect the most recent images.
        struct Ref { let msgIdx: Int; let partIdx: Int; let image: BudgetImage }
        var refs: [Ref] = []
        for (mi, msg) in messages.enumerated() {
            for (pi, part) in msg.parts.enumerated() {
                switch part {
                case .imageData(let data, let mimeType, let lp):
                    refs.append(Ref(msgIdx: mi, partIdx: pi, image: BudgetImage(data: data, linuxPath: lp, mimeType: mimeType)))
                case .toolResult(_, _, _, _, let imgData, let imgMime, _, let lp):
                    if let d = imgData {
                        refs.append(Ref(msgIdx: mi, partIdx: pi, image: BudgetImage(data: d, linuxPath: lp, mimeType: imgMime ?? "image/jpeg")))
                    }
                default: break
                }
            }
        }
        guard !refs.isEmpty else { return messages }
        let plan = Self.planRequestBudget(refs.map { $0.image })
        guard plan.mutated else { return messages }

        // Resolve linuxPath for dropped images, spilling if needed.
        var resolved: [Int: String?] = [:]
        let sid = sessionId ?? "unknown"
        for ref in refs {
            let id = ObjectIdentifier(ref.image.data as AnyObject).hashValue
            guard plan.droppedIds.contains(id) else { continue }
            if let existing = ref.image.linuxPath {
                resolved[id] = existing
            } else {
                resolved[id] = Self.ensureSpillover(ref.image.data, mimeType: ref.image.mimeType, sessionId: sid)
            }
        }

        // Build new messages with dropped image parts replaced.
        var mutated = messages
        let grouped = Dictionary(grouping: refs, by: { $0.msgIdx })
        for (mi, group) in grouped {
            var newParts = mutated[mi].parts
            for ref in group {
                let id = ObjectIdentifier(ref.image.data as AnyObject).hashValue
                guard plan.droppedIds.contains(id) else { continue }
                let path: String? = resolved[id] ?? nil
                let placeholder = Self.elidedImagePlaceholder(linuxPath: path)
                let original = newParts[ref.partIdx]
                switch original {
                case .imageData:
                    newParts[ref.partIdx] = .text(placeholder)
                case .toolResult(let id, let name, let content, let isError, _, _, let pageURL, let imgLinuxPath):
                    let newContent = content.isEmpty ? placeholder : "\(content)\n\(placeholder)"
                    newParts[ref.partIdx] = .toolResult(
                        id: id, name: name, content: newContent,
                        isError: isError, imageData: nil, imageMimeType: nil,
                        pageURL: pageURL, imageLinuxPath: imgLinuxPath
                    )
                default: break
                }
            }
            mutated[mi].parts = newParts
        }

        logger.info("[ImageBudget] request-level: dropped=\(plan.droppedCount)/\(plan.totalCount) keptBytes=\(plan.keptBytes) elidedBytes=\(plan.elidedBytes)")

        // Surface to the user via Toast (already-existing infrastructure).
        let droppedCount = plan.droppedCount
        Task { @MainActor in
            self.transientNotice = AppLocalized("Older \(droppedCount) image(s) elided from request to fit 25MB budget")
        }

        return mutated
    }

    /// Single-shot resize + JPEG encode at the given edge/quality. Always
    /// re-encodes (does NOT short-circuit when the input is already small)
    /// so the caller's ladder can compare candidates at consistent settings.
    static func jpegEncode(_ data: Data, maxLongEdge: CGFloat, quality: CGFloat) -> Data? {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
        let pixelW = CGFloat(cgImage.width)
        let pixelH = CGFloat(cgImage.height)
        let longest = max(pixelW, pixelH)
        let targetW: CGFloat
        let targetH: CGFloat
        if longest > maxLongEdge {
            let scale = maxLongEdge / longest
            targetW = pixelW * scale
            targetH = pixelH * scale
        } else {
            targetW = pixelW
            targetH = pixelH
        }
        let newSize = CGSize(width: targetW, height: targetH)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: quality)
    }

    /// Rewrite known provider error messages into friendlier guidance. The
    /// raw Anthropic 413 text is `"Downloaded image content cannot exceed
    /// 30MB"` — we keep the agent-visible record (`raw`) for diagnosis but
    /// surface a localized hint to the user. T-imgsize-13b7d81c.
    static func friendlyErrorMessage(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("image content cannot exceed")
            || lower.contains("image_too_large")
            || (lower.contains("413") && lower.contains("image")) {
            return AppLocalized("Image too large for the provider. The pre-send compressor already shrank it as far as it could; try removing one or more attachments and resending.") + "\n\n" + raw
        }
        // [T-file-write-large-content-timeout] GH#223. A request that dies with
        // a timeout / TLS drop while the model is emitting a big file_write
        // argument surfaces only as "Network error: request timed out", which
        // reads as a connectivity fault and sends users off checking their
        // proxy. The real cause is usually the sheer length of the generated
        // argument, so point at that too — without claiming it as the only
        // cause, since a genuinely bad network produces the same string.
        if lower.contains("timed out") || lower.contains("timeout")
            || lower.contains("request timed out") || lower.contains("secure connection")
            || lower.contains("ssl") || lower.contains("tls") {
            return raw + "\n\n" + AppLocalized("If this happened while writing a large file, the request likely died mid-generation rather than the network being down: the whole file is generated as tool arguments before the write starts. Ask for the file in smaller appended chunks, or have it generated by a short script instead.")
        }
        return raw
    }

    /// Persistent storage directory for a specific session's workspace:
    /// <minis>/<personaId>/<sessionId>/workspace. Same persona rule as
    /// minisOffloadsPersistentDir (session-dir fallback).
    nonisolated static func minisWorkspacePersistentDir(for sid: String, personaId: String? = nil) -> URL {
        PersonaStore.sessionDir(for: sid, personaId: personaId ?? PersonaStore.personaIdForSessionDir(forSessionId: sid))
            .appendingPathComponent("workspace", isDirectory: true)
    }

    /// Persistent storage directory for a specific session's browser snapshots:
    /// <minis>/<personaId>/<sessionId>/browser. Same persona rule as above.
    nonisolated static func minisBrowserPersistentDir(for sid: String, personaId: String? = nil) -> URL {
        PersonaStore.sessionDir(for: sid, personaId: personaId ?? PersonaStore.personaIdForSessionDir(forSessionId: sid))
            .appendingPathComponent("browser", isDirectory: true)
    }

    /// App Group container root for FileProvider-visible directories.
    /// Everything under this path is exposed to iOS Files via the replicated
    /// FileProvider extension. Keep ONLY user-facing subdirs (shared, skills,
    /// memory) here — anything else leaks into "On My iPhone → Minis".
    nonisolated static var minisAppGroupRoot: URL {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedContainerStore.appGroupID
        )!.appendingPathComponent("MinisFileProvider", isDirectory: true)
    }

    /// App Group subdirectory for private metadata that must NOT be exposed
    /// to iOS Files (mounted-folders.json, FileProvider extension logs, etc).
    /// Sibling of `minisAppGroupRoot` inside the same App Group container.
    nonisolated static var minisConfigRoot: URL {
        let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedContainerStore.appGroupID
        )!.appendingPathComponent("MinisConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Memory root. Per-persona dirs live under it in the personas/
    /// container (PersonaStore.memoryDir → memory/personas/<id>/); the
    /// flat files here are the pre-migration shared data, copied once
    /// into memory/personas/default/ and never written again.
    /// Stored in the App Group container so the FileProvider extension can access it.
    nonisolated static var minisMemoryPersistentDir: URL {
        minisAppGroupRoot.appendingPathComponent("memory", isDirectory: true)
    }

    /// Legacy skills root and read-only global baseline. Per-persona dirs
    /// live under it (PersonaStore.skillsDir); new skills are written to
    /// the persona dir, the flat dir is only read as a baseline.
    /// Stored in the App Group container so the FileProvider extension can access it.
    nonisolated static var minisSkillsPersistentDir: URL {
        minisAppGroupRoot.appendingPathComponent("skills", isDirectory: true)
    }

    /// Shared root. Per-persona namespace dirs live under it
    /// (PersonaStore.sharedDir → shared/<personaId>/), where a persona's
    /// new shared data lands. The flat dir itself is a LIVE read/write
    /// runtime area (events.jsonl, together/, heartbeat state) — it is
    /// NOT a read-only mount and must never be locked (crosscheck-verdict
    /// §5: locking it stops together-listening, the event stream and the
    /// heartbeat). Isolation for shared lives in resolution: persona
    /// namespace first, flat area second.
    /// Stored in the App Group container so the FileProvider extension can access it.
    nonisolated static var minisSharedPersistentDir: URL {
        minisAppGroupRoot.appendingPathComponent("shared", isDirectory: true)
    }

    /// Persistent storage directory for MCP server configs (servers.json,
    /// daemon log). Deliberately under MinisConfig, NOT minisAppGroupRoot:
    /// servers.json carries credentials (Authorization headers, API keys) and
    /// must never surface in iOS Files via the FileProvider extension.
    nonisolated static var minisMcpServersPersistentDir: URL {
        minisConfigRoot.appendingPathComponent("mcp-servers", isDirectory: true)
    }

    /// Resolve a `minis://` URL to a host filesystem URL.
    /// Shared resolution logic used by Markdown link handlers and the browser's WKURLSchemeHandler.
    nonisolated static func resolveMinisURL(_ url: URL) -> URL? {
        guard url.scheme == "minis", let host = url.host else { return nil }
        // Tolerate double-encoded links (%25E6…) alongside the correct
        // single-encoded form. [T-fix-double-encoding]
        let subPaths = MinisURLPathDecoding.subPathCandidates(for: url)
        let fm = FileManager.default

        // Primary: resolve via active session, nested under its persona.
        // The persona comes from the PersonaStore cache (populated at
        // session load/create, warmed at launch). A cache miss is NIL —
        // never "default" (items 1–2): the persona-dependent candidates
        // below are skipped and only the global baselines are tried.
        let personaId = PersonaStore.cachedPersonaId(forSessionId: activeSessionId)
        if let sid = activeSessionId, let personaId {
            for subPath in subPaths {
                let candidate = PersonaStore.sessionHostDir(for: sid, personaId: personaId, host: host)
                    .appendingPathComponent(subPath)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }

        // Per-persona directories (memory/shared), then the shared
        // baselines. Skills is GLOBAL — skills/default/ is the dir
        // SkillStore loads from. Memory has NO flat fallback: the flat
        // memory/ files are legacy personal data (owned by the default
        // persona since the migration copied them to
        // memory/personas/default/), not a shared baseline — falling back
        // to them would leak the default persona's memory into every new
        // persona. Skills keeps its flat dir as a read-only baseline
        // (shared skills, by design). Shared keeps its flat dir as the
        // LIVE read/write runtime area (events.jsonl, together/,
        // heartbeat) — second after the persona namespace, never locked.
        var personaDirs: [(String, URL)] = [
            ("skills", PersonaStore.skillsDir(for: PersonaStore.defaultPersonaId)),
        ]
        if let personaId {
            personaDirs.append(("memory", PersonaStore.memoryDir(for: personaId)))
            personaDirs.append(("shared", PersonaStore.sharedDir(for: personaId)))
        }
        let baselineDirs: [(String, URL)] = [
            ("skills", minisSkillsPersistentDir),
            ("shared", minisSharedPersistentDir),
        ]
        for (subdir, dir) in personaDirs where host == subdir {
            for subPath in subPaths {
                let candidate = dir.appendingPathComponent(subPath)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        for (subdir, dir) in baselineDirs where host == subdir {
            for subPath in subPaths {
                let candidate = dir.appendingPathComponent(subPath)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }

        // The old scan-all-sessions fallback is DELETED (decisions.md §3):
        // it silently returned another session's — and therefore another
        // persona's — file. A miss is now an explicit failure (nil), never
        // a silent cross-persona read. Callers surface it as an error.
        logger.warning("[resolveMinisURL] no match host=\(host) sid=\(activeSessionId?.prefix(8) ?? "nil") persona=\(personaId?.prefix(8) ?? "nil") — cross-session fallback removed, returning nil")
        return nil
    }

    struct OffloadResult {
        let linuxPath: String
    }

    /// Save large tool output to persistent storage.
    /// With bind mounts, writing to persistent storage is automatically visible to iSH.
    func offloadToolOutput(_ output: String, toolName: String, toolId: String) -> OffloadResult {
        let fm = FileManager.default
        let sid = sessionId ?? "unknown"

        // Write to persistent storage (bind-mounted, so iSH sees it automatically)
        let persistDir = Self.minisOffloadsPersistentDir(for: sid, personaId: personaId)
        try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)

        let timestamp = Int(Date().timeIntervalSince1970)
        let sanitizedName = toolName.replacingOccurrences(of: "/", with: "_")
        let fileName = "\(sanitizedName)_\(timestamp)_\(toolId.prefix(8)).txt"
        let persistPath = persistDir.appendingPathComponent(fileName)
        try? output.write(to: persistPath, atomically: true, encoding: .utf8)

        let linuxPath = "\(Self.minisOffloadsLinuxDir)/\(fileName)"
        return OffloadResult(linuxPath: linuxPath)
    }

}
