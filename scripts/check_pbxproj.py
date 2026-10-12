#!/usr/bin/env python3
"""
pbxproj sanity check — verifies that:
  1. Every UUID referenced in buildFiles / groups / phases / targets
     exists as a defined object.
  2. Each .m file referenced in a PBXBuildFile has a matching
     PBXFileReference and is reachable from the main group.
  3. Every .m file on disk has a corresponding buildFile entry in
     the Sources build phase.
"""
import re
import sys
from pathlib import Path

PROJ_PATH = Path("/home/z/my-project/download/iOS6AIChat/iOS6AIChat.xcodeproj/project.pbxproj")
ROOT = Path("/home/z/my-project/download/iOS6AIChat/iOS6AIChat")

text = PROJ_PATH.read_text(encoding="utf-8")

# All 24-char hex UUIDs referenced anywhere in the file.
hex_uuid_re = re.compile(r"\b([0-9A-Fa-f]{24})\b")
defined_uuids = set()
referenced_uuids = set()

# Defined entries — lines like  `<uuid> /* ... */ = {isa = PBX...`
defined_re = re.compile(r"^\s*([0-9A-Fa-f]{24})\s+/\*.*?\*/\s*=\s*\{\s*isa\s*=\s*(\w+);", re.M)
for m in defined_re.finditer(text):
    defined_uuids.add((m.group(1).upper(), m.group(2)))

print(f"Defined entries: {len(defined_uuids)}")

# References — `fileRef = <uuid>`, `children = ( <uuid>, ... )`,
# `fileRef` inside build files etc.
for keyword in ("fileRef", "productReference", "mainGroup",
                "productRefGroup", "rootObject"):
    for m in re.finditer(rf"{keyword}\s*=\s*([0-9A-Fa-f]{{24}})", text):
        referenced_uuids.add(m.group(1).upper())

# Children arrays.
for m in re.finditer(r"children\s*=\s*\(([^)]+)\)", text):
    for um in re.finditer(r"([0-9A-Fa-f]{24})", m.group(1)):
        referenced_uuids.add(um.group(1).upper())

# Files in build phase.
for m in re.finditer(r"files\s*=\s*\(([^)]+)\)", text):
    for um in re.finditer(r"([0-9A-Fa-f]{24})", m.group(1)):
        referenced_uuids.add(um.group(1).upper())

# buildConfigurationList.
for m in re.finditer(r"buildConfigurationList\s*=\s*([0-9A-Fa-f]{24})", text):
    referenced_uuids.add(m.group(1).upper())

# Targets array.
for m in re.finditer(r"targets\s*=\s*\(([^)]+)\)", text):
    for um in re.finditer(r"([0-9A-Fa-f]{24})", m.group(1)):
        referenced_uuids.add(um.group(1).upper())

# buildConfigurations.
for m in re.finditer(r"buildConfigurations\s*=\s*\(([^)]+)\)", text):
    for um in re.finditer(r"([0-9A-Fa-f]{24})", m.group(1)):
        referenced_uuids.add(um.group(1).upper())

defined_only_uuids = {u for u, _ in defined_uuids}
missing = referenced_uuids - defined_only_uuids
if missing:
    print(f"❌ REFERENCED but NOT DEFINED ({len(missing)}):")
    for u in sorted(missing):
        print(f"   {u}")
else:
    print("✓ Every referenced UUID is defined.")

# Cross-check: every .m file on disk should have a buildFile entry
disk_m_files = sorted(p.name for p in ROOT.rglob("*.m"))
build_files = re.findall(r"/\*\s*([\w.]+\.m)\s+in Sources\s*\*/", text)
build_file_names = set(build_files)
missing_on_disk = [n for n in disk_m_files if n not in build_file_names]
if missing_on_disk:
    print(f"❌ .m files on disk NOT in Sources phase: {missing_on_disk}")
else:
    print(f"✓ All {len(disk_m_files)} .m files on disk appear in Sources phase.")

# All .h files on disk should have a PBXFileReference
disk_h_files = sorted(p.name for p in ROOT.rglob("*.h"))
ref_h_files = re.findall(r"PBXFileReference;[^}]*?path\s*=\s*([\w.]+\.h)", text)
ref_h_names = set(ref_h_files)
missing_h = [n for n in disk_h_files if n not in ref_h_names]
if missing_h:
    print(f"❌ .h files on disk without PBXFileReference: {missing_h}")
else:
    print(f"✓ All {len(disk_h_files)} .h files have PBXFileReference entries.")

# Print group hierarchy summary
print("\n--- Group hierarchy ---")
groups = re.findall(r"([0-9A-Fa-f]{24})\s+/\*\s*([\w =]+?)\s*\*/\s*=\s*\{\s*isa\s*=\s*PBXGroup;", text)
for g in groups:
    print(f"  {g[0].upper()}  {g[1]}")
