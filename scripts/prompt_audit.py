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
for p in sorted(paths):
    if any(s in p for s in skip_frag):
        continue
    p2 = p.rstrip(".,)")
    checked += 1
    if not os.path.exists(p2):
        warn("提示词提到 %s，本机不存在（真机上可能由 App 创建）" % p2)
print("检查路径 %d 个" % checked)

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

# ---------------------------------------------------------------- 报告
print()
for w in warns:
    print("WARN  " + w)
for f in fails:
    print("FAIL  " + f)
if not fails:
    print("全部通过（%d 条警告）" % len(warns))
sys.exit(1 if fails else 0)
