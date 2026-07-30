#!/usr/bin/env python3
"""Fail-closed structural verifier for SEMIProviderKit.

This checks the SwiftPM product/target graph and source import boundaries. It does
not replace build or test execution; it detects architecture drift that compilers
may otherwise permit through accidental target dependencies.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

EXPECTED_PRODUCTS = {
    "SEMIProviderCore": ("SEMIProviderCore",),
    "SEMIProviderRuntime": ("SEMIProviderRuntime",),
    "SEMIProviderApple": ("SEMIProviderApple",),
}
EXPECTED_TARGETS = {
    "SEMIProviderCore": ("regular", ()),
    "SEMIProviderRuntime": ("regular", ("SEMIProviderCore",)),
    "SEMIProviderApple": ("regular", ("SEMIProviderCore",)),
    "SEMIProviderCoreTests": ("test", ("SEMIProviderCore",)),
    "SEMIProviderRuntimeTests": (
        "test",
        ("SEMIProviderCore", "SEMIProviderRuntime"),
    ),
    "SEMIProviderAppleTests": (
        "test",
        ("SEMIProviderApple", "SEMIProviderCore"),
    ),
}
ALLOWED_IMPORTS = {
    "SEMIProviderCore": {"Foundation"},
    "SEMIProviderRuntime": {
        "Darwin",
        "Foundation",
        "SEMIProviderCore",
    },
    "SEMIProviderApple": {
        "AppKit",
        "CryptoKit",
        "Foundation",
        "Network",
        "Security",
        "SEMIProviderCore",
    },
}
IMPORT_PATTERN = re.compile(r"^\s*(?:@_\w+\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)\b")


def dependency_name(value: dict[str, Any]) -> str | None:
    for key in ("byName", "target", "product"):
        raw = value.get(key)
        if isinstance(raw, list) and raw and isinstance(raw[0], str):
            return raw[0]
    return None


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def verify(root: Path) -> list[str]:
    errors: list[str] = []
    package_file = root / "Package.swift"
    source_root = root / "Sources"

    if not package_file.is_file():
        return [f"Package.swift is missing at {package_file}"]
    if not source_root.is_dir():
        return [f"Sources directory is missing at {source_root}"]

    try:
        result = subprocess.run(
            ["swift", "package", "dump-package", "--package-path", str(root)],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return ["Swift toolchain is unavailable; package graph was not verified"]

    if result.returncode != 0:
        return [
            "swift package dump-package failed",
            result.stderr.strip() or result.stdout.strip(),
        ]

    try:
        package = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        return [f"dump-package returned invalid JSON: {error}"]

    if package.get("name") != "SEMIProviderKit":
        fail(errors, f"unexpected package name: {package.get('name')!r}")
    if package.get("dependencies") != []:
        fail(errors, "external SwiftPM dependencies are not allowed")
    if package.get("swiftLanguageVersions") != ["6"]:
        fail(errors, f"unexpected Swift language modes: {package.get('swiftLanguageVersions')!r}")

    products: dict[str, tuple[str, ...]] = {}
    for product in package.get("products", []):
        name = product.get("name")
        targets = tuple(product.get("targets", []))
        if isinstance(name, str):
            products[name] = targets
        product_type = product.get("type", {})
        if "library" not in product_type:
            fail(errors, f"product {name!r} is not a library")
    if products != EXPECTED_PRODUCTS:
        fail(errors, f"product graph drifted: {products!r}")

    targets: dict[str, tuple[str, tuple[str, ...]]] = {}
    for target in package.get("targets", []):
        name = target.get("name")
        if not isinstance(name, str):
            continue
        dependencies = tuple(
            sorted(
                dependency
                for raw in target.get("dependencies", [])
                if (dependency := dependency_name(raw)) is not None
            )
        )
        targets[name] = (target.get("type"), dependencies)
    normalized_expected = {
        name: (kind, tuple(sorted(dependencies)))
        for name, (kind, dependencies) in EXPECTED_TARGETS.items()
    }
    if targets != normalized_expected:
        fail(errors, f"target dependency graph drifted: {targets!r}")

    for path in sorted(source_root.rglob("*")):
        if path.is_symlink():
            fail(errors, f"source symlink is forbidden: {path.relative_to(root)}")

    present_source_targets = {path.name for path in source_root.iterdir() if path.is_dir()}
    if present_source_targets != set(ALLOWED_IMPORTS):
        fail(errors, f"unexpected source target directories: {sorted(present_source_targets)!r}")

    for target, allowed in ALLOWED_IMPORTS.items():
        target_root = source_root / target
        swift_files = sorted(target_root.rglob("*.swift"))
        if not swift_files:
            fail(errors, f"target {target} has no Swift sources")
            continue
        for source in swift_files:
            try:
                text = source.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                fail(errors, f"source is not UTF-8: {source.relative_to(root)}")
                continue
            for line_number, line in enumerate(text.splitlines(), start=1):
                match = IMPORT_PATTERN.match(line)
                if not match:
                    continue
                module = match.group(1)
                if module not in allowed:
                    fail(
                        errors,
                        f"forbidden import {module!r} in {source.relative_to(root)}:{line_number}",
                    )

    return errors


def main() -> int:
    if len(sys.argv) > 2:
        print("usage: verify-providerkit-boundaries.py [package-root]", file=sys.stderr)
        return 2
    root = (
        Path(sys.argv[1]).expanduser().resolve()
        if len(sys.argv) == 2
        else Path(__file__).resolve().parent.parent
    )
    errors = verify(root)
    if errors:
        print("FAIL: SEMIProviderKit boundary verification", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS: SEMIProviderKit product, target, import, and source boundaries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
