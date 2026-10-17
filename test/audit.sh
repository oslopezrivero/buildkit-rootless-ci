#!/usr/bin/env bash
# Checks audit-dind.py against the fixtures in test/audit/.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/audit-dind.py test/audit/clean >/dev/null 2>&1 || { echo "FAIL: clean fixture flagged"; exit 1; }
out=$(python3 scripts/audit-dind.py test/audit 2>/dev/null) && { echo "FAIL: findings not reported"; exit 1; }
expected=$'test/audit/dind/.gitlab-ci.yml:4\ntest/audit/dind/.gitlab-ci.yml:6\ntest/audit/sock/.gitlab-ci.yml:3'
got=$(cut -d: -f1-2 <<<"$out")
[[ "$got" == "$expected" ]] || { echo "FAIL: unexpected findings:"; echo "$out"; exit 1; }
echo "ok: audit-dind.py flags dind, docker build and the socket; ignores comments and quoted text"
