package com.openminis.app.scheduled

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
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

    // [persona] F3: the persona this task runs as. Stored value wins;
    // otherwise derive from the creator session, then the target session.
    // Android has no session→persona source yet (F4: no persona_id on
    // sessions, no PersonaStore), so the derivation chain ends at "default"
    // today — the creator/target session ids are still recorded on the task
    // so F4's backfill can resolve them to a real persona later. The
    // resolved value is stored back, so later reads see the same owner.
    fun ensurePersonaId(task: ScheduledTask): ScheduledTask {
        if (task.personaId != null) return task
        val stamped = task.copy(personaId = DEFAULT_PERSONA_ID)
        store.upsert(stamped)
        return stamped
    }

    /** Stamp every task that still has no persona. Called before a filtered
     * list is built and on boot, so no task is silently omitted from every
     * persona's list. */
    fun backfillMissingPersonaIds() {
        for (t in store.all()) {
            if (t.personaId == null) ensurePersonaId(t)
        }
    }

    /**
     * [persona] F3: throw when [task] belongs to a different persona than
     * the caller. A null caller persona means "no session context" — the
     * management view, same as the in-app task list — and enforcement is
     * skipped only then. Callers surface the exception as an explicit
     * cross-persona error, never a silent no-op.
     */
    fun requirePersona(task: ScheduledTask, callerPersonaId: String?) {
        if (callerPersonaId == null) return
        val owner = ensurePersonaId(task).personaId
        if (owner != callerPersonaId) {
            throw IllegalStateException(
                "task ${task.id} belongs to persona \"$owner\"; it cannot be changed from persona \"$callerPersonaId\"."
            )
        }
    }

    /**
     * [persona] F3: null [personaId] = the management view (in-app task
     * list, boot re-registration) — every task. A non-null personaId lists
     * only that persona's tasks; backfill runs first so a task with no
     * persona yet is owned before filtering, never silently omitted.
     */
    fun list(personaId: String? = null): List<ScheduledTask> {
        if (personaId == null) return store.all()
        backfillMissingPersonaIds()
        return store.all().filter { it.personaId == personaId }
    }

    fun get(taskId: String): ScheduledTask? = store.get(taskId)

    /** Persona-scoped lookup: null when missing OR owned by another persona. */
    fun get(taskId: String, personaId: String): ScheduledTask? {
        val t = store.get(taskId) ?: return null
        if (ensurePersonaId(t).personaId != personaId) return null
        return t
    }

    fun create(task: ScheduledTask): ScheduledTask {
        val stamped = ensurePersonaId(task)
        store.upsert(stamped)
        if (stamped.enabled) registerAlarm(stamped)
        return stamped
    }

    fun update(task: ScheduledTask): ScheduledTask {
        cancelAlarm(task.id)
        // [persona] F3: ownership survives an edit — changing a task's
        // timing or target does not move it to another persona.
        val stamped = ensurePersonaId(task)
        store.upsert(stamped)
        if (stamped.enabled) registerAlarm(stamped)
        return stamped
    }

    fun setEnabled(taskId: String, enabled: Boolean) {
        val t = store.get(taskId) ?: return
        val updated = t.copy(enabled = enabled)
        store.upsert(updated)
        if (enabled) registerAlarm(updated) else cancelAlarm(taskId)
    }

    /** Persona-scoped enable/disable: throws on a cross-persona task. */
    fun setEnabled(taskId: String, enabled: Boolean, personaId: String) {
        val t = store.get(taskId) ?: return
        requirePersona(t, personaId)
        val updated = t.copy(enabled = enabled)
        store.upsert(updated)
        if (enabled) registerAlarm(updated) else cancelAlarm(taskId)
    }

    fun delete(taskId: String) {
        cancelAlarm(taskId)
        store.delete(taskId)
    }

    /** Persona-scoped delete: throws on a cross-persona task. */
    fun delete(taskId: String, personaId: String) {
        val t = store.get(taskId) ?: return
        requirePersona(t, personaId)
        cancelAlarm(taskId)
        store.delete(taskId)
    }

    /**
     * Re-register every enabled task with AlarmManager. Called from
     * [com.openminis.app.offload.AlarmReceiver]'s BOOT_COMPLETED branch
     * so persisted tasks survive a device reboot.
     */
    fun rescheduleAll() {
        // [persona] F3: own every task before re-registering, so the
        // persisted rows carry their owner from the first boot after this
        // change.
        backfillMissingPersonaIds()
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
        /** [persona] F3: fallback owner when no session can be resolved to a
         * persona (no session context, or the session row is gone). Matches
         * iOS `PersonaStore.defaultPersonaID`. */
        const val DEFAULT_PERSONA_ID = "default"
    }
}
