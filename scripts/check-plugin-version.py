#!/usr/bin/env python3
"""Fail when Conduit's recommended plugin version is behind the plugin.

NotifierPluginStatus.recommendedVersion decides when Conduit offers the
one-tap plugin update: only a host below it sees the notice. It is a constant
someone has to raise by hand, so plugin releases 0.30-0.41 shipped while it
still said 0.29.0 and nobody was told to update. This check compares it with
the version on hermes-conduit-notifier's main branch (what an update installs)
and fails until they match.

Behind main means users miss the notice; ahead of main means an update can't
reach the version Conduit asks for, so the notice would never go away. Merge
the plugin first, then raise the constant in Conduit.

If GitHub can't be reached the check warns and passes, so an outage doesn't
block every PR.
"""

import argparse
import os
import re
import sys
import time
import urllib.request

PLUGIN_YAML_URL = (
    "https://raw.githubusercontent.com/kaishi00/hermes-conduit-notifier/main/plugin.yaml")
SWIFT_FILE = os.path.join("Conduit", "Services", "NotifierPluginStatus.swift")

RECOMMENDED_RE = re.compile(r'static\s+let\s+recommendedVersion\s*=\s*"([^"]+)"')
YAML_VERSION_RE = re.compile(r'^version:\s*["\']?([^"\'\s#]+)', re.MULTILINE)


def recommended_version(swift_source):
    match = RECOMMENDED_RE.search(swift_source)
    return match.group(1) if match else None


def plugin_version(plugin_yaml):
    match = YAML_VERSION_RE.search(plugin_yaml)
    return match.group(1) if match else None


def parts(version):
    core = version.split("-", 1)[0]
    return tuple(int(part) for part in core.split("."))


def compare(recommended, latest):
    """Returns None when they match, else the problem to report."""
    if parts(recommended) == parts(latest):
        return None
    where = "behind" if parts(recommended) < parts(latest) else "ahead of"
    return (
        f"NotifierPluginStatus.recommendedVersion is {recommended}, {where} the "
        f"plugin on hermes-conduit-notifier main ({latest}). Set it to "
        f'"{latest}" in {SWIFT_FILE} so hosts below it are offered the update.')


def fetch(url, attempts=3):
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=15) as response:
                return response.read().decode("utf-8")
        except OSError as error:
            if attempt == attempts - 1:
                raise
            print(f"fetch failed ({error}), retrying", file=sys.stderr)
            time.sleep(2 ** attempt)
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--plugin-yaml",
                        help="read the plugin's plugin.yaml from this file instead of GitHub")
    args = parser.parse_args(argv)

    with open(os.path.join(args.repo_root, SWIFT_FILE), encoding="utf-8") as fh:
        recommended = recommended_version(fh.read())
    if not recommended:
        print(f"error: no recommendedVersion found in {SWIFT_FILE}", file=sys.stderr)
        return 1

    if args.plugin_yaml:
        with open(args.plugin_yaml, encoding="utf-8") as fh:
            yaml_text = fh.read()
    else:
        try:
            yaml_text = fetch(PLUGIN_YAML_URL)
        except OSError as error:
            print(f"::warning::Couldn't read the plugin version from GitHub ({error}); "
                  "recommendedVersion not checked.")
            return 0

    latest = plugin_version(yaml_text)
    if not latest:
        print("error: no version: line in the plugin's plugin.yaml", file=sys.stderr)
        return 1

    problem = compare(recommended, latest)
    if problem:
        print(f"::error file={SWIFT_FILE}::{problem}")
        return 1
    print(f"recommendedVersion {recommended} matches the plugin on main.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
