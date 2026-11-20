package com.openminis.app.scheduled

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import com.openminis.app.data.PersonaStore
import com.openminis.app.logging.AppLogger

/**
 * [T-android-scheduled-tasks-design] Schedules / cancels AlarmManager
 * entries for [ScheduledTask] rows held in [ScheduledTaskStore]. Pairs with
 * [ScheduledTaskAlarmReceiver] which fires on the trigger and hands the
 * task off to [ScheduledAgentRunner].
 *
 * Repeating tasks (DAILY / WEEKDAYS / CUSTOM) are NOT scheduled via
 * AlarmManager.setRepeating — that primitive is inexact on Android 19+
 * and Doze makes it worse. Instead the receiver re-schedules the next
 * occurrence after every fire, giving Doze-tolerant precision.
 */
class ScheduledTaskManager(private val context: Context) {

    private val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
    private val store = ScheduledTaskStore(context)

    init { ensureNotificationChannel() }

    /** Read-only access to persistence for callers that only need data. */
    fun store(): ScheduledTaskStore = store

    fun list(personaId: String? = null): List<ScheduledTask> =
        if (personaId == null) store.all() else store.allForPersona(personaId)

    fun get(taskId: String): ScheduledTask? = store.get(taskId)

    /**
     * Persona-scoped get: returns the task only when it belongs to
     * [personaId]. Throws [IllegalStateException] when the task exists
     * under a DIFFERENT persona — a cross-persona read is an explicit
     * error, never a silent empty result. Returns null only when the
     * task does not exist at all.
     */
    fun get(taskId: String, personaId: String): ScheduledTask? {
        val task = store.get(taskId) ?: return null
        if ((task.personaId ?: PersonaStore.LEGACY_PERSONA_ID) != personaId) {
            throw IllegalStateException(
                "task $taskId belongs to another persona",
            )
        }
        return task
    }

    /**
     * Stamp the persona a task runs under when it has none: the target
     * session's persona for APPEND_TO/RERUN, "legacy" for NEW_SESSION
     * (no creator session in scope at the global editor — the task
     * runs under legacy memory, never under another persona).
     */
    private fun stampPersona(task: ScheduledTask): ScheduledTask {
        if (task.personaId != null) return task
        val targetSessionId = task.targetMode.sessionIdOrNull
        val personaId = targetSessionId
            ?.let { PersonaStore.personaIdForSession(context, it) }
            ?: PersonaStore.LEGACY_PERSONA_ID
        return task.copy(personaId = personaId)
    }

    fun create(task: ScheduledTask): ScheduledTask {
        val stamped = stampPersona(task)
        store.upsert(stamped)
        if (stamped.enabled) registerAlarm(stamped)
        return stamped
    }

    fun update(task: ScheduledTask): ScheduledTask {
        val stamped = stampPersona(task)
        cancelAlarm(stamped.id)
        store.upsert(stamped)
        if (stamped.enabled) registerAlarm(stamped)
        return stamped
    }

    fun setEnabled(taskId: String, enabled: Boolean) {
        setEnabled(taskId, enabled, personaId = null)
    }

    fun setEnabled(taskId: String, enabled: Boolean, personaId: String?) {
        val t = if (personaId == null) store.get(taskId) else get(taskId, personaId)
            ?: return
        val updated = t.copy(enabled = enabled)
        store.upsert(updated)
        if (enabled) registerAlarm(updated) else cancelAlarm(taskId)
    }

    fun delete(taskId: String) {
        delete(taskId, personaId = null)
    }

    fun delete(taskId: String, personaId: String?) {
        if (personaId != null) get(taskId, personaId) // throws on cross-persona
        cancelAlarm(taskId)
        store.delete(taskId)
    }

    /**
     * Re-register every enabled task with AlarmManager. Called from
     * [com.openminis.app.offload.AlarmReceiver]'s BOOT_COMPLETED branch
     * so persisted tasks survive a device reboot.
     */
    fun rescheduleAll() {
        val tasks = store.all()
        if (tasks.isEmpty()) {
            AppLogger.info(TAG, "rescheduleAll: no tasks")
            return
        }
        var count = 0
        for (t in tasks) {
            if (!t.enabled) continue
            registerAlarm(t)
            count++
        }
        AppLogger.info(TAG, "rescheduleAll: re-registered $count enabled task(s)")
    }

    /**
     * Called by the receiver after firing — for repeating tasks, schedule
     * the next occurrence. ONCE tasks get disabled in-place (enabled=false)
     * so they linger in the list with their lastResult* metadata visible.
     */
    fun rescheduleNext(taskId: String) {
        val t = store.get(taskId) ?: return
        if (t.repeatMode == ScheduledRepeatMode.ONCE) {
            // Mark fired ONCE task as disabled — keep row so the user can
            // see its last result, re-enable if they want to re-run.
            store.upsert(t.copy(enabled = false))
            return
        }
        registerAlarm(t)
    }

    fun markFired(taskId: String, sessionId: String?, resultPreview: String?, ok: Boolean = true) {
        val t = store.get(taskId) ?: return
        val now = System.currentTimeMillis()
        // [T-android-scheduled-tasks-run-records] Prepend a run record
        // (newest-first), capped at MAX_RUN_HISTORY. lastResult* are kept in
        // sync for back-compat but are no longer surfaced in the list UI.
        val run = ScheduledRun(firedAt = now, sessionId = sessionId, preview = resultPreview, ok = ok)
        val history = (listOf(run) + t.runHistory).take(ScheduledTask.MAX_RUN_HISTORY)
        store.upsert(
            t.copy(
                lastFiredAt = now,
                lastResultPreview = resultPreview,
                lastResultSessionId = sessionId,
                runHistory = history,
            ),
        )
    }

    private fun registerAlarm(task: ScheduledTask) {
        val triggerAt = task.nextTriggerMs() ?: run {
            AppLogger.warning(TAG, "task ${task.id} has no next trigger — skipping register")
            return
        }
        val pi = buildPendingIntent(task.id)
        try {
            alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
            AppLogger.info(TAG, "registered task=${task.id} label=\"${task.label}\" triggerAt=$triggerAt")
        } catch (e: SecurityException) {
            // S+ users may have revoked SCHEDULE_EXACT_ALARM — fall back
            // to inexact so we still fire eventually rather than dropping.
            AppLogger.warning(
                TAG,
                "exact-alarm denied for task=${task.id} (${e.message}); falling back to inexact",
            )
            try {
                alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
            } catch (t2: Throwable) {
                AppLogger.error(TAG, "inexact fallback failed for task=${task.id}: ${t2.message}")
            }
        }
    }

    private fun cancelAlarm(taskId: String) {
        val pi = buildPendingIntent(taskId)
        alarmManager.cancel(pi)
        pi.cancel()
    }

    private fun buildPendingIntent(taskId: String): PendingIntent {
        val intent = Intent(context, ScheduledTaskAlarmReceiver::class.java).apply {
            action = ACTION_FIRE
            putExtra(EXTRA_TASK_ID, taskId)
        }
        val requestCode = taskId.hashCode() and 0x7FFFFFFF
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(context, requestCode, intent, flags)
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "Posts when a scheduled task finishes running."
        }
        nm.createNotificationChannel(channel)
    }

    companion object {
        private const val TAG = "ScheduledTaskManager"
        const val ACTION_FIRE = "com.openminis.app.scheduled.FIRE"
        const val EXTRA_TASK_ID = "task_id"
        const val CHANNEL_ID = "minis_scheduled_tasks"
        private const val CHANNEL_NAME = "Scheduled Tasks"
    }
}
