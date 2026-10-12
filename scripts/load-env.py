#!/usr/bin/env python3
"""Read the simple KEY=value Compose env file without evaluating shell code."""
import sys

for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\r\n")
    if not line or line.lstrip().startswith("#"):
        continue
    key, sep, value = line.partition("=")
    if not sep or not key.replace("_", "").isalnum() or not (key[0].isalpha() or key[0] == "_"):
        raise SystemExit(f"Invalid .env entry: {line.split('=', 1)[0]}")
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        quote = value[0]
        value = value[1:-1]
    elif " #" in value:
        value = value.split(" #", 1)[0]
    sys.stdout.buffer.write(key.encode() + b"=" + value.encode() + b"\0")
