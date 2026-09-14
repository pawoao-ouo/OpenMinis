import Foundation

// MARK: - Tool Definitions (Canonical)

extension AIChatViewModel {

    /// [T-ios-vision-branch-mismatch #182] THE single source of truth for
    /// "can the model that will actually receive this turn see images itself".
    ///
    /// Both the `read_image` registration (which picks the tool DESCRIPTION) and
    /// its handler (which picks pixels-vs-Vision-Group) must agree, or the model
    /// is told one thing and handed another. They previously each wrote
    /// `selectedModel.capabilities.supportedModalities.contains(.imageInput)` —
    /// textually identical, yet wrong: `selectedModel` is the @Published UI
    /// property, while the REQUEST is built from `resolveCurrentEntry()` (see
    /// `activeModel` in runAgentLoop). With group routing or a session binding
    /// those are different models, so a text-only model could be registered with
    /// the Vision Group tool description and then served by the native pixel
    /// branch — returning metadata and no description at all.
    ///
    /// Resolve from the same entry the request uses, and fall back to
    /// `selectedModel` only when that resolution fails.
    var activeModelHasNativeVision: Bool {
        let model = resolveCurrentEntry()?.model ?? selectedModel
        return model.capabilities.supportedModalities.contains(.imageInput)
    }

    // MARK: - Tool Definitions (Canonical)

    func makeAgentTools() -> [AgentToolDefinition] {
        // [T-memory-toggle-gates-injection-and-tools-ios] memory_get and
        // memory_write are conditionally registered. When the per-session
        // toggle is off, drop both tool definitions so the LLM never sees
        // them. The system prompt also switches to a "memory disabled"
        // wording (see baseSystemPrompt below) so the model can correctly
        // tell the user to re-enable memory via /memory or Settings.
        let includeMemoryTools = memoryEnabled
        var tools: [AgentToolDefinition] = [
            AgentToolDefinition(
                name: "shell_execute",
                description: "Execute a shell command in an isolated Linux process (iSH/Alpine Linux). Each invocation is a fresh process — no shared terminal session. Default timeout 15 min. Shell quirks and package installs: manual section 1.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "5-10 word summary of this call, shown to the user; same language as the user."),
                    "command": AgentToolParam(type: .string, description: "The shell command to execute. Supports multi-line commands directly — no special escaping needed. Keep under 1000 chars; for longer scripts, write to a file with file_write first, then run it."),
                    "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds (default: 900). Use a larger value for long-running commands like package installs."),
                    "delay": AgentToolParam(type: .integer, description: "Delay in seconds before execution begins. The tool blocks the agent flow during this wait WITHOUT occupying the iSH shell, so other concurrent tasks can use it. Use this instead of sleep commands to avoid resource contention."),
                ],
                required: ["tool_title", "command"],
                propertyOrdering: ["tool_title", "command", "timeout", "delay"]
            ),
            AgentToolDefinition(
                name: "file_read",
                description: "Read a file from the Linux filesystem. Faster than shell_execute for reading files — no shell overhead. Returns file content with metadata. Rejects binary files.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "5-10 word summary of this call, shown to the user; same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to read (e.g. /var/minis/workspace/data.csv)"),
                    "offset": AgentToolParam(type: .integer, description: "1-based line number to start reading from (default: 1). Ignored when direction is 'tail'. If a previous read was truncated, its header ends with next_offset=N — pass that as offset to continue from where it stopped."),
                    "lines": AgentToolParam(type: .integer, description: "Maximum number of lines to return (default: all lines up to max_length)"),
                    "max_length": AgentToolParam(type: .integer, description: "Maximum character length of returned content (default: 15000)"),
                    "direction": AgentToolParam(type: .string, description: "Read direction: 'head' (from start, default) or 'tail' (from end of file)"),
                ],
                required: ["tool_title", "path"],
                propertyOrdering: ["tool_title", "path", "offset", "lines", "direction", "max_length"]
            ),
            AgentToolDefinition(
                name: "file_write",
                // [T-file-write-large-content-timeout] GH#223. Every byte of
                // `content` has to be GENERATED by the model as tool-call
                // arguments, streamed over the network, before the write even
                // starts. So a single 50-100KB write is a very long, fragile
                // request — the failures users report as "file_write timed out"
                // are the LLM request dying mid-generation, not the (purely
                // local, instant) filesystem write. Splitting into appends makes
                // each request short, and any part that can be COMPUTED rather
                // than transcribed should be, because generated bytes are the
                // actual cost. Without this guidance the model happily emits one
                // giant argument and the turn dies with no useful diagnostic.
                description: "Write content to a file on the Linux filesystem. Creates it if missing; append: true to extend an existing file. For content over ~8KB write it in chunks or generate it with a script — one huge call is slow and often dies mid-request. Details: manual section 2.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "5-10 word summary of this call, shown to the user; same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to write (e.g. /root/test.txt)"),
                    "content": AgentToolParam(type: .string, description: "The text content to write to the file. For large content prefer several appending calls over one huge one — see the tool description."),
                    "append": AgentToolParam(type: .boolean, description: "If true, append to existing file instead of overwriting (default: false)"),
                    "create_dirs": AgentToolParam(type: .boolean, description: "If true, create parent directories if they don't exist (default: false)"),
                ],
                required: ["tool_title", "path", "content"],
                propertyOrdering: ["tool_title", "path", "content", "append", "create_dirs"]
            ),
            AgentToolDefinition(
                name: "file_edit",
                description: "Make targeted edits to an existing file by exact string replacement. Read the file first. Prefer this over file_write for edits — only the changed part is sent. old_string must match exactly one location unless replace_all is true. Details: manual section 2.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "5-10 word summary of this call, shown to the user; same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to the file to edit (e.g. /root/script.py)"),
                    "old_string": AgentToolParam(type: .string, description: "The exact text to find in the file. Must match precisely including whitespace and indentation. Must be unique in the file unless replace_all is true."),
                    "new_string": AgentToolParam(type: .string, description: "The replacement text. Use empty string to delete old_string."),
                    "replace_all": AgentToolParam(type: .boolean, description: "If true, replace ALL occurrences of old_string (default: false)"),
                ],
                required: ["tool_title", "path", "old_string", "new_string"],
                propertyOrdering: ["tool_title", "path", "old_string", "new_string", "replace_all"]
            ),
            AgentToolDefinition(
                name: "browser_use",
                // [T-agent-prompt-claude-code 09-14] Trimmed from ~2.8k chars:
                // per-action detail duplicated in the parameter descriptions
                // below is gone; the action list + cookie mechanics (unique
                // information) stay. Long-form guidance: agent-manual.md §3.
                description: "Control a web browser with up to 3 tabs. Allowed actions are the `action` parameter's values; per-action detail is in each parameter, and browser/cookie mechanics are in the manual (section 12). Do NOT use this tool for minis-clone:// action URLs (open_terminal, views, settings) — those are app deep links, use Markdown links in chat instead. minis-clone:// resource URLs CAN be opened with navigate.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "5-10 word summary of this call, shown to the user; same language as the user."),
                    "action": AgentToolParam(type: .string, description: "The browser action to perform", enumValues: BrowserAction.allCases.map(\.rawValue)),
                    "url": AgentToolParam(type: .string, description: "URL to navigate to (for navigate action) or resource to download (for fetch action)"),
                    "selector": AgentToolParam(type: .string, description: "CSS selector for the target element (click, type, get_text, scroll, hover, find_elements). For scroll, name the scrollable container (e.g. 'div.timeline'); omitted, the best one is auto-detected."),
                    "text": AgentToolParam(type: .string, description: "Text to type (for type action)"),
                    "coordinate_x": AgentToolParam(type: .integer, description: "X coordinate for click (alternative to selector)"),
                    "coordinate_y": AgentToolParam(type: .integer, description: "Y coordinate for click (alternative to selector)"),
                    "direction": AgentToolParam(type: .string, description: "Scroll direction", enumValues: ["up", "down"]),
                    "amount": AgentToolParam(type: .integer, description: "Scroll amount in pixels (default: 500)"),
                    "script": AgentToolParam(type: .string, description: "JavaScript to execute (for execute_js). Runs inside an async function wrapper — `await` and top-level `return` are supported; DOM values (DOMRect, Date, Error, element, NodeList) are converted to plain JSON."),
                    "user_agent": AgentToolParam(type: .string, description: "User agent profile to switch to", enumValues: ["desktop_safari", "mobile_safari"]),
                    "max_depth": AgentToolParam(type: .integer, description: "Maximum tree depth for get_backbone (default: 5)"),
                    "scroll_count": AgentToolParam(type: .integer, description: "Number of scroll steps for scroll_and_collect (default: 10, max: 20). Each step scrolls by 'amount' pixels and waits for new content."),
                    "item_selector": AgentToolParam(type: .string, description: "CSS selector for individual content items in scroll_and_collect (e.g. 'article', '[data-testid=\"tweet\"]'). If omitted, auto-detects repeated elements."),
                    "tab_id": AgentToolParam(type: .integer, description: "Target tab ID (optional, defaults to most recently used tab). Use list_tabs to see available tabs."),
                    "keywords": AgentToolParam(type: .string, description: "Filter cookies by name (for get_cookies). A space-separated string or array of strings. With fuzzy=true (default), ALL keywords must appear in the cookie name (case-insensitive). With fuzzy=false, cookie name must exactly equal any one of the provided keywords (case-insensitive). Omit to return all cookies for the current site."),
                    "fuzzy": AgentToolParam(type: .boolean, description: "Whether keyword matching is fuzzy (contains-all) or exact-any (for get_cookies, default: true)."),
                    "cookies": AgentToolParam(type: .string, description: "For set_cookies: a JSON array of cookie objects to write. Pass it as a JSON array (a JSON-encoded string of the array is also accepted). Each object: {\"name\": str (required), \"value\": str (required), \"domain\": str (optional, defaults to current page host), \"path\": str (optional, defaults to \"/\"), \"secure\": bool (optional), \"http_only\": bool (optional — sets an HttpOnly cookie that JS cannot read/set), \"expires\": int (optional, Unix timestamp in seconds; omit for a session cookie)}. Field-name variants from common cookie exports are accepted: httpOnly (=http_only), expirationDate (=expires), sameSite, and case/camel variants — so you can paste cookies verbatim from browser extensions (EditThisCookie / Cookie-Editor) or Playwright/Puppeteer storage."),
                    "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds for wait_for_dom_stable (default: 10). The action polls every 0.5s and resolves when DOM mutation rate stabilizes."),
                    "viewport_width": AgentToolParam(type: .integer, description: "Viewport width in CSS pixels for set_viewport (e.g. 1920). Required together with viewport_height unless reset=true."),
                    "viewport_height": AgentToolParam(type: .integer, description: "Viewport height in CSS pixels for set_viewport (e.g. 1080). Required together with viewport_width unless reset=true."),
                    "reset": AgentToolParam(type: .boolean, description: "For set_viewport: when true, clear the session-level viewport override and fall back to the global browser setting."),
                    "full_page": AgentToolParam(type: .boolean, description: "For screenshot: capture the entire scrollable page instead of just the viewport. Capped at 32768px tall; when capped the result says so and gives the real height."),
                ],
                required: ["tool_title", "action"],
                propertyOrdering: ["tool_title", "action", "tab_id", "url", "selector", "text", "coordinate_x", "coordinate_y", "direction", "amount", "scroll_count", "item_selector", "script", "user_agent", "max_depth", "keywords", "fuzzy", "cookies", "timeout", "viewport_width", "viewport_height", "reset", "full_page"]
            ),
        ]

        if includeMemoryTools {
            tools.append(AgentToolDefinition(
                name: "memory_write",
                description: "Write an entry to today's daily log (YYYY-MM-DD.md). Save preferences, recurring patterns, key facts, conventions. Never save passwords, API keys or tokens. GLOBAL.md is read-only. Details: manual section 9.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "5-10 word summary of this call, shown to the user; same language as the user."),
                    "content": AgentToolParam(type: .string, description: "The memory content to write. Use concise Markdown with a short heading (## Topic) and context about what was done/learned."),
                ],
                required: ["tool_title", "content"],
                propertyOrdering: ["tool_title", "content"]
            ))
            tools.append(AgentToolDefinition(
                name: "memory_get",
                description: "Search memory files by keyword; returns matching lines with surrounding context. Use when a request depends on what was said or decided earlier.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "5-10 word summary of this call, shown to the user; same language as the user."),
                    "scope": AgentToolParam(type: .string, description: "Memory scope to search: 'daily' for daily logs only, 'all' for daily logs + GLOBAL.md.", enumValues: ["daily", "all"]),
                    "keywords": AgentToolParam(type: .string, description: "Space-separated keywords for fuzzy matching (e.g. 'python preference' or 'API key setup'). All keywords must appear in a line or its surrounding context for a match. Leave empty to return full memory files."),
                ],
                required: ["tool_title"],
                propertyOrdering: ["tool_title", "scope", "keywords"]
            ))
        }

        // [T-ios-vision-group #182] Expose read_image when the model can see
        // images ITSELF, or when a Vision Group is configured to see them on its
        // behalf. Previously a text-only model simply never got this tool, so an
        // image on disk was invisible to it with no recourse. The handler picks
        // the matching branch: native models get pixels, others get the Vision
        // Group's description as text.
        //
        // `isConfigured` is strict (group must resolve AND hold a usable
        // image-capable member), so we never advertise a tool whose non-native
        // path has nothing behind it.
        let nativeVision = activeModelHasNativeVision
        // Evaluate FIRST, not inside the `||` below: short-circuiting on
        // `nativeVision` would skip the call, and this read is also what keeps
        // `isConfiguredCached` — which the off-main T264 placeholder builder
        // relies on — up to date.
        let visionGroupConfigured = VisionGroupResolver.isConfigured
        if nativeVision || visionGroupConfigured {
            // Describe what this model will ACTUALLY receive. Promising "the
            // image is returned directly" to a text-only model would set up a
            // false expectation and invite it to re-call the tool when no pixels
            // arrive; the non-native branch returns a written description instead.
            let readImageDescription = nativeVision
                ? "Read an image file from the Linux filesystem and return it for visual analysis. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, or any visual output. The image is returned directly for your analysis along with metadata (dimensions, file size)."
                : "Read an image file from the Linux filesystem and return a written description of it. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, user-attached photos, or any visual output. You cannot see images directly, so the image is analyzed by a separate vision model and you receive its detailed description plus a transcription of any visible text, along with metadata (dimensions, file size). Because you cannot look again yourself, use the optional 'prompt' argument to ask for exactly what you need from the image — that is your only way to follow up on specific details."
            // [T-ios-vision-group-t264 #182] The `prompt` argument is what makes
            // the non-native branch usable for anything but a generic caption:
            // the host model can't look at the image, so this is its only lever
            // for directing the describing model. On the native branch the model
            // sees the pixels itself, so the argument is documented as optional
            // context rather than a question.
            let promptDescription = nativeVision
                ? "Optional. A note about what you are looking for in the image. Recorded alongside the result; the image itself is returned to you in full either way."
                : "Optional. A specific question or instruction about the image, e.g. 'transcribe the table', 'what error message is shown in this screenshot', 'describe the people and their expressions'. This is passed to the vision model that reads the image for you, so ask for exactly the detail you need. If omitted, a generic detailed description with full text transcription is returned."
            tools.append(AgentToolDefinition(
                name: "read_image",
                description: readImageDescription,
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "5-10 word summary of this call, shown to the user; same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Linux path (e.g. /var/minis/attachments/chart.png) or minis-clone:// URL (e.g. minis-clone://attachments/chart.png)"),
                    "prompt": AgentToolParam(type: .string, description: promptDescription),
                ],
                required: ["tool_title", "path"],
                propertyOrdering: ["tool_title", "path", "prompt"]
            ))
        }

        return tools
    }

}
