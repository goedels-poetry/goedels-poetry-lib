
#!/usr/bin/env python3
"""Regenerate Init.lean files for subdirectories under GoedelsPoetryLib.

The root Init.lean is maintained separately because no new top-level modules
will be added. Run this in CI to keep subdirectory Init.lean files in sync.

Requires Python >=3.10,<4.0
"""
import sys
from pathlib import Path

# Validate Python version
if sys.version_info < (3, 10) or sys.version_info >= (4, 0):
    sys.exit("Error: Python >=3.10,<4.0 is required")

root = Path("GoedelsPoetryLib")

for d in sorted([p for p in root.rglob("*") if p.is_dir()]):
    imports = []

    for f in sorted(d.glob("*.lean")):
        if f.name != "Init.lean":
            mod = ".".join(f.with_suffix("").parts)
            imports.append(f"import {mod}")

    for sd in sorted(d.iterdir()):
        if sd.is_dir() and (sd / "Init.lean").exists():
            mod = ".".join(sd.parts)
            imports.append(f"import {mod}.Init")

    if imports:
        content = "-- auto-generated; do not edit manually\n" + "\n".join(imports) + "\n"
        init_file = d / "Init.lean"
        
        # Validate content before writing
        if not content.strip():
            sys.exit(f"Error: Generated Init.lean content for {d} is empty")
        
        # Basic validation: check that content has proper structure
        lines = content.split('\n')
        if len(lines) < 2 or not lines[0].startswith("-- auto-generated"):
            sys.exit(f"Error: Generated Init.lean for {d} has invalid format")
        
        init_file.write_text(content)
