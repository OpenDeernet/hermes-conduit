#!/usr/bin/env python3
"""Fail when app text is set in a fixed point size.

`.font(.system(size: 11))` ignores the user's Text Size, so a label set that
way stays small at accessibility sizes while the text around it grows (#830).
Text uses a text style (`.caption2`, `.footnote`, ...) or a size scaled with
`@ScaledMetric(relativeTo:)` instead.

Text-level, like check-sheet-environment.py: a `Text(` whose modifier chain
(the same line, then each following line that starts with `.`) sets
`.system(size:` to a number literal is reported. Glyphs in fixed-size frames
(`Image(systemName:)` in a 32 pt circle) are left alone, and a size computed
from a scaled metric or a frame (`size * 0.42`) passes.

Text that really must keep its size, such as the small and large "A" around
the chat text size slider, says why on the line above:
`// Fixed size: <reason>`.

Usage: check-fixed-text-sizes.py [--repo-root DIR]
"""

import argparse
import os
import re
import sys

SOURCE_DIRS = ("Conduit",)
TEXT_START = re.compile(r"\bText\s*\(")
FIXED_SIZE = re.compile(r"\.system\(size:\s*\d")
EXEMPTION = "// Fixed size:"


def find_problems(sources):
    """sources: {path: text}. Returns ["path:line: ..."] for each fixed text size."""
    problems = []
    for path, text in sorted(sources.items()):
        lines = text.splitlines()
        for index, line in enumerate(lines):
            if not TEXT_START.search(line):
                continue
            exempt = index > 0 and EXEMPTION in lines[index - 1]
            chain = [(index, line[TEXT_START.search(line).start():])]
            follow = index + 1
            while follow < len(lines) and lines[follow].lstrip().startswith("."):
                chain.append((follow, lines[follow]))
                follow += 1
            for number, part in chain:
                if FIXED_SIZE.search(part) and not exempt:
                    problems.append(
                        f"{path}:{number + 1}: Text in a fixed point size ignores Text Size; "
                        "use a text style or @ScaledMetric(relativeTo:), or say why "
                        f"with '{EXEMPTION} ...' on the line above the Text")
    return problems


def load_sources(repo_root):
    sources = {}
    for directory in SOURCE_DIRS:
        for root, _, files in os.walk(os.path.join(repo_root, directory)):
            for name in files:
                if name.endswith(".swift"):
                    path = os.path.join(root, name)
                    with open(path, encoding="utf-8") as handle:
                        sources[os.path.relpath(path, repo_root)] = handle.read()
    return sources


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", default=".")
    args = parser.parse_args()
    sources = load_sources(args.repo_root)
    problems = find_problems(sources)
    if problems:
        print(f"FAIL: {len(problems)} fixed text size(s):")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print(f"OK: no fixed text sizes in {len(sources)} Swift files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
