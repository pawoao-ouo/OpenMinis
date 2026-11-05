#!/usr/bin/env python3
"""跑一遍 standalone 断言文件的所有静态检查。

CI 的第 9 步只编译 App，第 10 步才真跑断言。断言里写错一个标识符、或者
断言的字符串跟源码对不上，都要等到第 10 步才炸——一整轮构建白等。这个
脚本把能静态查的全部提前查掉：

  1. lint-standalone.py   括号配平、重复声明、未声明标识符、check 参数
  2. verify-assertions.py 每条 X.contains("...") 是否真在对应源文件里

用法（仓库根目录）:
  python3 scripts/theme/check-standalone.py
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))
STANDALONE = os.path.join(ROOT, "src/ios/MinisTests/Standalone")

# 只有"读源码做断言"的套件才适用这里的两项检查。其余套件是真跑逻辑的，
# 括号统计对它们没有意义（字符串插值里的括号会把朴素配平算歪）。
SOURCE_READING_SUITES = [
    "AppearanceThemePackTests.swift",
    "AppearancePaletteIntegrityTests.swift",
]

files = [os.path.join(STANDALONE, n) for n in SOURCE_READING_SUITES]
missing = [f for f in files if not os.path.exists(f)]
if missing:
    print("missing suite(s):", missing)
    sys.exit(1)

failed = 0
for path in files:
    rel = os.path.relpath(path, ROOT)
    print(f"== {rel}")
    for script in ("lint-standalone.py", "verify-assertions.py"):
        cmd = [sys.executable, os.path.join(HERE, script)]
        if script == "verify-assertions.py":
            cmd += [ROOT, rel]
        else:
            cmd.append(rel)
        result = subprocess.run(cmd, cwd=ROOT)
        if result.returncode != 0:
            failed += 1

if failed:
    print(f"\n{failed} check(s) failed")
    sys.exit(1)
print("\nALL STATIC CHECKS PASS")