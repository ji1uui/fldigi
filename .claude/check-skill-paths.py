#!/usr/bin/env python3
"""Skill の paths グロブが実際のリポジトリに当たっているかを見る。

paths はグロブなので、当たらなくても当たりすぎても **何のエラーも出ない**。
Skill が黙って発動しないだけである。だから機械で見る。

    python3 .claude/check-skill-paths.py

確認するのは 3 点。

  1. lazarus/ の外に当たっていないか
     上流の C++ と doxygen の画像が大量にあり、緩いグロブは簡単にそこへ届く。
  2. 1 件も当たらないグロブが無いか
     綴り誤りか、ファイルが消えたか、名前が変わったかのいずれか。
  3. 大文字小文字
     glob は Linux / macOS で **区別する**。このリポジトリは PascalCase なので、
     小文字の *modem* では ModemDSP.pas に当たらない。
"""
import fnmatch
import pathlib
import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML が要ります: pip install pyyaml")

ROOT = pathlib.Path(__file__).resolve().parent.parent
FILES = subprocess.run(
    ["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True
).stdout.split()

problems = 0
for skill in sorted((ROOT / ".claude" / "skills").iterdir()):
    doc = skill / "SKILL.md"
    if not doc.is_file():
        continue
    meta = yaml.safe_load(doc.read_text(encoding="utf-8").split("---")[1])
    globs = meta.get("paths")
    if not globs:
        print(f"{skill.name:26} paths なし (常に候補)")
        continue
    if isinstance(globs, str):
        globs = [g.strip() for g in globs.split(",")]

    hits, dead = set(), []
    for g in globs:
        m = [f for f in FILES if fnmatch.fnmatch(f, g)]
        if not m:
            dead.append(g)
        hits.update(m)
    outside = sorted(f for f in hits if not f.startswith("lazarus/"))

    print(f"{skill.name:26} {len(hits):3d} 件")
    if dead:
        problems += 1
        print("    !! 1 件も当たらないグロブ (綴り誤り / 大文字小文字 / 削除):")
        for g in dead:
            print(f"       {g}")
    if outside:
        problems += 1
        print(f"    !! lazarus/ の外に {len(outside)} 件当たっている:")
        for f in outside[:5]:
            print(f"       {f}")

print()
if problems:
    print(f"{problems} 件の問題。該当する SKILL.md の paths を直すこと。")
    sys.exit(1)
print("すべてのグロブが lazarus/ 内に当たっている。")
