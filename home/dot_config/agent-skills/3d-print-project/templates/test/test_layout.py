"""The project's layout: tooling, ignored state, and docs that point at real things."""
import re
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = [ROOT / "README.md", ROOT / "AGENTS.md",
        *(p for p in (ROOT / "docs").rglob("*.md") if "superpowers" not in p.parts)]


def test_test_dependencies_are_declared_and_locked():
    py = tomllib.loads((ROOT / "pyproject.toml").read_text())
    dev = " ".join(py["dependency-groups"]["dev"])
    for dep in ("pytest", "pytest-xdist", "trimesh", "numpy", "shapely", "rtree", "scipy", "networkx"):
        assert dep in dev, f"{dep} not in the dev group"
    assert (ROOT / "uv.lock").exists()
    assert "--with" not in (ROOT / "scripts/test.sh").read_text(), "test.sh should use the locked environment"


def test_local_state_is_ignored():
    lines = [l.strip() for l in (ROOT / ".gitignore").read_text().splitlines() if l.strip() and not l.startswith("#")]
    for entry in (".claude/", ".venv/", ".pytest_cache/", "__pycache__/", "stl/", "renders/", "references/", ".superpowers/"):
        assert entry in lines, f"{entry} not ignored"


def test_every_doc_link_resolves():
    broken = []
    for doc in (d for d in DOCS if d.exists()):
        for target in re.findall(r"\]\(([^)#\s]+)(?:#[^)]*)?\)", doc.read_text()):
            if "://" not in target and not (doc.parent / target).exists():
                broken.append(f"{doc.relative_to(ROOT)} -> {target}")
    assert not broken, "broken links:\n" + "\n".join(broken)


def test_docs_name_real_paths():
    missing = []
    for doc in (d for d in DOCS if d.exists()):
        for path in re.findall(r"`((?:parts|params|lib|scripts|test|docs)/[\w./-]*)`", doc.read_text()):
            if "*" not in path and not (ROOT / path.rstrip("/")).exists():
                missing.append(f"{doc.relative_to(ROOT)}: {path}")
    assert not missing, "paths that don't exist:\n" + "\n".join(missing)


def test_readme_and_agents_exist():
    readme = (ROOT / "README.md").read_text()
    for must in ("bash scripts/test.sh", "scripts/export.py", "scripts/slice.py", "## Layout"):
        assert must in readme, f"README.md lacks {must}"
    assert (ROOT / "AGENTS.md").exists()


def test_printing_doc_lists_every_coupon():
    from scripts.print_parts import hosts
    doc = (ROOT / "docs/build/printing.md").read_text()
    coupons = {n for n in hosts() if n.startswith("coupon_")}
    assert all(f"`{c}`" in doc for c in coupons), coupons
