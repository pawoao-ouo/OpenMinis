#!/usr/bin/env python3
"""推送前自查 standalone 断言文件。

CI 的 compile gate 只查 App，第 10 步才跑这个脚本；脚本里一个没声明的
标识符要等到那一步才暴露，前面白等一整轮构建。这里把能静态查的先查掉。

用法: python3 scripts/theme/lint-standalone.py <文件>
"""
import re
import sys
import collections

path = sys.argv[1] if len(sys.argv) > 1 else \
    "src/ios/MinisTests/Standalone/AppearanceThemePackTests.swift"
src = open(path, encoding="utf-8").read()
lines = src.split("\n")
problems = []

def strip_literals(text):
    """去掉字符串字面量与注释，只留下真正的代码括号。

    断言里会写源码片段（`studio.contains("func f() {\n ...")`），那些括号
    在字符串里，不该参与配平——否则每个断言都报不平衡。
    """
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


code = strip_literals(src)

# 1. 括号平衡
for open_ch, close_ch, name in (("{", "}", "braces"), ("(", ")", "parens"), ("[", "]", "brackets")):
    delta = code.count(open_ch) - code.count(close_ch)
    if delta != 0:
        problems.append(f"{name} unbalanced by {delta}")

# 2. 顶层 let 重复声明
tops = [(i + 1, m.group(1)) for i, l in enumerate(lines) if (m := re.match(r"^let (\w+)", l))]
counts = collections.Counter(n for _, n in tops)
for name, n in counts.items():
    if n > 1:
        problems.append(f"duplicate top-level let '{name}' at lines " +
                        ",".join(str(ln) for ln, x in tops if x == name))

# 3. xxx.contains( 用到的标识符必须声明过（顶层或同级局部）
declared = set(n for _, n in tops)
declared |= set(re.findall(r"^\s*let (\w+) = read\(", src, flags=re.M))
declared |= set(re.findall(r"^\s*let (\w+)\s*=", src, flags=re.M))
swift_whitelist = {"String", "label", "Body", "body", "text", "hex", "raw", "entry"}
# 只在"真代码"里找标识符：断言字符串里会写源码片段，里面的 xxx.contains(
# 不是这里的调用，按原文扫会误报。
used = set(re.findall(r"(?<![\w.])([a-zA-Z]\w*)\.(?:contains|hasPrefix|isEmpty)\(", code))
for name in sorted(used - declared - swift_whitelist):
    problems.append(f"identifier '{name}' used but never declared")

# 4. 每个 check/checkEq 至少两个参数
for i, l in enumerate(lines):
    if re.search(r"\bcheck\(", l) or re.search(r"\bcheckEq\(", l):
        joined = l
        j = i
        while joined.count("(") > joined.count(")") and j + 1 < len(lines):
            j += 1
            joined += " " + lines[j]
        inner = joined[joined.index("(") + 1: joined.rindex(")")] if ")" in joined else ""
        if inner.count(",") < 1:
            problems.append(f"line {i+1}: check/checkEq with fewer than 2 arguments")

if problems:
    print("FAIL")
    for p in problems:
        print("  -", p)
    sys.exit(1)
print("OK", path)