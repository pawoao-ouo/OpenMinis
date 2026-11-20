package com.openminis.app.sandbox.offload

import android.content.Context
import com.openminis.app.data.PersonaStore
import com.openminis.app.logging.AppLogger
import com.openminis.app.sandbox.NativeOffloadHandler
import com.openminis.app.sandbox.NativeOffloadRequest
import com.openminis.app.sandbox.NativeOffloadResult
import com.openminis.app.scheduled.ScheduledRepeatMode
import com.openminis.app.scheduled.ScheduledTargetMode
import com.openminis.app.scheduled.ScheduledTask
import com.openminis.app.scheduled.ScheduledTaskManager
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

/**
 * [T-android-scheduled-tasks-full] minis-scheduled — CLI surface for the
 * Scheduled Tasks feature, exposing the same option set as the editor UI and
 * the iOS Shortcuts intents so the agent can create / inspect / fire timed
 * AI actions from a prompt.
 *
 *   minis-scheduled list
 *   minis-scheduled create --label L --time HH:MM --prompt "..."
 *                          [--repeat once|daily|weekdays|custom --days mon,tue,...]
 *                          [--target new|follow-up|rerun]
 *                          [--session <id>] [--message <id>]
 *                          [--model <modelId>]
 *                          [--start YYYY-MM-DD] [--end YYYY-MM-DD]
 *                          [--disabled]
 *   minis-scheduled delete --id <taskId>
 *   minis-scheduled enable  --id <taskId>
 *   minis-scheduled disable --id <taskId>
 *   minis-scheduled run     --id <taskId>     (fire immediately, off-schedule)
 *
 * Target modes mirror iOS App Intents:
 *   new        ≈ SendPrompt(no session)   — run prompt in a fresh chat
 *   follow-up  ≈ FollowUpSession           — append prompt to --session
 *   rerun      ≈ RetryRun                  — re-run --session from --message
 */
class ScheduledTaskOffloadHandler(private val context: Context) : NativeOffloadHandler {

    private val manager get() = ScheduledTaskManager(context)

    override fun handle(request: NativeOffloadRequest): NativeOffloadResult {
        val args = OffloadArgs(
            request.argv.drop(1),
            booleanFlags = setOf("disabled", "h", "help"),
        )
        // [T-offload-defaults-batch-android] Help only on explicit
        // --help/-h; no subcommand defaults to `list`.
        if (args.hasFlag("h", "help")) {
            return NativeOffloadResult(0, HELP)
        }
        return try {
            // Item 8: the caller persona resolves from the legacy set,
            // which the one-time migration writes at launch. Awaiting it
            // here (a no-op join after the first run) keeps every
            // subcommand — list, create, run — from acting as the wrong
            // persona in the launch window. runBlocking is safe on the
            // offload thread (handleRun already blocks here).
            runBlocking { PersonaStore.awaitMigration() }
            // Multi-persona isolation: the CLI runs inside the calling
            // chat's shell, so every subcommand is scoped to the caller
            // persona (resolved from request.sessionId). A task from one
            // persona can never list, run, delete, or toggle a task that
            // belongs to another persona — cross-persona access is an
            // explicit error, never a silent empty result.
            val personaId = callerPersonaId(request)
            when (val sub = args.positional.firstOrNull() ?: "list") {
                "list" -> handleList(personaId)
                "create", "add" -> handleCreate(args, personaId)
                "delete", "remove", "rm" -> handleDelete(args, personaId)
                "enable" -> handleSetEnabled(args, true, personaId)
                "disable" -> handleSetEnabled(args, false, personaId)
                "run" -> handleRun(args, personaId)
                else -> NativeOffloadResult(2, "minis-scheduled: unknown subcommand '$sub'\n$HELP")
            }
        } catch (e: IllegalStateException) {
            // Cross-persona access (manager.get scoped) — explicit denial,
            // exit 1 like any other failed operation.
            NativeOffloadResult(1, "minis-scheduled: cross-persona denied: ${e.message}")
        } catch (e: IllegalArgumentException) {
            NativeOffloadResult(2, "minis-scheduled: ${e.message}")
        } catch (e: Throwable) {
            AppLogger.warning(TAG, "handle failed: ${e.message}")
            NativeOffloadResult(1, "minis-scheduled: ${e.message}")
        }
    }

    /**
     * Persona the CLI acts as. The agent shell forwards
     * MINIS_CHAT_SESSION_ID as request.sessionId; the session resolves
     * to its persona (legacy session → "default", new session → itself,
     * task-created session → the creator's persona). Outside a chat
     * (interactive terminal, sessionId null) there is no creator
     * session, so the caller acts as the default persona — the persona
     * that owns the pre-migration shared history. Never "legacy" (an
     * empty dir with no SOUL) and never the offload-global permission
     * bucket id (OFFLOAD_GLOBAL_SESSION_ID is not a persona).
     */
    private fun callerPersonaId(request: NativeOffloadRequest): String {
        val sid = request.sessionId
        return if (sid != null) PersonaStore.personaIdForSession(context, sid)
        else PersonaStore.DEFAULT_PERSONA_ID
    }

    private fun handleList(personaId: String): NativeOffloadResult {
        val arr = JSONArray()
        for (t in manager.list(personaId)) arr.put(taskJson(t))
        val out = JSONObject().put("tasks", arr).put("count", arr.length())
        return NativeOffloadResult(0, out.toString(2))
    }

    private fun handleCreate(args: OffloadArgs, personaId: String): NativeOffloadResult {
        val label = args.get("label", "l") ?: ""
        val (hour, minute) = parseTime(args.get("time", "t")
            ?: throw IllegalArgumentException("--time HH:MM required"))
        val repeat = parseRepeat(args.get("repeat", "r"))
        val customDays = if (repeat == ScheduledRepeatMode.CUSTOM) {
            parseDays(args.get("days") ?: throw IllegalArgumentException("--days required for custom repeat"))
        } else emptySet()
        val target = parseTarget(args)
        // A follow-up/rerun target names a session: it must belong to
        // the caller's persona, otherwise persona B could schedule work
        // into persona A's chat. "new" has no session to check.
        target.sessionIdOrNull?.let { targetSid ->
            val targetPersona = PersonaStore.personaIdForSession(context, targetSid)
            if (targetPersona != personaId) {
                throw IllegalArgumentException(
                    "target session $targetSid belongs to another persona",
                )
            }
        }
        val prompt = args.get("prompt", "p") ?: ""
        if (target !is ScheduledTargetMode.RerunMessage && prompt.isBlank()) {
            throw IllegalArgumentException("--prompt required (except for rerun target)")
        }
        val task = ScheduledTask(
            label = label,
            timeOfDayHour = hour,
            timeOfDayMinute = minute,
            repeatMode = repeat,
            customDays = customDays,
            prompt = prompt,
            targetMode = target,
            modelId = args.get("model", "m"),
            enabled = !args.hasFlag("disabled"),
            startDateMs = args.get("start")?.let { parseDate(it) },
            endDateMs = args.get("end")?.let { parseDate(it) },
            // Stamp the creator's persona (manager.create keeps an
            // explicit personaId) — never "legacy": a task with no
            // persona would fire with no SOUL and empty memory.
            personaId = personaId,
            // Item 10: record the creator's session so the store backfill
            // (and any later healing) attributes this task to the creator's
            // persona even for NEW_SESSION targets. Null outside a chat.
            creatorSessionId = request.sessionId,
        )
        // manager.create is suspend (it awaits the persona migration
        // before stamping); the CLI thread blocks here like handleRun.
        runBlocking { manager.create(task) }
        val out = JSONObject().put("created", taskJson(task))
        return NativeOffloadResult(0, out.toString(2))
    }

    private fun handleDelete(args: OffloadArgs, personaId: String): NativeOffloadResult {
        val id = args.get("id") ?: throw IllegalArgumentException("--id required")
        // Scoped get: null = does not exist at all; throws
        // IllegalStateException when it exists under another persona.
        if (manager.get(id, personaId) == null) return NativeOffloadResult(1, "minis-scheduled: no task with id=$id")
        manager.delete(id, personaId)
        return NativeOffloadResult(0, JSONObject().put("deleted", id).toString())
    }

    private fun handleSetEnabled(args: OffloadArgs, enabled: Boolean, personaId: String): NativeOffloadResult {
        val id = args.get("id") ?: throw IllegalArgumentException("--id required")
        if (manager.get(id, personaId) == null) return NativeOffloadResult(1, "minis-scheduled: no task with id=$id")
        manager.setEnabled(id, enabled, personaId)
        return NativeOffloadResult(0, JSONObject().put("id", id).put("enabled", enabled).toString())
    }

    private fun handleRun(args: OffloadArgs, personaId: String): NativeOffloadResult {
        val id = args.get("id") ?: throw IllegalArgumentException("--id required")
        val task = manager.get(id, personaId) ?: return NativeOffloadResult(1, "minis-scheduled: no task with id=$id")
        // Fire immediately, off-schedule. Blocks until the agent loop finishes
        // (ScheduledAgentRunner waits internally). Mirrors the editor "Run now".
        // The task runs under its stored personaId (runner), which the
        // scoped get above has already proven is the caller's persona.
        val sessionId = runBlocking {
            com.openminis.app.scheduled.ScheduledAgentRunner.run(context, task)
        }
        val out = JSONObject()
            .put("id", id)
            .put("ran", sessionId != null)
            .apply { if (sessionId != null) put("sessionId", sessionId) }
        return NativeOffloadResult(if (sessionId != null) 0 else 1, out.toString(2))
    }

    // ── parsing helpers ──

    private fun parseTime(s: String): Pair<Int, Int> {
        val parts = s.split(":")
        require(parts.size == 2) { "--time must be HH:MM" }
        val h = parts[0].toIntOrNull()?.takeIf { it in 0..23 }
            ?: throw IllegalArgumentException("bad hour in --time")
        val m = parts[1].toIntOrNull()?.takeIf { it in 0..59 }
            ?: throw IllegalArgumentException("bad minute in --time")
        return h to m
    }

    private fun parseRepeat(s: String?): ScheduledRepeatMode = when (s?.lowercase()) {
        null, "once" -> ScheduledRepeatMode.ONCE
        "daily" -> ScheduledRepeatMode.DAILY
        "weekdays" -> ScheduledRepeatMode.WEEKDAYS
        "custom" -> ScheduledRepeatMode.CUSTOM
        else -> throw IllegalArgumentException("--repeat must be once|daily|weekdays|custom")
    }

    private fun parseDays(s: String): Set<Int> {
        val map = mapOf(
            "sun" to Calendar.SUNDAY, "mon" to Calendar.MONDAY, "tue" to Calendar.TUESDAY,
            "wed" to Calendar.WEDNESDAY, "thu" to Calendar.THURSDAY, "fri" to Calendar.FRIDAY,
            "sat" to Calendar.SATURDAY,
        )
        return s.split(",").mapNotNull { map[it.trim().lowercase().take(3)] }.toSet()
    }

    private fun parseTarget(args: OffloadArgs): ScheduledTargetMode {
        return when (args.get("target")?.lowercase() ?: "new") {
            "new" -> ScheduledTargetMode.NewSession
            "follow-up", "followup", "follow" -> {
                val sid = args.get("session", "s")
                    ?: throw IllegalArgumentException("--session required for follow-up target")
                ScheduledTargetMode.AppendToSession(sid)
            }
            "rerun", "re-run", "retry" -> {
                val sid = args.get("session", "s")
                    ?: throw IllegalArgumentException("--session required for rerun target")
                val mid = args.get("message")
                    ?: throw IllegalArgumentException("--message required for rerun target")
                ScheduledTargetMode.RerunMessage(sid, mid)
            }
            else -> throw IllegalArgumentException("--target must be new|follow-up|rerun")
        }
    }

    /** YYYY-MM-DD → local start-of-day epoch ms. */
    private fun parseDate(s: String): Long {
        val parts = s.split("-")
        require(parts.size == 3) { "--start/--end must be YYYY-MM-DD" }
        val y = parts[0].toInt(); val mo = parts[1].toInt(); val d = parts[2].toInt()
        return Calendar.getInstance().apply {
            clear(); set(y, mo - 1, d, 0, 0, 0)
        }.timeInMillis
    }

    private fun taskJson(t: ScheduledTask): JSONObject = JSONObject().apply {
        put("id", t.id)
        put("label", t.label)
        put("time", "%02d:%02d".format(t.timeOfDayHour, t.timeOfDayMinute))
        put("repeat", t.repeatMode.name.lowercase())
        if (t.customDays.isNotEmpty()) put("days", JSONArray(t.customDays.toList()))
        put("prompt", t.prompt)
        put("target", t.targetMode.encode())
        if (t.modelId != null) put("model", t.modelId)
        put("enabled", t.enabled)
        t.nextTriggerMs()?.let { put("nextTriggerMs", it) }
        if (t.startDateMs != null) put("startDateMs", t.startDateMs)
        if (t.endDateMs != null) put("endDateMs", t.endDateMs)
        if (t.lastFiredAt != null) put("lastFiredAt", t.lastFiredAt)
        if (t.lastResultPreview != null) put("lastResultPreview", t.lastResultPreview)
        if (t.lastResultSessionId != null) put("lastResultSessionId", t.lastResultSessionId)
        put("persona", t.personaId ?: PersonaStore.DEFAULT_PERSONA_ID)
    }

    companion object {
        private const val TAG = "ScheduledTaskOffload"
        private val HELP = """
            minis-scheduled — manage timed AI tasks (mirrors the in-app Scheduled Tasks).

            (no subcommand)  Same as `list` (default subcommand)
            list
            create --time HH:MM --prompt "..." [--label L]
                   [--repeat once|daily|weekdays|custom --days mon,tue,...]
                   [--target new|follow-up|rerun --session <id> --message <id>]
                   [--model <modelId>] [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--disabled]
            delete  --id <taskId>
            enable  --id <taskId>
            disable --id <taskId>
            run     --id <taskId>          fire immediately, off-schedule

            Target modes: new = run prompt in a fresh chat; follow-up = append prompt
            to an existing chat (--session); rerun = re-run a chat (--session) from a
            chosen user message (--message, prompt ignored).

            Persona scoping: every subcommand runs as the calling chat's
            persona (from MINIS_CHAT_SESSION_ID; outside a chat, the
            default persona). list shows only that persona's tasks; create
            stamps the new task to it and rejects a --session that belongs
            to another persona; delete/enable/disable/run on another
            persona's task fail with an explicit cross-persona error.
        """.trimIndent()
    }
}
