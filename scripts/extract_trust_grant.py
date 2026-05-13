#!/usr/bin/env python3
"""Extract ClickOnce trust grant from a Wine user.reg into a .reg import file.

Captures the IsFullTrust + ApplicationTrust values (and their PackageMetadata
section headers) and emits a Unicode-format .reg file (Windows Registry Editor
Version 5.00) that wine regedit /S can import into a fresh prefix.

Usage:  extract_trust_grant.py <path-to-user.reg> > trust-grant.reg
"""
import sys, re

p = sys.argv[1]
with open(p, "r", errors="replace") as f:
    raw = f.read().splitlines()

BACKSLASH = "\\"

def join_continuation(lines, i):
    """Reassemble a multi-line continuation (`\\` at EOL) starting at lines[i]."""
    parts = []
    while i < len(lines):
        ln = lines[i].rstrip()
        if ln.endswith(BACKSLASH):
            parts.append(ln[:-1])
            i += 1
        else:
            parts.append(ln)
            i += 1
            break
    return "".join(parts), i

# Find the two value lines along with their enclosing section headers.
sections = []  # list of (header_section, full_value_line)
current = None
i = 0
while i < len(raw):
    s = raw[i].rstrip()
    if s.startswith("[") and "]" in s:
        # Drop the trailing " <timestamp>" Wine appends.
        current = s[: s.index("]") + 1].strip("[]")
        i += 1
        continue
    if '!IsFullTrust"=' in s or '!ApplicationTrust"=' in s:
        full, ni = join_continuation(raw, i)
        sections.append((current, full))
        i = ni
        continue
    i += 1

# Clean the hex byte list: strip all whitespace, leave only comma-separated
# 2-hex-digit pairs. Wine's .reg parser accepts this format directly.
def normalize(value_line):
    head, body = value_line.split("=hex:", 1)
    bytes_only = re.findall(r"[0-9a-fA-F]{2}", body)
    # Re-break into 32-byte lines with `,\` continuation for readability and
    # to keep individual lines under typical parser limits.
    lines = []
    chunk = 25
    for k in range(0, len(bytes_only), chunk):
        seg = ",".join(bytes_only[k : k + chunk])
        if k == 0:
            lines.append(f"{head}=hex:{seg}")
        else:
            # Continuation lines indented with 2 spaces, prefixed with comma.
            lines.append(f"  {seg}")
    # Join with `\<newline>` between segments
    return ",\\\n".join(lines)

# Emit Unicode-format .reg file.
out = ["Windows Registry Editor Version 5.00", ""]
for header, value in sections:
    # Wine user.reg uses implicit HKCU root + doubled backslashes; rewrite to
    # absolute HKEY_CURRENT_USER\... with single backslashes (.reg format).
    h = header.replace("\\\\", "\\")
    out.append(f"[HKEY_CURRENT_USER\\{h}]")
    out.append(normalize(value))
    out.append("")

# Trailing blank line — .reg parsers expect end-of-file marker.
print("\n".join(out))
