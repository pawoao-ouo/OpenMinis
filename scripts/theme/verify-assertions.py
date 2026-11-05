#!/usr/bin/env python3
"""核对 standalone 断言里的字符串是否真在目标源码里。

第 10 步跑的是真 Swift 脚本，断言为 false 只会在 CI 报 FAIL，又是一整轮。
这里把每个 X.contains("字面量") 按变量名映射回源文件，逐条验。
条件里取反的（!X.contains）不验——那条本来就该找不到。

用法: python3 verify-assertions.py <仓库根> <测试文件>
"""
import re
import sys
import os
import ast

repo = sys.argv[1] if len(sys.argv) > 1 else "."
test = sys.argv[2] if len(sys.argv) > 2 else \
    "src/ios/MinisTests/Standalone/AppearanceThemePackTests.swift"

src = open(os.path.join(repo, test), encoding="utf-8").read()

# 变量名 -> 源文件相对路径
mapping = dict(re.findall(
    r'let (\w+) = read\(here\.appendingPathComponent\("([^"]+)"\)\)', src))

cache = {}


def body_of(rel):
    if rel not in cache:
        path = os.path.join(repo, "src/ios", rel)
        cache[rel] = open(path, encoding="utf-8").read() if os.path.exists(path) else None
    return cache[rel]


# 找 X.contains("...")，跳过前面有 ! 的
pattern = re.compile(r'(?<![!\w.])(\w+)\.contains\(("(?:[^"\\]|\\.)*")\)')
problems = []
checked = 0
for m in pattern.finditer(src):
    var, lit = m.group(1), m.group(2)
    if var not in mapping:
        continue
    try:
        want = ast.literal_eval(lit)
    except Exception:
        continue
    # Swift 转义比 Python 少一层，粗略还原 \\ 与 \"
    want = want.replace('\\\\', '\\').replace('\\"', '"')
    body = body_of(mapping[var])
    if body is None:
        problems.append(f"{var}: source file missing ({mapping[var]})")
        continue
    checked += 1
    # 字符串里可能有 \n 表示换行
    probe = want.replace('\\n', '\n')
    if probe not in body and want not in body:
        line = src[:m.start()].count("\n") + 1
        problems.append(f"line {line}: {var}.contains(...) not found in {mapping[var]}\n      → {want[:90]!r}")

print(f"checked {checked} positive contains() assertions")
if problems:
    print("FAIL")
    for p in problems:
        print("  -", p)
    sys.exit(1)
print("OK")