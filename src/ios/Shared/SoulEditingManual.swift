import Foundation

// [batch1-soul-hint 11-27 醒醒] 身份段里的 soulEditHint 原来是一段 4,158 字符
// 的常驻说明（怎么改 SOUL、怎么改主题、TOGETHER 怎么用），每轮都进系统提示，
// 占掉身份段将近全部。批 1 要求：改成"目录里留一行说明，正文用到时再读"。
//
// 这份就是正文。启动时同步到 /var/minis/shared/soul-editing.md，
// 提示词里只留路径 + 一句用途。模型真要改人设/外观时 file_read 读它。
enum SoulEditingManual {

    /// 模型看到的路径。
    nonisolated static let linuxPath = "/var/minis/shared/soul-editing.md"

    /// 常驻索引，替代原来 4,158 字符的 soulEditHint。
    nonisolated static var indexFragment: String {
        """
        Editing this app (persona fields, appearance, the shared music player): read \(linuxPath) with file_read before changing anything — it lists every command, every real parameter, and what is locked. Do not invent parameters. Every image argument is `--file <path inside iSH>`, never a URL or base64.
        """
    }

    /// 完整正文。
    nonisolated static let content: String = """
    # Editing this app

    Every command below is real. Do not invent parameters.
    Every image argument is `--file <path inside iSH>` — never a URL or base64.

    ## Persona / identity

    `minis-config topic-help soul` lists every field.
    Write with `minis-config set soul.name '"X"'` (style / lang / body take the same shape;
    long text goes through `--file <json>`).
    This edits the CURRENT persona only, and every write asks the user to approve.
    UI path: Settings → Soul.

    ## Appearance — all of it goes through `minis-theme`

    · Avatars: `minis-theme avatar --role assistant --file <png>` (the agent's) /
      `--role user` (the user's); `--remove` clears.
      The single source is the contacts entry (Persona.avatar); SOUL.md `icon` is only a
      mirror — change it there, never in two places. UI path: contacts (the Soul page is read-only).
    · Row icons: `minis-theme icon --list` is the only icon command available.
      Setting or clearing an icon is locked on purpose — the user changes icons in the settings UI.
    · Wallpaper: `minis-theme wallpaper --scope global|home|chat|settings|browser|files|terminal|bottomBar|persona --file <img>`;
      `--remove` clears.
    · Single colours: `minis-theme color --list --scope chat` reads current values, then
      `minis-theme color --role accent --hex D4778B --scope chat --variant light|dark`;
      `--clear` restores the default.
    · Whole skin (bubbles / corner radius / fonts / thinking card / input bar / category tiles):
      `minis-theme get` → edit the JSON → `minis-theme apply --file`.
      `save --name` stores a pack; `list` / `use --id` loads one; `reset` restores;
      `undo` reverses the last reset.
      Delete / rename / avatar / wallpaper / reset all stop at a confirmation sheet the user must approve.
      A wallpaper inside a pack lands in the `global` scope — the same slot
      `wallpaper --scope global` writes, so they replace each other rather than stack.
    · App icon and light/dark mode are NOT under `minis-theme` yet:
      `minis-config set appearance.appIcon auto|light|dark|legacy_light|legacy_dark`
      and `appearance.theme light|dark|system`.

    ## TOGETHER (一起听) — a shared music player

    One state file, `/var/minis/shared/together/state.json`; both the agent and the app panel
    write it, so a change shows up on the other side within a couple of seconds.
    All through the `together` command:

    · Read state: `together now` (a sentence about what is playing — not a field dump),
      `together status`, `together events --limit 30`, `together history`.
    · Play: `together play <trackId> [--at 秒]` / `pause` / `resume` / `seek <秒>` /
      `handoff [user|ai]` (passes the remote). `together lib` lists the library;
      `together lib add <id> <path> <title>` and `together lib rm <id>` manage it.
    · Leave a line at a second: `together note <秒> <话>` — it surfaces only when playback
      reaches that second, not before. `together loopline <trackId> <话>` sets the looping
      line for a song with no lyrics. `together mood <词> [--intensity 1-5]` is a state tag
      shown in the panel. `together reply <话>` speaks now (3 a day, hard cap — the command
      refuses the 4th). `together radio <trackId> --why <理由>` chooses a song unprompted;
      the reason is stored so it is still known next turn why it played.
    · Playlists: `together playlist new <名> | add <id> <trackId> | rename <id> <名> | rm <id>`.
    · Fetching songs/lyrics is `together-fetch`: `search`, `import <file>`, `lyrics <id>`.
      Lyrics come with timestamps; if a song has none, write a loopline instead of inventing
      lyrics. Never make up song titles that do not exist in `together lib`.

    ## Scheduled tasks

    `minis-scheduled create --prompt "…" --after 30m` (once),
    `--interval 10m --count 6` (loop), `--time 09:00 --repeat daily|weekdays|custom --days mon,fri`
    (calendar), `--trigger on-completion --of <jobId>` (chain).
    `--target follow-up` (default: each fire is a new turn in this chat) |
    `new` (each fire opens a separate new chat) | `child-of-current` (a hidden helper).
    Read the `delivery` line `create` prints and re-create with the right target if it is wrong.
    `--command "<shell>"` pre-runs a command at each fire.
    `list`, `delete --id`, `enable/disable --id`, `run --id`.
    Timers live only while the app process is alive; for guaranteed execution after the app
    is killed the user needs an Apple Shortcuts automation.
    """

    /// 把正文写到 /var/minis/shared/，内容不同才写（保持 mtime 稳定）。
    nonisolated static func syncToSharedDir() {
        let url = URL(fileURLWithPath: linuxPath)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           existing == content {
            return
        }
        try? content.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
