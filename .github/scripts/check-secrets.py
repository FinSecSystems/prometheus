#!/usr/bin/env python3
"""Scan the lines being added by this commit for credentials.

Reads `git diff --cached` (added lines only, so existing secrets are not re-reported).
Files covered by git-crypt (.gitattributes `filter=git-crypt`) are stored encrypted, so they are not scanned for
secrets; instead the staged blob must really start with the GITCRYPT magic, otherwise the commit is blocked.
Add `# allow-secret` to a line to accept a false positive.
Exit code 1 blocks the commit.

Usage: check-secrets.py            scan the staged changes (pre-commit)
       check-secrets.py --range A..B   scan the changes between two revisions (CI; no git-crypt key needed) Values are never printed.
"""
import re
import subprocess
import sys

KEY = r"[A-Za-z0-9_.-]*(?:PASSWORD|PASSWD|SECRET|TOKEN|PRIVATE_?KEY|API_?KEY|ACCESS_?KEY|CREDENTIALS?)[A-Za-z0-9_.-]*"
ASSIGN = re.compile(rf"^\s*(?:export\s+)?-?\s*['\"]?({KEY})['\"]?\s*[:=]\s*['\"]?([^\s'\"#]+)", re.I)
PATTERNS = {
    "private key block": re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY"),
    "AWS access key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "GitHub token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    "Slack token": re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    "Cloudflare/JWT-like token": re.compile(r"\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}"),
    "credentials in URL": re.compile(r"[a-z]+://[^/\s:@${}]+:[^/\s@${}]{3,}@"),
}
PLACEHOLDER = re.compile(r"^(\$\{?[A-Za-z_]|<|changeme|change-me|example|xxx+|\*+|none|null|false|true|secret|password|todo|your[-_])", re.I)
SKIP_FILES = re.compile(r"(^|/)(\.env\.example|[^/]*\.example|[^/]*\.sample|check-secrets\.py)$|^docs/|\.md$")

def git(*args):
    return subprocess.run(["git", *args], capture_output=True, errors="replace", text=True).stdout


def crypt_files(files):
    """Subset of files whose filter attribute is git-crypt."""
    if not files:
        return set()
    out = subprocess.run(["git", "check-attr", "-z", "filter", "--stdin"], input="\0".join(files) + "\0",
                         capture_output=True, text=True).stdout.split("\0")
    return {out[i] for i in range(0, len(out) - 2, 3) if out[i + 2] == "git-crypt"}


RANGE = sys.argv[sys.argv.index("--range") + 1] if "--range" in sys.argv else None
# staged: compare the index; range: compare revisions without textconv (ciphertext stays ciphertext)
DIFF_ARGS = [RANGE, "--no-textconv"] if RANGE else ["--cached"]
HEAD_REV = RANGE.split("..")[-1] if RANGE else ""

staged = [f for f in git("diff", *DIFF_ARGS, "--name-only", "--diff-filter=ACMR").splitlines() if f]
encrypted = crypt_files(staged)
unencrypted = []
for f in encrypted:
    blob = subprocess.run(["git", "cat-file", "-p", f"{HEAD_REV}:{f}"], capture_output=True).stdout
    if not blob.startswith(b"\0GITCRYPT"):
        unencrypted.append(f)

diff = subprocess.run(["git", "diff", *DIFF_ARGS, "-U0", "--no-color", "--diff-filter=ACMR"],
                      capture_output=True, text=True, errors="replace").stdout
found, cur = [], None
for line in diff.splitlines():
    if line.startswith("+++ b/"):
        cur = line[6:]
    elif line.startswith("+") and not line.startswith("+++") and cur and cur not in encrypted and not SKIP_FILES.search(cur):
        text = line[1:]
        if "allow-secret" in text or text.lstrip().startswith("#"):
            continue
        m = ASSIGN.match(text)
        if m and len(m.group(2)) >= 6 and not PLACEHOLDER.match(m.group(2)):
            found.append((cur, f"{m.group(1)} has a literal value"))
        for name, rx in PATTERNS.items():
            if rx.search(text):
                found.append((cur, name))

for f in sorted(unencrypted):
    found.append((f, "covered by git-crypt but staged UNENCRYPTED (is the repo unlocked / git-crypt installed?)"))

for f, why in sorted(set(found)):
    print(f"SECRET? {f}: {why}")
if found:
    print("\nCommit blocked. Move the value to an untracked env file / Docker secret and commit a placeholder,")
    print("or append '# allow-secret' to the line if it is a false positive.")
sys.exit(1 if found else 0)
