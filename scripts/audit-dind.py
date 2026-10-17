#!/usr/bin/env python3
"""Flag CI pipelines that build with Docker-in-Docker or a host Docker socket.

Scans GitLab CI files under one or more directories (for example, a folder with every
repository of a group checked out) and reports risky patterns. Comments are stripped
before matching, so a template that only *mentions* docker:dind is not a false positive.

Usage:
    audit-dind.py <dir> [<dir> ...]

Exit code: 0 = clean, 1 = findings, 2 = usage error. Suitable for a scheduled CI job.
"""
import re
import sys
from pathlib import Path

PATTERNS = [
    ("docker:dind service", re.compile(r"docker:[\w.\-]*dind")),
    ("privileged job", re.compile(r"^\s*privileged\s*[:=]\s*true\b", re.I)),
    ("host Docker socket", re.compile(r"/var/run/docker\.sock")),
    ("docker build via CLI", re.compile(r"^\s*-?\s*docker\s+(?:buildx\s+)?build\b")),
]

CI_GLOBS = (".gitlab-ci.yml", "*.gitlab-ci.yml", ".gitlab/ci/*.yml", "ci/*.yml")
SKIP_DIRS = {".git", "node_modules", "vendor"}


def strip_comment(line: str) -> str:
    """Drop a YAML comment, ignoring '#' inside quotes."""
    out, quote = [], None
    for ch in line:
        if quote:
            if ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
        elif ch == "#":
            break
        out.append(ch)
    return "".join(out)


def ci_files(root: Path):
    seen = set()
    for pattern in CI_GLOBS:
        for path in root.rglob(pattern):
            if path.is_file() and not SKIP_DIRS.intersection(path.parts) and path not in seen:
                seen.add(path)
                yield path


def scan(root: Path):
    for path in sorted(ci_files(root)):
        for lineno, raw in enumerate(path.read_text(errors="replace").splitlines(), 1):
            line = strip_comment(raw)
            for label, rx in PATTERNS:
                if rx.search(line):
                    yield path, lineno, label, raw.strip()


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    findings = [f for arg in argv[1:] for f in scan(Path(arg))]
    for path, lineno, label, text in findings:
        print(f"{path}:{lineno}: {label}: {text}")
    print(f"{len(findings)} finding(s)", file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
