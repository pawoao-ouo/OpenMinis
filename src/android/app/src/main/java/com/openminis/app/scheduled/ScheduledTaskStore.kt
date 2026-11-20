package com.openminis.app.scheduled

import android.content.Context
import com.openminis.app.data.PersonaStore
import com.openminis.app.logging.AppLogger
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import org.json.JSONArray

/**
 * [T-android-scheduled-tasks-design] SharedPreferences-backed JSON array of
 * [ScheduledTask] rows. Same pattern as [com.openminis.app.offload.AlarmOffloadManager]
 * — small dataset, low write frequency, no Room migration cost.
 *
 * Multi-persona isolation (crosscheck-verdict §3): every task carries a
 * personaId; [allForPersona] / [getForPersona] are the persona-scoped
 * read paths. The global list screen still uses [all] (management
 * surface, no current persona in scope) — per-persona enforcement
 * lives in get/delete/setEnabled/run when a persona is in scope.
 */
class ScheduledTaskStore(private val context: Context) {

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun all(): List<ScheduledTask> {
        migratePersonasIfNeeded()
        return loadRaw()
    }

    /** Tasks that run under [personaId]. Pre-migration rows (null
     *  personaId, only possible while the migration is deferred) read
     *  as the legacy persona. */
    fun allForPersona(personaId: String): List<ScheduledTask> =
        all().filter { (it.personaId ?: PersonaStore.LEGACY_PERSONA_ID) == personaId }

    fun get(taskId: String): ScheduledTask? = all().firstOrNull { it.id == taskId }

    /** The task only when it belongs to [personaId]; null otherwise —
     *  the caller (manager) turns the null into a cross-persona error
     *  instead of silently returning a task from another persona. */
    fun getForPersona(taskId: String, personaId: String): ScheduledTask? =
        get(taskId)?.takeIf { (it.personaId ?: PersonaStore.LEGACY_PERSONA_ID) == personaId }

    private fun loadRaw(): List<ScheduledTask> {
        val raw = prefs.getString(KEY_TASKS, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            buildList {
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    runCatching { ScheduledTask.fromJson(o) }
                        .onSuccess { add(it) }
                        .onFailure { AppLogger.warning(TAG, "skip malformed row: ${it.message}") }
                }
            }
        } catch (t: Throwable) {
            AppLogger.warning(TAG, "load failed: ${t.message}")
            emptyList()
        }
    }

    fun upsert(task: ScheduledTask) {
        val current = all().filter { it.id != task.id }
        write(current + task)
    }

    fun delete(taskId: String) {
        write(all().filter { it.id != taskId })
    }

    fun clear() {
        prefs.edit().remove(KEY_TASKS).apply()
    }

    private fun write(tasks: List<ScheduledTask>) {
        val arr = JSONArray()
        for (t in tasks) arr.put(t.toJson())
        prefs.edit().putString(KEY_TASKS, arr.toString()).apply()
    }

    /**
     * Cold flow that emits the current task list whenever the prefs file
     * changes. Used by [ScheduledTasksViewModel] to keep the list screen
     * live.
     */
    fun observe(): Flow<List<ScheduledTask>> = callbackFlow {
        trySend(all())
        val listener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == KEY_TASKS || key == null) {
                trySend(all())
            }
        }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        awaitClose { prefs.unregisterOnSharedPreferenceChangeListener(listener) }
    }

    /**
     * One-time backfill of personaId for pre-isolation tasks. Flag-gated
     * and idempotent (re-running rewrites only rows still missing it).
     *
     * Attribution uses the only signal the Android store ever recorded:
     * the target session — `targetMode.sessionIdOrNull`, resolved through
     * PersonaStore.personaIdForSession (legacy session → "default", new
     * session → itself). A NEW_SESSION task has no target session, so it
     * goes to the legacy persona.
     *
     * DEFERRED until the PersonaStore migration is done: backfilling
     * before that would resolve a legacy session id to itself (a new,
     * empty persona) instead of "default" (the migrated memory). While
     * deferred the flag stays unset and the next all() retries.
     */
    private fun migratePersonasIfNeeded() {
        if (prefs.getBoolean(KEY_PERSONA_MIGRATION_DONE, false)) return
        if (!PersonaStore.isMigrationDone(context)) return
        val tasks = loadRaw()
        if (tasks.none { it.personaId == null }) {
            prefs.edit().putBoolean(KEY_PERSONA_MIGRATION_DONE, true).apply()
            return
        }
        val migrated = tasks.map { task ->
            if (task.personaId != null) task
            else {
                val targetSessionId = task.targetMode.sessionIdOrNull
                val personaId = targetSessionId
                    ?.let { PersonaStore.personaIdForSession(context, it) }
                    ?: PersonaStore.LEGACY_PERSONA_ID
                task.copy(personaId = personaId)
            }
        }
        write(migrated)
        prefs.edit().putBoolean(KEY_PERSONA_MIGRATION_DONE, true).apply()
        AppLogger.info(TAG, "scheduled-task persona migration done: ${migrated.size} task(s)")
    }

    companion object {
        private const val TAG = "ScheduledTaskStore"
        private const val PREFS_NAME = "minis_scheduled_tasks_prefs"
        private const val KEY_TASKS = "tasks_json"
        private const val KEY_PERSONA_MIGRATION_DONE = "persona_migration_completed_v1"
    }
}
