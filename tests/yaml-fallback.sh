#!/usr/bin/env bash
# The dependency-free YAML parser must agree with PyYAML on every file the
# repository commits, and validate-data.py must pass without PyYAML at all.
# (The CI job image has no PyYAML unless it is installed; this is what broke
# 'data' on the first real pipeline run.)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scratch
T="$SCRATCH/tree"
generate "$T"

echo "yaml fallback"
python3 -c 'import yaml' 2>/dev/null || { echo "  (PyYAML not installed here; comparison skipped)"; HAVE_YAML=0; }

if [ "${HAVE_YAML:-1}" = 1 ]; then
	out="$(python3 - "$T" <<'PY'
import sys, glob, os
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import yaml
import yamlcompat
bad = 0
files = sorted(glob.glob(os.path.join(sys.argv[1], "**", "*.y*ml"), recursive=True))
files += sorted(glob.glob(os.path.join(sys.argv[1], "data", "**", "*.yaml"), recursive=True))
seen = set()
for f in files:
    if f in seen or "/.gitlab-ci" in f or f.endswith(".gitlab-ci.yml"):
        continue
    seen.add(f)
    text = open(f).read()
    try:
        want = yaml.safe_load(text)
    except Exception:
        continue          # not plain data (templates, CI): not ours to compare
    try:
        got = yamlcompat._Parser(text).parse()
    except Exception as e:
        print(f"MISMATCH {os.path.relpath(f, sys.argv[1])}: fallback raised {e}")
        bad += 1
        continue
    if got != want:
        print(f"MISMATCH {os.path.relpath(f, sys.argv[1])}: parsers disagree")
        bad += 1
print(f"compared {len(seen)} files, {bad} disagree")
sys.exit(1 if bad else 0)
PY
)"
	rc=$?
	printf '%s\n' "$out" | sed 's/^/    /'
	check "fallback parser agrees with PyYAML on every committed YAML file" test "$rc" -eq 0
fi

# Flow mappings inside block sequences: the case that broke.
res="$(python3 - "$T" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import yamlcompat
doc = yamlcompat._Parser("tags:\n  - { scope: workload, tag: payments-web }\n  - { scope: quarantine, tag: active }   # c\nlist: [a, b]\nm: { x: 1, y: 'a: b' }\n").parse()
want = {"tags": [{"scope": "workload", "tag": "payments-web"}, {"scope": "quarantine", "tag": "active"}], "list": ["a", "b"], "m": {"x": 1, "y": "a: b"}}
print("ok" if doc == want else f"got {doc!r}")
PY
)"
check "flow mappings in a block sequence parse correctly" test "$res" = ok

# validate-data.py with PyYAML blocked entirely, as in the job image.
(cd "$T" && python3 -c "
import sys, runpy
sys.modules['yaml'] = None            # 'import yaml' now raises ImportError
sys.argv = ['validate-data.py']
runpy.run_path('scripts/validate-data.py', run_name='__main__')
" >"$SCRATCH/validate.out" 2>&1)
check "validate-data.py passes on the shipped data without PyYAML" test $? -eq 0
tail -3 "$SCRATCH/validate.out" | sed 's/^/    /'

finish yaml-fallback
