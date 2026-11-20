package com.openminis.app.data

import android.content.Context
import com.openminis.app.data.repository.ChatRepository
import com.openminis.app.data.repository.MemoryRepository
import com.openminis.app.logging.AppLogger
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Multi-persona isolation (Android parity with iOS PersonaStore):
 * persona identity + per-persona directory layout.
 *
 * A persona IS a session: a new session is its own persona
 * (persona id == session id) and starts with empty memory/SOUL dirs —
 * it inherits nothing from any other persona. Sessions that predate
 * this layout read back "default" and share the one-time migrated copy
 * of the old shared data at `minis-global/memory/personas/default/`.
 * Fork/duplicate inherit the source session's persona id (same persona,
 * new conversation thread) — on Android the fork path copies the
 * memory files explicitly (SessionForkManager.copyMemory).
 * There is no separate Persona type and no persona picker UI — that is
 * a product decision, not an omission here.
 *
 * Layout (decisions.md §3 as amended by crosscheck-verdict §4 — the
 * runtime already stores personas this way, so the app adopts the
 * existing layout instead of inventing a second one):
 *   minis-global/memory/personas/<personaId>/GLOBAL.md,
 *   .../YYYY-MM-DD.md, .../SOUL.md
 *   minis-global/memory/personas/me/ is the USER profile
 *   (personas/me/SOUL.md), not a persona — [allPersonaIds] excludes it
 *   everywhere personas are enumerated.
 *
 * Android has no `persona_id` column on its session rows (no Room
 * migration in this change), so "predates the layout" is recorded
 * instead as a SharedPreferences set of session ids that existed when
 * the one-time migration ran. A session id in that set resolves to
 * "default"; any other id resolves to itself. Sessions created after
 * the migration are new personas by construction.
 *
 * Session file dirs (workspace/<sid>/, attachments/<sid>/) stay flat
 * under minis-global/: they were already per-session, and Android has
 * no scan-all-sessions resolver to close, so nesting them under a
 * persona adds nothing. Only the memory layout moves.
 */
object PersonaStore {

    const val DEFAULT_PERSONA_ID = "default"

    /** User-profile pseudo-persona (personas/me/SOUL.md): the human's own
     *  profile, injected as "about the person you're talking to" — NOT a
     *  persona. Must be excluded whenever personas are enumerated. */
    const val USER_PROFILE_PERSONA_ID = "me"

    /** Persona id for scheduled tasks that cannot be attributed to any
     *  session (a NEW_SESSION task with no target session). Runs under
     *  the legacy/default memory, never under another persona. */
    const val LEGACY_PERSONA_ID = "legacy"

    const val MEMORY_ROOT_SUBDIR = "minis-global/memory"
    const val PERSONAS_SUBDIR = "personas"

    private const val TAG = "PersonaStore"
    private const val PREFS_NAME = "minis_persona"
    private const val KEY_MIGRATION_DONE = "migration_completed_v1"
    private const val KEY_LEGACY_DEFAULT_SESSIONS = "legacy_default_sessions"

    // MARK: - Paths

    /** The personas container: <filesDir>/minis-global/memory/personas/. */
    fun personasDir(filesDir: File): File =
        File(File(filesDir, MEMORY_ROOT_SUBDIR), PERSONAS_SUBDIR)

    /** Per-persona memory root: <filesDir>/minis-global/memory/personas/<personaId>/ */
    fun memoryDir(filesDir: File, personaId: String): File =
        File(personasDir(filesDir), personaId)

    fun soulFile(filesDir: File, personaId: String): File =
        File(memoryDir(filesDir, personaId), "SOUL.md")

    fun globalFile(filesDir: File, personaId: String): File =
        File(memoryDir(filesDir, personaId), "GLOBAL.md")

    fun dailyFile(filesDir: File, personaId: String, date: String): File =
        File(memoryDir(filesDir, personaId), "$date.md")

    /** All persona ids that have a memory dir, EXCLUDING the user-profile
     *  pseudo-persona ("me"). Sorted for determinism. */
    fun allPersonaIds(filesDir: File): List<String> {
        val dir = personasDir(filesDir)
        return (dir.listFiles() ?: emptyArray())
            .filter { it.isDirectory && it.name != USER_PROFILE_PERSONA_ID && !it.name.startsWith(".") }
            .map { it.name }
            .sorted()
    }

    // MARK: - Identity

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun isMigrationDone(context: Context): Boolean =
        prefs(context).getBoolean(KEY_MIGRATION_DONE, false)

    /**
     * Persona id for a session: "default" when the session existed
     * before the one-time migration (recorded in the legacy set), the
     * session id itself otherwise. A cache miss on the legacy set (no
     * migration has ever run) resolves to the session id — a fresh
     * install has no legacy data to preserve.
     */
    fun personaIdForSession(context: Context, sessionId: String): String {
        val legacy = prefs(context)
            .getStringSet(KEY_LEGACY_DEFAULT_SESSIONS, null)?.toSet() ?: emptySet()
        return if (sessionId in legacy) DEFAULT_PERSONA_ID else sessionId
    }

    /** MemoryRepository scoped to a session's persona dir. */
    fun memoryRepositoryForSession(context: Context, sessionId: String): MemoryRepository =
        MemoryRepository(memoryDir(context.filesDir, personaIdForSession(context, sessionId)))

    /** MemoryRepository scoped to an explicit persona id (scheduled-task runs). */
    fun memoryRepositoryForPersona(context: Context, personaId: String): MemoryRepository =
        MemoryRepository(memoryDir(context.filesDir, personaId))

    // MARK: - One-time legacy migration

    /**
     * Shared one-time migration job. Started at app launch (MinisApp);
     * session loading awaits it via [awaitMigration] so no prompt is
     * ever built against pre-migration paths. After the first run the
     * flag short-circuit makes awaiting it a no-op.
     */
    @Volatile
    private var migrationJob: Job? = null

    fun startMigration(context: Context, chatRepository: ChatRepository) {
        if (migrationJob?.isActive == true) return
        if (isMigrationDone(context)) return
        migrationJob = CoroutineScope(Dispatchers.IO).launch {
            migrateLegacyDataIfNeeded(context.applicationContext, chatRepository)
        }
    }

    suspend fun awaitMigration() {
        migrationJob?.join()
    }

    /**
     * Copies the old shared memory/SOUL files into
     * `minis-global/memory/personas/default/` and records the sessions
     * that existed at migration time as default-persona sessions.
     * Idempotent: guarded by a SharedPreferences flag and by
     * "target missing" checks, so a re-run is a no-op. Originals are
     * NEVER deleted here — the flat memory/GLOBAL.md etc. stay on disk,
     * and whether to delete them after 30 days is the user's call.
     *
     * Layout history this migration must absorb (crosscheck-verdict §4):
     *   - flat memory/*.md (pre-isolation) → personas/default/
     *   - memory/<id>/*.md (the unshipped v1 layout, memory/<personaId>/)
     *     → personas/<id>/ — any dir directly under memory/ other than
     *     "personas" itself is treated as a v1 persona dir.
     *   - memory/personas/<id>/ (the runtime layout) is already correct:
     *     SOUL.md and history logs there are left exactly in place —
     *     nothing is moved or overwritten when the target already exists.
     *     In particular personas/default/ history logs stay the default
     *     persona, and personas/me/ (user profile) is never touched.
     *
     * The flag is set ONLY after the session list was read successfully:
     * if the database cannot be read, the migration returns without
     * setting the flag and retries on the next launch — otherwise old
     * sessions would silently resolve to their own (empty) persona dir
     * and lose their memory.
     */
    suspend fun migrateLegacyDataIfNeeded(context: Context, chatRepository: ChatRepository) {
        val prefs = prefs(context)
        if (prefs.getBoolean(KEY_MIGRATION_DONE, false)) return

        // 1. Read the pre-existing session ids FIRST: if this fails we
        // return without touching anything, so the next launch retries.
        val legacyIds = runCatching {
            chatRepository.querySessionsMeta(
                sessionIds = null, keywords = null, limit = Int.MAX_VALUE,
                startMs = null, endMs = null,
            ).map { it.id }
        }.getOrElse {
            AppLogger.warning(TAG, "persona migration: cannot list sessions (${it.message}) — will retry next launch")
            return
        }

        val filesDir = context.filesDir
        val root = File(filesDir, MEMORY_ROOT_SUBDIR)

        // 2. Memory + SOUL: copy flat files into memory/personas/default/.
        //    SOUL.md at the root is copied only when personas/default/
        //    has none — a SOUL already in place is never overwritten.
        val defaultDir = memoryDir(filesDir, DEFAULT_PERSONA_ID).apply { mkdirs() }
        root.listFiles()?.forEach { src ->
            if (src.isFile && src.extension == "md") {
                val dst = File(defaultDir, src.name)
                if (!dst.exists()) runCatching { src.copyTo(dst) }
            }
        }

        // 2a. v1 layout: memory/<personaId>/*.md → memory/personas/<personaId>/.
        root.listFiles()?.forEach { dir ->
            if (dir.isDirectory && dir.name != PERSONAS_SUBDIR) {
                val dstDir = memoryDir(filesDir, dir.name).apply { mkdirs() }
                dir.listFiles()?.forEach { src ->
                    if (src.isFile && src.extension == "md") {
                        val dst = File(dstDir, src.name)
                        if (!dst.exists()) runCatching { src.copyTo(dst) }
                    }
                }
            }
        }

        prefs.edit()
            .putStringSet(KEY_LEGACY_DEFAULT_SESSIONS, legacyIds.toSet())
            .putBoolean(KEY_MIGRATION_DONE, true)
            .apply()
        AppLogger.info(TAG, "persona migration done: ${legacyIds.size} legacy session(s) → default persona")
    }
}
