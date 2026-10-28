#!/bin/bash
# ── 本机 shell 脚本的两类「必踩」坑静态检查
#
# 为什么有这个脚本：这两个坑在本仓库各踩过两次，症状都不是「报错」，而是
# 脚本静默走错分支或直接崩在无关紧要的一行 —— 排查成本远高于加一条检查。
#
# ── 检查 A：`$VAR` 紧贴多字节字符（bash 3.2 会把首字节当标识符一部分）
#   macOS 自带 /bin/bash 是 3.2.57，`set -u` 下这行会直接崩：
#       SN="AC"; echo "武装【$SN】侧"
#       ⇒ s4-arm.sh: line N: SN?: unbound variable
#   （报错里那个 `?` 是终端无法解码的 `】` 首字节）
#   修法：一律写 `${SN}`，花括号给出明确边界。
#
# ── 检查 B：`set -o pipefail` 与 `... | grep -q`
#   `grep -q` 命中即退出 → 左侧命令收 SIGPIPE → 管道退出码 13 → pipefail 让整条管道失败
#   ⇒ `if cmd | grep -q X; then` 明明命中也判假。本机实测 pipefail_exit=13。
#   修法：先存变量再字符串匹配，例如
#       OUT="$(cmd 2>/dev/null)"; if [[ "$OUT" == *X* ]]; then
#
# 用法：bash EFI/scripts/lint-shell-cjk.sh [目录...]   （默认 EFI/scripts + tools）
set -u

ROOTS=("$@")
if [[ ${#ROOTS[@]} -eq 0 ]]; then
  ROOTS=("EFI/scripts" "tools")
fi

/usr/bin/python3 - "${ROOTS[@]}" <<'PY'
import re, sys, glob, os

roots = sys.argv[1:]
files = []
for r in roots:
    if os.path.isfile(r):
        files.append(r)
    else:
        files += glob.glob(os.path.join(r, '**', '*.sh'), recursive=True)
files = sorted(set(files))

var_pat = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*')
problems = []

for f in files:
    try:
        text = open(f, encoding='utf-8', errors='replace').read()
    except OSError:
        continue
    lines = text.split('\n')
    has_pipefail = re.search(r'^\s*set\s+-[a-z]*o\s+pipefail|^\s*set\s+-o\s+pipefail', text, re.M) is not None

    for n, ln in enumerate(lines, 1):
        # 跳过纯注释行（否则本文件的示例、以及别处的「正确写法」说明都会被误报）
        if re.match(r'^\s*#', ln):
            continue
        # A: $VAR 紧跟多字节字符
        for m in var_pat.finditer(ln):
            if m.end() < len(ln) and ord(ln[m.end()]) > 127:
                problems.append((f, n, 'A',
                    f'{m.group(0)} 紧贴 {ln[m.end()]!r}，应写 ${{{m.group(0)[1:]}}}'))
        # B: pipefail 下的 | grep -q
        if has_pipefail and re.search(r'\|\s*grep\s+-[a-zA-Z]*q', ln):
            problems.append((f, n, 'B',
                'set -o pipefail 下的 "| grep -q" 会因 SIGPIPE 误判，改存变量再匹配'))

if not problems:
    print('✔ 两类坑均未发现（A: $VAR 贴多字节 / B: pipefail + grep -q）')
    sys.exit(0)

cur = None
for f, n, kind, msg in problems:
    if f != cur:
        print(f'\n{f}')
        cur = f
    print(f'  [{kind}] {n}: {msg}')
print(f'\n共 {len(problems)} 处')
sys.exit(1)
PY
