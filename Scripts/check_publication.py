#!/usr/bin/env python3
"""Redacted publication checks shared by Git hooks, CI and the DMG gate."""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

EMAIL = re.compile(rb"[a-z0-9._%+-]+@([a-z0-9.-]+\.[a-z]{2,})", re.I)
HOME = re.compile(rb"/Users/(?!runner/|Shared/)[\w.-]+/")
HOST = re.compile(rb"\b(?:jira|vpn)\.[a-z0-9.-]+\.[a-z]{2,}", re.I)
CREDENTIAL = re.compile(rb"""(?im)(?:^|[\s{,(])(?P<keyquote>["']?)(?:username|login|password|passwd|pwd)(?P=keyquote)\s*[:=]\s*(?:["']([^"'\r\n]*)["']|([a-zA-Z0-9._!+/-]+)\s*$)""")
FIXTURES = {b"secret", b"max", b"test", b"test-user", b"fixture", b"fixture-private-password", b"fixture-secret"}
# Code references (not credential assignments) may match the unquoted syntax.
REFERENCES = {b"nil", b"null", b"false", b"true", b"password", b"saved", b"username", b"value"}


def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL)


def findings(data, path, private_terms=(), binary=False):
    issues = set()
    lower = data.lower()
    if any(term in lower or term.decode().encode("utf-16le") in lower or
           term.decode().encode("utf-16be") in lower for term in private_terms):
        issues.add("private value")
    if HOME.search(data):
        issues.add("local home path")
    if binary:
        return issues
    for match in EMAIL.finditer(data.lower()):
        domain = match.group(1)
        if match.group() == b"noreply@github.com":
            continue
        if domain not in (b"users.noreply.github.com", b"2x.png") and not domain.endswith((b".test", b".invalid", b".example")):
            issues.add("email")
    for host in HOST.findall(data.lower()):
        if not host.endswith((b".test", b".invalid", b".example", b".example.com", b".example.org", b".example.net")):
            issues.add("internal endpoint")
    tests = path.startswith(("Tests/", "Scripts/test_"))
    for match in CREDENTIAL.finditer(data):
        _, quoted, unquoted = match.groups()
        value = (quoted if quoted is not None else unquoted).strip()
        if not value or value.startswith((b"$", b"\\(")) or (unquoted and value in REFERENCES):
            continue
        if unquoted and path.endswith((".swift", ".m", ".py", ".h")):
            continue
        if tests and value in FIXTURES:
            continue
        issues.add("literal credential")
    return issues


def check(data, path, terms):
    result = findings(data, path, terms, binary=b"\0" in data)
    if result:
        # Never print the offending line, filename, identity or private list.
        raise ValueError("Publication blocked: " + ", ".join(sorted(result)))


def private_terms():
    file = os.environ.get("OC_PUBLICATION_DENY_FILE")
    if not file:
        return []
    path = Path(file).resolve()
    if path.is_relative_to(Path.cwd().resolve()):
        raise ValueError("Keep the private list outside the checkout")
    return [line.strip().lower() for line in path.read_bytes().splitlines() if line.strip()]


def scan_objects(roots, terms):
    # Walk every reachable snapshot and tag, including intermediate commits.
    # Tree entries are checked separately to catch renamed, unchanged blobs.
    rows = git("rev-list", "--objects", *roots, "--").splitlines()
    # cat-file streams one object at a time, including annotated tag objects.
    metadata = bytearray()
    with subprocess.Popen(["git", "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as proc:
        for row in rows:
            oid, _, raw_path = row.partition(b" ")
            path = os.fsdecode(raw_path)
            check(raw_path, "", terms)
            proc.stdin.write(oid + b"\n")
            proc.stdin.flush()
            _, kind, size = proc.stdout.readline().split()
            data = proc.stdout.read(int(size))
            proc.stdout.read(1)
            if kind == b"tree":
                offset = 0
                while offset < len(data):
                    end = data.index(b"\0", offset)
                    name = data[offset:end].split(b" ", 1)[1]
                    check(name, "", terms)
                    if name.lower().endswith((b".p12", b".pfx", b".keychain-db", b".mobileconfig")) or name == b".env":
                        raise ValueError("Private file type")
                    offset = end + 1 + len(oid) // 2
                continue
            if kind in (b"commit", b"tag"):
                metadata.extend(data + b"\n")
                for line in data.partition(b"\n\n")[0].splitlines():
                    if line.startswith((b"author ", b"committer ", b"tagger ")):
                        identity(line)
            check(data, path, terms)
        proc.stdin.close()
    if metadata:
        leaks("stdin", data=metadata)
    print(f"Checked {len(rows)} Git objects")


def identity(line):
    match = re.search(rb"<([^<>]+)>", line)
    if not match or not re.fullmatch(rb"(?:[^@<>\s]+@users\.noreply\.github\.com|noreply@github\.com)", match[1], re.I):
        raise ValueError("Use a GitHub noreply identity for public history")


def leaks(*args, data=None):
    subprocess.run(["gitleaks", *args, "--redact=100", "--no-banner", "--exit-code=1"],
                   input=data, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["staged", "message", "history", "push"])
    parser.add_argument("refs", nargs="*")
    args = parser.parse_args()
    terms = private_terms()
    if args.mode == "message":
        message = Path(args.refs[0]).read_bytes()
        check(message, "", terms)
        leaks("stdin", data=message)
        return
    if args.mode == "staged":
        for var in ["GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT"]:
            ident = git("var", var)
            identity(ident)
            check(ident, "", terms)
        scan_objects([git("write-tree").decode().strip()], terms)
        leaks("git", "--pre-commit", "--staged", ".")
        return
    roots = args.refs or ["HEAD"]
    if args.mode == "push":
        roots = []
        for line in sys.stdin.buffer:
            local, sha, remote, _ = line.split()
            check(local + b" " + remote, "", terms)
            if sha.strip(b"0"):
                roots.append(sha.decode())
        if not roots:
            return
    roots = [git("rev-parse", "--verify", "--end-of-options", r).decode().strip() for r in roots]
    scan_objects(roots, terms)
    leaks("git", "--log-opts=--full-history -m " + " ".join(roots), ".")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(str(error) if isinstance(error, ValueError) else "Publication check failed or scanner unavailable", file=sys.stderr)
        sys.exit(1)
