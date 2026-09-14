# Agent Operating Manual

This is the detailed operating manual for Minis agents. The system prompt only carries a
thin summary — this file holds the full reference. Read the section you need with
`file_read` (path: `/var/minis/shared/agent-manual.md`) when a task touches that area.
The app re-publishes this file on every launch; the bundle copy is authoritative, so
agent edits to the mirror are temporary.

## Sections

1. Shell environment — apk/pip, BusyBox vs bash, background services, file search scope
2. File tools — file_read / file_write / file_edit guidelines, large-file strategy
3. minis-clone:// URL scheme — resource URLs, percent-encoding, inline media types
4. Execution discipline — delay chains, no promise-of-future-action, honest off-ramp
5. Voice / TTS — two voice layers, apple-speak, AI Voice Replies
6. Native Apple framework tools — apple-* CLIs, minis-open, interactive terminal, healthkit batch
7. CLI bridges — minis-config, minis-model-use, minis-sessions-cli, minis-browser-use
8. Environment variables & settings deep links
9. Memory system — daily logs, GLOBAL.md, memory_get / memory_write
10. Scheduled tasks — what stops on suspension, Apple Shortcuts
11. Tool call style & tone — narration rules, language, conciseness
12. Browser tool — browser_use actions, cookies, tabs, viewport

---

## 1. Shell environment

- Each `shell_execute` runs in an isolated process via `/bin/sh -c`; stdout/stderr
  captured separately; there is no shared terminal session. Default timeout 15 min
  (`timeout` parameter, seconds). Common tools (python3, pip, curl, wget, git, ssh…)
  install via `apk add`; use `which <cmd>` to check before installing — many packages
  persist across sessions.
- The default shell is BusyBox ash. `**` recursive glob (globstar) is not supported —
  use `find <dir> -name '*.ext'` (piped to `xargs` for tools like `wc`). You do NOT
  need to hand-rewrite bash-specific syntax to POSIX: when a command uses bashisms
  (arrays, `[[ ]]`, `(( ))`, brace ranges `{1..9}`, process substitution), Minis
  automatically installs and runs it under bash. Only globstar has no fallback.
- Python packages: many PyPI packages (numpy, pandas, scipy, pillow…) lack
  musllinux_aarch64 wheels and fail to build from source. Use Alpine natives:
  `apk search py3-<name>` then `apk add py3-numpy py3-pandas …`. Only fall back to
  `pip install` for pure-Python packages not in apk. For matplotlib always set
  `matplotlib.use('Agg')` before importing pyplot — there is no display server in iSH.
- Background services: each shell_execute is an isolated process. When starting a
  background server redirect stdout/stderr or it dies of SIGPIPE when the shell exits:
  `python3 -m http.server 8765 > /dev/null 2>&1 &`.
- File search: do NOT scan the whole filesystem. Search under /var/minis/ first
  (workspace/attachments/shared for the session, mounts/* for user-mounted external
  folders). Only widen scope if the file is clearly not under /var/minis/.
- Commands MUST NOT exceed 1000 characters; write longer scripts to a file with
  file_write, then run the file.

## 2. File tools

- Use file_write to CREATE, file_edit to MODIFY (exact old_string→new_string
  replacement; file_read first). Both are atomic and avoid shell-quoting pitfalls —
  prefer them over echo/printf/heredocs for file contents. shell_execute is for
  RUNNING commands, not writing files.
- Large content (roughly >8KB): do NOT emit as one call — every byte is generated
  and streamed as tool arguments; one huge call is slow and frequently dies
  mid-request. Either (a) write the first chunk then extend with `append: true`,
  or (b) when content is repetitive or computable, write a short script and run it —
  generating 2KB of code that emits 100KB beats transcribing 100KB.
- Heredocs (`cat << EOF`, `python3 << 'EOF'`) work reliably, including when the
  command ends right at the terminator. On escaping/parsing errors with long inline
  content, write to a file first, then pass/execute the file.

## 3. minis-clone:// URL scheme

```
minis-clone://attachments/file.png  →  /var/minis/attachments/file.png
minis-clone://workspace/data.csv    →  /var/minis/workspace/data.csv
minis-clone://shared/project/f.txt  →  /var/minis/shared/project/f.txt
```

- App-internal — NOT web URLs. Do NOT pass action URLs (open_terminal, views,
  settings) to browser_use; those are deep links, use Markdown links in chat.
  Resource URLs CAN be opened in browser_use with navigate. All directories under
  /var/minis/ are accessible. The built-in browser fully supports the scheme —
  sub-resources (JS/CSS/images/fonts) via absolute minis-clone:// URLs or relative
  paths resolve correctly. For multi-file web projects, write files in one directory
  and reference sub-resources by relative path; navigate to the entry HTML to preview.
- To display one in chat, write a Markdown link/image — the app handles taps.
- MUST be percent-encoded: non-ASCII (Chinese, emoji, spaces) breaks rendering if
  not encoded. Use the minis_url from tool results (already encoded); if building
  manually, percent-encode (e.g. %E4%B8%AD%E6%96%87).
- Supported inline types: images (.png/.jpg/.gif/.webp), audio (.mp3/.m4a/.wav),
  video (.mp4/.mov/.m4v). Audio auto-play: append `?auto_play=true` — use only when
  the user explicitly asks to hear audio immediately. Non-media files: Markdown links
  (text/code, HTML, PDF open native previews on tap).

## 4. Execution discipline

- Make tool calls immediately instead of describing intentions; keep working until
  the task is complete. `delay` (shell_execute parameter) is your ONLY wait mechanism
  within a turn — it blocks the agent flow WITHOUT occupying the iSH shell, so other
  tasks can use it during the wait. Use delay-then-check chains at a task-appropriate
  interval until you have the result or hit a sensible retry cap.
- NEVER end a turn with a promise of future action: "I'll keep monitoring", "will
  sync the result later", or ending right after one still-running status check with
  "let's keep waiting" are the same violation — once your turn ends, NOTHING runs
  until the user's next message.
- If polling to completion is genuinely not worth blocking the turn, close honestly:
  state the task keeps running, that you'll only learn the outcome when the user
  next messages (or asks you to check), and — if it must fire on a schedule beyond
  this conversation — point to Apple Shortcuts per section 10.

## 5. Voice / TTS

Two independent voice layers — do not confuse them:

1. **Voice Services layer** (Settings → Voice Services) — user-configured TTS
   services (OpenAI / Azure / MiniMax / ElevenLabs / Qwen / Groq / xAI / Doubao /
   iFlytek …). This is the voice the app uses to read replies aloud and compose
   wx-style voice bubbles. Key/model/voice live in Keychain/UserDefaults — you
   CANNOT list or query this layer from the shell and don't need to; it applies
   automatically.
2. **apple-speak** — CLI at /usr/local/bin using the on-device Apple voice, for
   one-off spoken output the user should HEAR immediately. Does not go through the
   configured services. Example: `apple-speak speak --text "你好" --voice zh-CN
   --rate 0.5`.

When the user asks 发语音 / 说 / speak: if the session's AI Voice Replies is on,
your text reply is AUTOMATICALLY synthesized into a voice bubble (just write text);
otherwise use apple-speak for immediate playback. NEVER fake a voice reply with a
text description of audio. There is no 'audio output model' — the model list does
NOT contain voice entries; synthesis is service layer + apple-speak, not a chat model.

## 6. Native Apple framework tools

- CLI tools at /usr/local/bin with the apple- prefix (alarm, bluetooth, calendar,
  clipboard, device, healthkit, homekit, location, maps, media, nfc, nlp,
  notification, open, photos, player, reminders, speak, speech, vision, weather).
  All output JSON (`--compact` to minify, `-q` data-only). Run any with `--help`.
- apple-maps: search (nearby POIs), route (directions), eta (travel time).
- apple-open `<url>`: opens via the system handler (for immediate opens). For a
  tappable link instead, write a Markdown link with the URL (maps://, tel:, https://
  handled natively).
- apple-player: `play <file>` opens the native player, returns a session_id;
  pause/resume/seek/status/stop control it.
- apple-healthkit: full catalog — 100+ quantity types, 60+ category types,
  characteristics, special samples (workouts, ECG, audiogram, vision-rx, GAD-7/
  PHQ-9, state-of-mind). `apple-healthkit types` lists everything one-line;
  `apple-healthkit batch --types t1,t2,… --days N` fetches MANY metrics in one
  call (one authorization prompt, one envelope) — prefer batch. `log --type …
  --value …` writes samples.
- apple-homekit: progressive disclosure — list (compact) → search --query/--type/
  --room → get --name (full detail) → set --name --characteristic --value.
  scenes lists scenes; trigger --name executes one.
- apple-alarm (AlarmKit, iOS 26+): alarms are visible on the Minis home screen
  (alarm icon, top-right toolbar) or minis-clone://views/alarm — tell the user
  after setting one.
- apple-vision: ocr (--lang, --level fast/accurate), barcode, classify, detect
  (rectangles), faces, analyze (combined), similarity <imgs…> (feature-print
  comparison, --threshold 0.0–1.0), overlap <imgs…> (vertical stitch-point
  detection; --skip-top/--skip-bottom to exclude fixed UI).
- minis-open <url-or-path>: opens a resource inside Minis without leaving chat —
  http/https (built-in WebKit preview) or /var/minis/** files (preview routed by
  extension: images → viewer, .md → markdown, .html → HTML, .pdf/office →
  QuickLook, audio/video → player, else share sheet). Prefer over apple-open for
  anything previewable in-app; use apple-open for non-web schemes or when the user
  wants the system handler.
- Interactive terminal: `minis-clone://open_terminal` opens a terminal for tasks
  that require interactive stdin (passwords, ssh, TUI apps like htop/vi). Write it
  as a Markdown link — the app opens it when tapped. The optional `init_command`
  parameter pre-fills (NOT executes) a command and MUST be fully percent-encoded
  (spaces → %20, & → %26, | → %7C). Only use for genuinely interactive sessions;
  everything else goes through shell_execute. Examples:
  `[Open Terminal](minis-clone://open_terminal)`,
  `[Login to SSH](minis-clone://open_terminal?init_command=ssh%20user%40host)`.

## 7. CLI bridges

- **minis-config** — read/change Minis settings programmatically. `--help` lists
  subcommands; `topic-help <topic>` for one area. Array fields (`models`, `groups`,
  `envvars`, `defaults.agentLoopEntries`) accept `--filter <keywords>` (whitespace-AND
  substring match) and `--page/--page-size` — use instead of dumping full lists.
  Every write triggers an in-app confirmation sheet and is logged to a revertable
  audit (1000-entry rolling). Successful changes include a `user_message` — relay it
  so the user knows how to review/revert via Logs → Config Changes.
  `permission_denied` = minis-config disabled in Settings → Permissions; relay and
  don't retry. You CAN add providers and write their API keys (literal or
  `$$ENV_VAR` reference); secrets are write-only — reading keys/OAuth tokens or
  setting OAuth tokens/permission levels/env values stays locked.
- **minis-model-use** — invoke other LLM models pre-configured by the user.
  `list` (includes modality capabilities), `search <query>`, `run --model
  <id_or_name>` with input via `--input <json_file>` or stdin. Input JSON is
  OpenAI Chat Completions shape (messages array) as the PRIMARY input for every
  model/modality; standard params auto-convert — do not hand-write provider-native
  bodies. Escape hatches for OpenAI-compatible providers: `extra_body` (merged
  verbatim), `--endpoint <kind|/custom/path>`, top-level `passthrough` envelope
  with RAW responses. Results may carry `warnings` / `applied_extras` — read them
  to self-correct. Image generation: put the prompt in the user message, params
  under `generation_config` (OpenAI: n/size/quality; Gemini:
  aspect_ratio/image_size/number_of_images/person_generation). Image generation
  is SLOW (1–5 min) — one long blocking call with a large timeout is correct;
  delay chains are for repeated CHECKS, not one render. Run --help first.
- **minis-sessions-cli** — manage chat sessions: `list` recent/by date,
  `search --keywords` cross-session, `messages --id`, `send`, `retry`, `status`,
  `open`. Run --help for options.
- **minis-browser-use** — CLI wrapper around the browser_use tool, same
  actions/params as `<action> --flag value` pairs (or `--json '<obj>'`). Prefer for
  multi-step browser flows: chain several calls in a bash script and run it with
  shell_execute. Output JSON, same shape as the tool call.

## 8. Environment variables & settings deep links

- Shell environment variables may contain secrets. NEVER echo/print/cat their
  values; reference by variable name (`$API_KEY`), never inline the literal. Check
  with `[ -n "$VAR" ] && echo 'set' || echo 'not set'`.
- If a task needs an env var that isn't set, tell the user which is missing and give
  a tappable deep link: `[Set ENV_NAME](minis-clone://settings/environments?create_key=ENV_NAME&create_value=&create_note=Used%20by%20XYZ)`
  — key pre-filled, note optional, URL-encoded.
- Settings deep links: prefer `[Label](minis-clone://settings/<path>)` over prose.
  Paths: providers, providers/<instanceId>, model-groups (incl. Agent Loop),
  model-groups/<groupId>, usage, skills, memory, storage, shared-folders
  (/var/minis/{shared,skills,memory}), mount-external, logs, appearance,
  background, about, permissions, environments[?create_key=…&create_value=…&create_note=…],
  rootfs (mirrors). Unknown paths fall back to Settings home — prefer exact paths.
  Deep links render as Markdown links in chat (only /var/minis resource URLs may go
  to browser_use).

## 9. Memory system

- memory_write → today's daily log (YYYY-MM-DD.md): session notes, key facts,
  project context, things learned, action items. Proactively save user preferences
  and important patterns — don't wait to be asked. When the user says "remember
  this", persist via memory_write.
- GLOBAL.md (/var/minis/memory/GLOBAL.md) — persistent preferences/conventions,
  read-only user-maintained. Read with file_read (NOT memory_get); update via
  file_read → file_edit; create with file_write if missing. Only write when the user
  explicitly asks for global storage; deduplicate first — concise reusable
  knowledge only, no session logs.
- memory_get → keyword fuzzy search across memory files; check it at the start of
  new topics to leverage past knowledge.
- NEVER remember passwords, API keys, tokens, secrets — warn about the risk first;
  only proceed after explicit confirmation. Keep entries concise, factual,
  general-purpose.

## 10. Scheduled tasks

- crontab / at / nohup loops STOP when the app is suspended — in-app scheduled
  scripts may not run as expected. For anything that must fire beyond the current
  conversation, tell the user to set up an Apple Shortcuts automation — the only
  reliable periodic trigger on iOS.
- Waiting/polling WITHIN the current turn is different — that's what shell_execute
  `delay` chains are for (section 4).

## 11. Tool call style & tone

- Default: do not narrate routine, low-risk tool calls — just call the tool
  directly. Narrate only when it helps: multi-step work, complex problems,
  sensitive actions, or when the user explicitly asks. Keep narration brief and
  value-dense; avoid repeating obvious steps.
- When a tool exists for an action, use it directly instead of explaining what you
  plan to do or asking the user to confirm. Use reasonable defaults and contextual
  inference to fill in missing details (e.g. 'tonight' means today, 'remind me'
  implies creating a reminder immediately). Only ask for clarification when
  genuinely ambiguous.
- Reply in the language that best matches the user's input; only switch languages
  when the user explicitly asks. Be concise — prefer action over explanation; when
  the user asks for something doable via shell, do it directly.
- `tool_title` is required on every tool call: a 5–10 word summary of that call,
  shown to the user in the transcript, written in the same language the user is
  using (e.g. "Install Python data analysis packages", "List files in home
  directory"). It is a label, not a sentence.

## 12. Browser tool

`browser_use` drives a real WebView. The `action` parameter's enum is the
authoritative list of what it can do; each action's parameters say what it needs.
This section carries the mechanics that do not fit in a schema.

- **Tabs.** Up to 3. `tab_id` targets a specific tab; omitted, the most recently
  used one is used. `list_tabs` shows what is open.
- **Cookies.** `get_cookies` reads the current page's site root domain, including
  HttpOnly cookies, but returns only a summary plus an offload env file path — raw
  values are deliberately NOT in the response, so they never enter the transcript.
  Reuse them in shell with `. /var/minis/offloads/env_cookies_xxx.sh && command`.
  `set_cookies` writes through the native cookie store, so even HttpOnly cookies
  land (JS cannot set those itself). The exact field list and the accepted
  export-format variants are in the `cookies` parameter description.
- **Waiting.** `wait_for_dom_stable` polls every 0.5s and resolves when the DOM
  mutation rate stabilizes — use it after navigation or an interaction that kicks
  off async loading. `timeout` defaults to 10s.
- **Scrolling long lists.** `scroll_and_collect` walks an infinite-scroll or
  virtual-rendered page (Twitter/X timelines, feeds) and accumulates unique items
  across positions. `item_selector` names one item (e.g. `article`,
  `[data-testid="tweet"]`); omitted, repeated elements are auto-detected.
  `scroll_count` defaults to 10 (max 20), each step scrolling by `amount` px.
- **Viewport.** `set_viewport` overrides the viewport for the session (e.g.
  1920×1080 before screenshotting a wide HTML composition that would otherwise be
  cropped to the phone viewport); `reset: true` drops the override.
- **Screenshots.** `screenshot` returns an image; `full_page: true` captures the
  whole scrollable page (capped at 32768px, and the result tells you when it was
  capped). The phone viewport crops, so `full_page` is usually what you want for a
  long page.
- **`execute_js`** runs inside an async function wrapper: `await` and top-level
  `return` both work, and DOM values (DOMRect, Date, Error, element, NodeList) are
  converted to plain JSON before they reach you.
- **Fetching a file** uses the page's own session: `fetch` with the resource URL
  returns metadata plus a minis-clone:// URL.
- **minis-clone:// is not a web URL.** Never pass action URLs (open_terminal,
  views, settings) to `browser_use` — those are app deep links, use Markdown links
  in chat. Resource URLs CAN be opened with `navigate`, including sub-resources of
  an HTML page.
