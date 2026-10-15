#!/usr/bin/env python3
"""Checks plugin.toml against the repository: schema, semver, referenced files, block ids."""
import re
import sys
import tomllib

SEMVER = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(-((0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?$"
)

with open("plugin.toml", "rb") as f:
    manifest = tomllib.load(f)

errors = []
if manifest.get("schema") != 1:
    errors.append("schema must be 1")
if not SEMVER.match(str(manifest.get("version", ""))):
    errors.append(f"version {manifest.get('version')!r} is not semver (X.Y.Z or X.Y.Z-rc1)")

files = [manifest.get("host"), manifest.get("window")] + list(manifest.get("styles", []))
for name in files:
    if not name:
        continue
    try:
        open(name, "rb").close()
    except OSError:
        errors.append(f"{name} (named in plugin.toml) does not exist")

try:
    host = open(manifest["host"], encoding="utf-8").read()
except (KeyError, OSError):
    host = ""
for block in manifest.get("blocks", []):
    if not re.search(r'tern\.block\.define\(\s*"%s"' % re.escape(block["id"]), host):
        errors.append(f'block "{block["id"]}" is not defined in {manifest.get("host")}')

if errors:
    print("\n".join("plugin.toml: " + e for e in errors))
    sys.exit(1)
print(f"plugin.toml ok: {manifest['id']} {manifest['version']}")
