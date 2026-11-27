#!/usr/bin/env python3
"""
提示词自检：把"我以为写进去了"变成"能机器验的断言"。

跑法：python3 scripts/prompt_audit.py
退出码 0 = 全过，1 = 有 FAIL。

查四类事，全是真能出错的地方：
  1. 路由表点名的工具，schema 里到底有没有；没有的话有没有写替代文案。
  2. 提示词里提到的 /var/minis/ 路径，在 iSH 里存不存在。
  3. 手册索引能不能切出来、多大。
  4. 目录总 token 数，以及有没有重复条目。
"""
import re
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VM = os.path.join(ROOT, "src/ios/Agent/Chat/AIChatViewModel.swift")
TOOLS = os.path.join(ROOT, "src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift")
MANUAL = os.path.join(ROOT, "src/ios/Resources/user-manual.md")

fails = []
warns = []


def fail(msg):
    fails.append(msg)


def warn(msg):
    warns.append(msg)


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


vm = read(VM)
tools = read(TOOLS)
manual = read(MANUAL)

# ---------------------------------------------------------------- 1. 路由表
# 从路由表那一段里抽工具名（"→ xxx" 或 "→ there is no xxx"）。
i = vm.index('"Routing — pick the tool by the task')
j = vm.index('"File search & text scanning', i)
routing = vm[i:j]
named = set(re.findall(r"→ ([a-z_][a-z0-9_]*)(?=[\s.,])", routing))
print("路由表点名的工具:", sorted(named) or "(无)")

# schema 里真注册的工具名（name: "xxx" 出现在 AgentToolDefinition 里）
schema_names = set(re.findall(r'name: "([a-z_][a-z0-9_]*)"', tools))
for n in sorted(named):
    if n in schema_names:
        continue
    # 不在 schema 里，必须有一条明确的"这次没有"分支，否则就是让模型瞎调
    if re.search(r"there is no %s tool|no %s tool|no %s tool in this session" % (n, n, n), routing):
        print("  %-16s 条件可用，已有替代文案 ✓" % n)
    elif n in ("rg", "bash", "curl", "apk", "there", "search", "minis"):
        pass  # shell 命令，不是工具
    else:
        fail("路由表点名 %s，schema 里没有，也没有替代文案" % n)

# ---------------------------------------------------------------- 2. 路径
paths = set(re.findall(r"/var/minis/[A-Za-z0-9_./<>-]+", vm))
skip_frag = ("<", ">", "YYYY", "filename", "name")
checked = 0
# CI 是 macOS runner，没有 /var/minis —— 那边的「不存在」没有意义，只在真机上查
_on_device = os.path.isdir("/var/minis")
for p in sorted(paths):
    if any(s in p for s in skip_frag):
        continue
    p2 = p.rstrip(".,)")
    checked += 1
    if _on_device and not os.path.exists(p2):
        warn("提示词提到 %s，本机不存在（真机上可能由 App 创建）" % p2)
print("检查路径 %d 个%s" % (checked, "" if _on_device else "（非真机，跳过存在性检查）"))

# ---------------------------------------------------------------- 3. 手册索引
begin = "<!-- MANUAL-INDEX-BEGIN"
end = "MANUAL-INDEX-END -->"
if begin not in manual or end not in manual:
    fail("手册缺 MANUAL-INDEX 标记，indexFragment() 会返回 nil，索引注不进去")
else:
    b = manual.index(begin) + len(begin)
    e = manual.index(end, b)
    body = manual[b:e]
    if "-->" in body:
        body = body[body.index("-->") + 3:]
    body = body.strip()
    toks = len(body) // 2
    print("手册索引 %d 字符 ~%d token" % (len(body), toks))
    if not body.startswith("##"):
        fail("索引切片没从标题开始，切法坏了")
    if toks > 800:
        fail("索引 %d token 太大，常驻不划算（目标 < 500）" % toks)
    # 索引里列的章节，手册正文里必须真有
    for sec in re.findall(r"\*\*(.+?)\*\* —", body):
        key = sec.split()[0]
        if key not in manual:
            fail("索引提到「%s」，手册正文里找不到这一章" % sec)

# ---------------------------------------------------------------- 4. 目录
cat_items = re.findall(
    r'CatalogItem\(\s*id: "([^"]+)",\s*name: "([^"]+)",\s*category: \.(\w+)', tools
)
print("目录条目 %d 条" % len(cat_items))
ids = [c[0] for c in cat_items]
dup = {x for x in ids if ids.count(x) > 1}
if dup:
    fail("目录 id 重复: %s" % dup)

apple_rows = tools[tools.index("static func appleCompactSection"):]
apple_rows = apple_rows[: apple_rows.index("\n    }")]
n_apple = len(re.findall(r'\("-?[a-zA-Z][^"]*?",\s*"', apple_rows))
print("apple 压缩段 %d 条" % n_apple)
if n_apple < 20:
    fail("apple 压缩段只剩 %d 条，可能漏了工具" % n_apple)

# 目录里每条都要有 synopsis 和 quickSyntax，空的就是半条
for cid, name, cat in cat_items:
    blk = tools[tools.index('id: "%s"' % cid):]
    blk = blk[: blk.index("),")]
    if 'synopsis: ""' in blk or 'quickSyntax: ""' in blk:
        fail("目录条目 %s 的 synopsis/quickSyntax 是空的" % name)

# ---------------------------------------------------------------- 5. 祈使句基线（整改包 §2.2）
# 只统计「会进模型上下文」的字符串字面量里的严格祈使词。基线存在同目录的
# prompt_imperative_baseline.json，只许降不许升——升了说明有人新加了一条
# 「必须/绝不/Do NOT」，得先想清楚它是不是该由代码闸门来管。
import json

BASE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prompt_imperative_baseline.json")

# 严口径：真正在给模型下命令的词。only/should 这类英文正常文法用法太多，不计。
STRICT_EN = ["MUST", "Do NOT", "Never", "Always", "IMPORTANT", "You must", "You should", "You are"]
STRICT_ZH = ["必须", "总是", "绝不", "不许", "务必", "禁止", "请你",
             "不要", "不能", "核心原则", "规则："]
# 弱祈使（不要/不能/You should）在参数说明里常是正常表述，短串里不计。
# 强祈使（必须/绝不/务必/MUST/Never/Do NOT）无论多短都算。
STRICT_EN_STRONG = ["MUST", "Do NOT", "Never", "IMPORTANT"]
STRICT_ZH_STRONG = ["必须", "绝不", "务必", "禁止", "不许"]
STRICT_EN = ["MUST", "Do NOT", "Never", "Always", "IMPORTANT", "You must", "You should", "You are"]
STRICT_ZH = ["必须", "总是", "绝不", "不许", "务必", "禁止", "请你", "不要", "不能", "核心原则", "规则："]

LIT_RE = re.compile(r'"((?:[^"\\]|\\.){4,})"')
LIT_RE_LOOSE = re.compile(r'"((?:[^"\\]|\\.){8,})"')

SCAN_FILES = [
    # 系统提示主体、工具描述、标题生成、压缩、兜底提示词
    "src/ios/Agent/Chat/AIChatViewModel.swift",
    "src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift",
    "src/ios/Agent/Chat/AIChatViewModel+TitleGeneration.swift",
    "src/ios/Agent/Chat/AIChatViewModel+Persistence.swift",
    "src/ios/Agent/Chat/AIChatViewModel+MemoryTools.swift",
    "src/ios/Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift",
    "src/ios/Agent/Chat/AIChatViewModel+ManualTools.swift",
    "src/ios/Agent/Chat/AIChatViewModel+Fallback.swift",
    # 身份正文
    "src/ios/Agent/Session/SoulStore.swift",
    "src/ios/Agent/Session/PersonaStore.swift",
    # 压缩引擎（P6/P7）——它也用第二人称称呼模型
    "src/ios/Agent/Chat/AIChatViewModel+Compaction.swift",
    # 贴纸目录（R3）——中文规章腔
    "src/ios/Views/Chat/AIChatView.swift",
    # 后台任务 / 子任务链路（工具返回会进上下文）
    "src/ios/Agent/Jobs/HelperRunner.swift",
    "src/ios/Agent/Jobs/AgentJobRegistry.swift",
    "src/ios/Agent/Jobs/ScheduledJobRunner.swift",
    # 斜杠命令的 systemInfo
    "src/ios/Agent/Chat/AIChatViewModel+SlashCommands.swift",
]

# 技能正文单独统计：它是操作手册，加载时才进上下文，判定标准和系统提示不同
# （手册里写「不能改什么」「必须明说」是正当的，不该和系统提示混在一起计数）。
SCAN_FILES_DOC = [
    "src/ios/Agent/Session/SkillStore.swift",
]

current = {}
# 多行字符串 """...""" 才是提示词正文的主要形态（单行字面量只是零星几处）。
# 先把每行归到所属的字符串块里，再按块判断命中，避免漏掉压缩/贴纸这类长段。
def _count(rel_list, sink):
    for rel in dict.fromkeys(rel_list):
        p = os.path.join(ROOT, rel)
        if not os.path.isfile(p):
            # 路径写错、文件被改名/删除都会静默跳过，数字变小反而"达标"。
            # 这里必须报出来，否则基线失去意义。
            fail("扫描清单里的文件不存在：%s（路径写错，或文件被改名/删除）" % rel)
            continue
        src = open(p, encoding="utf-8", errors="ignore").read()
        n = 0
        in_block = False
        for line in src.split("\n"):
            s = line.lstrip()
            if not in_block and s.startswith("//"):
                continue
            # 进入/退出多行字符串
            if '"""' in line:
                if line.count('"""') == 1:
                    in_block = not in_block
                    continue
            if in_block:
                # 多行块内部：整行算一次。不能再走 LIT_RE，否则同一行里的引号
                # 会被重复计一次（多行块里的引号不是字符串边界）。
                # 口径和单行一致：强词或规章标记才算。
                if (any(w in line for w in STRICT_EN_STRONG)
                        or any(w in line for w in STRICT_ZH_STRONG)
                        or any(w in line for w in ("核心原则", "规则：", "You are", "You should"))):
                    n += 1
                continue
            for m in LIT_RE.finditer(line):
                text = m.group(1)
                if text in ("Never Used", "Never auto-lock", "Never"):
                    continue
                # AppLocalized("...") 是界面文案，模型看不到
                if 'AppLocalized(' in line:
                    continue
                # Swift 类型/常量误报：`Task<Void, Never>`、`...FromImageAlways`
                # 这类是代码不是文案。中文词不会出现在这里，英文才要过滤。
                if not any(w in text for w in STRICT_ZH):
                    if re.search(r"Task<[^>]*Never", text):
                        continue
                    if re.match(r"^[A-Za-z0-9_.]*(Always|Never)$", text):
                        continue
                # 强祈使词（必须/绝不/务必/MUST/Never/Do NOT）一律计。
                # 弱词只在「规章标记」上计：核心原则/规则：/You are/You should。
                # 「不要/不能」在参数说明里常是描述性的（"不传就用默认"），不作判据。
                strong = (any(w in text for w in STRICT_EN_STRONG)
                          or any(w in text for w in STRICT_ZH_STRONG))
                marker = any(w in text for w in ("核心原则", "规则：", "You are", "You should"))
                if strong or marker:
                    n += 1
        if n:
            sink[rel] = n

_count(SCAN_FILES, current)
doc_hits = {}
_count(SCAN_FILES_DOC, doc_hits)
total_now = sum(current.values())
doc_total = sum(doc_hits.values())
print("技能正文（单独统计，不作验收基线）%d 处" % doc_total)

if not os.path.exists(BASE_FILE):
    # CI 上基线文件必须已经提交进仓库。缺失时自动写一份等于让检查失效——
    # 首次运行只允许在本地发生（用 --init 显式声明）。
    if "--init" not in sys.argv:
        fail("基线文件 %s 不存在。首次建立基线请本地跑 `python3 scripts/prompt_audit.py --init`，"
             "然后把生成的文件一起提交。" % os.path.basename(BASE_FILE))
        total_now = 0
        base = None
    else:
        with open(BASE_FILE, "w", encoding="utf-8") as f:
            json.dump({"total": total_now,
                       "byFile": current,
                       "docTotal": doc_total,
                       "docByFile": doc_hits,
                       "_note": "只许降不许升。数字是当前存量，不是合格线——每次清理后手动下调基线，"
                                "新加的祈使句会直接撞红。改动口径（词表/扫描范围）必须同时重写这个文件并在此说明。"
                                "docTotal 是技能手册正文，只在技能加载时进上下文，单独统计不作验收。"},
                      f, ensure_ascii=False, indent=1)
        print("严格祈使句 %d 处（首次运行，已写入基线）" % total_now)
        base = None
else:
    base = json.load(open(BASE_FILE, encoding="utf-8"))

if base is not None:
    base_total = base.get("total", 0)
    print("严格祈使句 %d 处（基线 %d）" % (total_now, base_total))
    # 基线里有的文件这次没扫到 → 扫描范围缩小，数字变小会掩盖问题
    vanished = [k for k in base.get("byFile", {}) if k not in current]
    for v in vanished:
        fail("基线里的文件这次没扫到：%s（扫描范围缩小，基线数字不可比）" % v)
    if total_now > base_total:
        grew = {k: v for k, v in current.items() if v > base.get("byFile", {}).get(k, 0)}
        if grew:
            for k, v in sorted(grew.items(), key=lambda x: -x[1]):
                fail("祈使句比基线多 %d 处（%d → %d）：%s"
                     % (v - base.get("byFile", {}).get(k, 0), base.get("byFile", {}).get(k, 0), v, k))
        else:
            fail("祈使句总数比基线多（%d → %d）" % (base_total, total_now))

# ---------------------------------------------------------------- 报告
print()
for w in warns:
    print("WARN  " + w)
for f in fails:
    print("FAIL  " + f)
if not fails:
    print("全部通过（%d 条警告）" % len(warns))
sys.exit(1 if fails else 0)
