#!/usr/bin/env python3
"""
三平台版本一致性检查
v13.0.22 起强制执行：发布前必须跑本脚本通过。

检查项：
1. 三个 SKILL.md 的 version 字段是否一致
   - ./SKILL.md (Hermes 主技能 / 仓库根目录)
   - ./opencode/SKILL.md (OpenCode 适配层)
   - ./dsh/SKILL.md (DeepSeek Harness 适配层)
2. run_cli.py 各 agent 配置有无禁用的 prompt_mode="file" + use_stdin=False 组合（mimo bug 重放防护）
3. Version History 最新条目版本号是否等于 frontmatter version

用法：
    python scripts/check_version_consistency.py [--repo REPO_PATH]

退出码：
    0 = 全部一致
    1 = 有不一致
"""

import sys
import re
from pathlib import Path


def read_frontmatter_version(skill_path: Path) -> str | None:
    if not skill_path.exists():
        return None
    for line in skill_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("version:"):
            return line.split(":", 1)[1].strip()
    return None


def read_title_version(skill_path: Path) -> str | None:
    if not skill_path.exists():
        return None
    content = skill_path.read_text(encoding="utf-8")
    m = re.search(r"# .*?v(\d+\.\d+\.\d+)", content)
    return m.group(1) if m else None


def read_version_history_latest(skill_path: Path) -> str | None:
    if not skill_path.exists():
        return None
    content = skill_path.read_text(encoding="utf-8")
    matches = re.findall(r"### v(\d+\.\d+\.\d+)", content)
    return matches[0] if matches else None


def check_run_cli_mimo(run_cli_path: Path) -> tuple[bool, str]:
    if not run_cli_path.exists():
        return True, "N/A (file not found)"
    content = run_cli_path.read_text(encoding="utf-8")
    m = re.search(r'"mimo":\s*\{([^}]+)\}', content)
    if not m:
        return False, "mimo block not found"
    block = m.group(1)
    has_prompt_mode = 'prompt_mode' in block
    has_use_stdin_true = 'use_stdin' in block and 'True' in block
    if has_prompt_mode and not has_use_stdin_true:
        return False, "DANGER: mimo has prompt_mode but use_stdin not True — mimo -f is file attach, not message flag"
    if has_use_stdin_true:
        return True, "OK (use_stdin=True)"
    return False, "mimo config unclear"


def main() -> int:
    repo = Path(sys.argv[sys.argv.index("--repo") + 1]) if "--repo" in sys.argv else Path(__file__).parent.parent

    skills = {
        "Hermes/主仓库": repo / "SKILL.md",
        "OpenCode适配层": repo / "opencode" / "SKILL.md",
        "DSH适配层": repo / "dsh" / "SKILL.md",
    }

    print("=" * 60)
    print("三平台版本一致性检查")
    print(f"仓库: {repo}")
    print("=" * 60)

    all_ok = True
    versions = {}

    for name, path in skills.items():
        v = read_frontmatter_version(path)
        tv = read_title_version(path)
        hv = read_version_history_latest(path)
        versions[name] = {"frontmatter": v, "title": tv, "history": hv}

        status = "OK" if v else "MISSING"
        print(f"\n[{status}] {name}")
        print(f"   frontmatter: {v or 'MISSING'}")
        print(f"   title:       {tv or 'MISSING'}")
        print(f"   history 1st: {hv or 'MISSING'}")

        if not v:
            all_ok = False
        elif tv and tv != v:
            print(f"   WARN: title 版本 ({tv}) != frontmatter ({v})")
            all_ok = False
        elif hv and hv != v:
            print(f"   WARN: history 首条 ({hv}) != frontmatter ({v})")
            all_ok = False

    ver_set = {v["frontmatter"] for v in versions.values() if v["frontmatter"]}
    print("\n" + "=" * 60)
    if len(ver_set) == 1:
        print(f"[OK] 三平台版本一致: {ver_set.pop()}")
    else:
        print(f"[FAIL] 三平台版本不一致: {ver_set}")
        all_ok = False

    run_cli = repo / "scripts" / "run_cli.py"
    ok, detail = check_run_cli_mimo(run_cli)
    icon = "OK" if ok else "FAIL"
    print(f"\n[{icon}] run_cli.py mimo 配置: {detail}")
    if not ok:
        all_ok = False

    print("\n" + "=" * 60)
    if all_ok:
        print("[PASS] 全部通过，可以发布")
        return 0
    else:
        print("[FAIL] 检查未通过，修复后再发布")
        return 1


if __name__ == "__main__":
    sys.exit(main())
