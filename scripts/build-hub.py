#!/usr/bin/env python3
"""Writes hub/index.json: every plugin under hub/plugins/ with the SHA-256 and size of each of its files.

EditMax reads that index (Settings ▸ Plugins ▸ Hub), downloads the files it lists and checks each hash, so the index
must be rebuilt whenever a plugin's files change. `--check` writes nothing and fails when the index is out of date.
"""
import hashlib, json, re, sys
from pathlib import Path

HUB = Path(__file__).resolve().parent.parent / "hub"
SLUG = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
SKIP = {".DS_Store"}


def frontmatter_name(skill: Path) -> str:
    text = (skill / "SKILL.md").read_text(encoding="utf-8")
    m = re.match(r"^---\s*\n(.*?)\n---", text, re.S)
    name = re.search(r"^name:\s*(.+)$", m.group(1), re.M) if m else None
    return name.group(1).strip().strip("\"'") if name else skill.name


def listing(folder: Path) -> dict:
    if not SLUG.match(folder.name):
        sys.exit(f"{folder.name}: a plugin's folder is lower-case letters, digits and hyphens")
    manifest = json.loads((folder / "plugin.json").read_text(encoding="utf-8"))
    for key in ("name", "version", "description"):
        if not manifest.get(key):
            sys.exit(f"{folder.name}/plugin.json needs \"{key}\"")
    if manifest["name"] != folder.name:
        sys.exit(f"{folder.name}/plugin.json: \"name\" must be the folder's name")
    files = []
    for f in sorted(p for p in folder.rglob("*") if p.is_file() and p.name not in SKIP):
        if f.is_symlink():
            sys.exit(f"{f}: links are not allowed in a hub plugin")
        data = f.read_bytes()
        files.append({"path": f.relative_to(folder).as_posix(), "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
    skills = sorted(frontmatter_name(d) for d in (folder / "skills").iterdir() if (d / "SKILL.md").is_file()) if (folder / "skills").is_dir() else []
    servers = []
    for source in (manifest.get("mcpServers"), json.loads((folder / ".mcp.json").read_text()) if (folder / ".mcp.json").is_file() else None):
        if isinstance(source, dict):
            servers = sorted((source.get("mcpServers") or source).keys())
            break
    out = {"id": folder.name, "name": manifest.get("title") or folder.name.replace("-", " ").capitalize(), "description": manifest["description"],
           "version": manifest["version"], "author": manifest["author"]["name"] if isinstance(manifest.get("author"), dict) else manifest.get("author", ""),
           "skills": skills, "servers": servers, "path": f"plugins/{folder.name}", "files": files}
    if manifest.get("homepage"):
        out["homepage"] = manifest["homepage"]
    return out


def main() -> None:
    plugins = [listing(d) for d in sorted((HUB / "plugins").iterdir()) if d.is_dir()]
    text = json.dumps({"name": "EditMax Hub", "plugins": plugins}, indent=2, ensure_ascii=False) + "\n"
    target = HUB / "index.json"
    if "--check" in sys.argv:
        if not target.is_file() or target.read_text(encoding="utf-8") != text:
            sys.exit("hub/index.json is out of date: run python3 scripts/build-hub.py")
        print(f"hub/index.json is current ({len(plugins)} plugins)")
        return
    target.write_text(text, encoding="utf-8")
    print(f"hub/index.json: {len(plugins)} plugins, {sum(len(p['files']) for p in plugins)} files")


if __name__ == "__main__":
    main()
