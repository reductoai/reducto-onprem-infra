#!/usr/bin/env python3
"""Regenerate the vendored agent-sandbox manifests from an upstream release.

The two vendored files in this directory are NOT hand-edited. They are the
upstream GitHub release assets with a fixed, declared set of modifications
applied by this script. The PATCHES list below IS the record of every change
we make to upstream — after a version bump, edit VERSION, run this script, and
the same modifications re-apply (or fail loudly if upstream changed shape).

    uv run python3 patch.py            # download + patch + overwrite files
    uv run python3 patch.py --check    # fail (exit 1) if committed files
                                       # differ from a fresh regeneration

Each patch targets a document by (kind, name). A patch whose target matches no
document is a hard error: upstream renamed/removed something and the edit must
be revisited rather than silently dropped.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn, Protocol

import yaml

# v0.5.3 is a deliberate pin (v0.5.4 shipped 2026-07-30, after this was cut).
# To bump: edit VERSION, refresh ASSET_SHA256 + CONTROLLER_IMAGE below from the
# new release, run `patch.py`, and diff the rendered bundles.
VERSION = "v0.5.3"
BASE_URL = (
    f"https://github.com/kubernetes-sigs/agent-sandbox/releases/download/{VERSION}"
)
HERE = Path(__file__).parent

# GitHub release assets are mutable under a tag (a maintainer, or anyone with
# repo write, can replace an asset without moving the tag). Pin the sha256 of
# each asset so a tampered or silently-changed upstream fails the fetch loudly
# instead of vendoring different YAML on the next regen. Keyed by asset name.
ASSET_SHA256: dict[str, str] = {
    "sandbox.yaml": "50f54b0e746376455ae6bb8b90b436bdd8798e1296cff0d72b6267bbeb858e3c",
    "extensions.yaml": "3379a7725f94b163d51049aebe941c8e4e969f9669015472664a5a0f7fa06c6b",
}

# Controller image pinned by digest (immutable) while keeping the tag readable.
# Runtimes resolve tag@digest by DIGEST (the tag is ignored), so a stale digest
# would silently deploy the old controller under a new-looking tag. Keyed by
# VERSION like ASSET_SHA256 so a bump without a matching digest fails loudly
# here instead. Resolve per bump with:
#   crane digest registry.k8s.io/agent-sandbox/agent-sandbox-controller:<VERSION>
CONTROLLER_IMAGE_DIGESTS: dict[str, str] = {
    "v0.5.3": "sha256:ba381b4e0c86cca597d5c5a31860e38d30ec1c45e0a7a8328bb2799c87d059c0",
}

# Vendored filename -> upstream release asset it is downloaded from. Upstream
# ships the core bundle as `sandbox.yaml` (renamed from `manifest.yaml` in
# v0.5.3); we vendor it as `core.yaml` to match how it is referenced everywhere
# (kubectl_manifest.agent_sandbox_core). The exact download URLs (for VERSION
# above) are:
#   core.yaml:       https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.5.3/sandbox.yaml
#   extensions.yaml: https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.5.3/extensions.yaml
BUNDLES: dict[str, str] = {
    "core.yaml": "sandbox.yaml",
    "extensions.yaml": "extensions.yaml",
}

# Recursive YAML value type. Typing the parse boundary as Json (rather than the
# Any that yaml.safe_load returns) lets isinstance narrow dicts to dict[str, Json]
# — str keys, not the Never keys you get from an untyped dict — so the merge below
# type-checks without casts on every index.
Json = dict[str, "Json"] | list["Json"] | str | int | float | bool | None
Doc = dict[str, Json]


def _die(message: str) -> NoReturn:
    print(message, file=sys.stderr)
    raise SystemExit(1)


if VERSION not in CONTROLLER_IMAGE_DIGESTS:
    _die(
        f"CONTROLLER_IMAGE_DIGESTS has no digest for {VERSION} — resolve with "
        f"`crane digest registry.k8s.io/agent-sandbox/agent-sandbox-controller:{VERSION}` "
        "and add it before regenerating."
    )
CONTROLLER_IMAGE = f"registry.k8s.io/agent-sandbox/agent-sandbox-controller:{VERSION}@{CONTROLLER_IMAGE_DIGESTS[VERSION]}"


def _doc_id(doc: Doc) -> tuple[str, str]:
    meta = doc.get("metadata")
    name = meta.get("name", "") if isinstance(meta, dict) else ""
    return str(doc.get("kind", "")), str(name)


def _merge(base: Json, overlay: Json) -> Json:
    """Deep-merge overlay into base. Lists whose elements are all `name`-keyed
    dicts merge by name (k8s strategic-merge semantics for containers / volumes
    / volumeMounts); every other value is replaced by the overlay."""
    if isinstance(base, dict) and isinstance(overlay, dict):
        merged: dict[str, Json] = dict(base)
        for key, value in overlay.items():
            merged[key] = _merge(merged[key], value) if key in merged else value
        return merged
    if (
        isinstance(base, list)
        and isinstance(overlay, list)
        and _all_named(base)
        and _all_named(overlay)
    ):
        merged_list: list[Json] = list(base)
        index: dict[object, int] = {}
        for i, item in enumerate(merged_list):
            if isinstance(item, dict):
                index[item["name"]] = i
        for item in overlay:
            if not isinstance(item, dict):
                continue
            name = item["name"]
            if name in index:
                merged_list[index[name]] = _merge(merged_list[index[name]], item)
            else:
                merged_list.append(item)
        return merged_list
    return overlay


def _all_named(items: Json) -> bool:
    return (
        isinstance(items, list)
        and bool(items)
        and all(isinstance(x, dict) and "name" in x for x in items)
    )


class Patch(Protocol):
    file: str

    def apply(self, docs: list[Doc]) -> list[Doc]: ...

    def describe(self) -> str: ...


@dataclass(frozen=True)
class RemoveDoc:
    """Drop the document matching (kind, name) from a file."""

    file: str
    kind: str
    name: str

    def apply(self, docs: list[Doc]) -> list[Doc]:
        kept = [d for d in docs if _doc_id(d) != (self.kind, self.name)]
        if len(kept) == len(docs):
            _die(
                f"{self.file}: RemoveDoc target {self.kind}/{self.name} not found — upstream changed"
            )
        return kept

    def describe(self) -> str:
        return f"remove {self.kind}/{self.name}"


@dataclass(frozen=True)
class MergeDoc:
    """Deep-merge `merge` into the document matching (kind, name)."""

    file: str
    kind: str
    name: str
    merge: Doc

    def apply(self, docs: list[Doc]) -> list[Doc]:
        hits = 0
        out: list[Doc] = []
        for doc in docs:
            if _doc_id(doc) == (self.kind, self.name):
                merged = _merge(doc, self.merge)
                # _merge of two dicts is always a dict; narrow for list[Doc].
                out.append(merged if isinstance(merged, dict) else doc)
                hits += 1
            else:
                out.append(doc)
        if hits != 1:
            _die(
                f"{self.file}: MergeDoc target {self.kind}/{self.name} matched {hits} docs (want 1)"
            )
        return out

    def describe(self) -> str:
        return f"merge into {self.kind}/{self.name}"


@dataclass(frozen=True)
class SetRuleVerbs:
    """Replace the verbs of each rule that lists one of `resources`, in the
    (Cluster)Role matching (kind, name). Asserts exactly one doc and, per
    resource, exactly one matching rule — so a reshaped upstream RBAC (a rule
    renamed, removed, or a grouped rule split apart) is caught loudly rather
    than silently mis-scoped. Narrowing each resource independently means the
    patch stays correct whether upstream groups pods/pvc/services in one rule
    or splits them. Mutates the matched rules in place (unlike RemoveDoc /
    MergeDoc which return fresh structures); safe because _render parses a
    fresh, unaliased doc set per file on every call.

    The guard asserts each named resource maps to exactly one rule; it does NOT
    assert that rule lists ONLY named resources. If upstream groups an unlisted
    resource into the same rule, that resource's verbs are rewritten too — diff
    the rendered manifests when bumping the upstream version."""

    file: str
    kind: str
    name: str
    resources: tuple[str, ...]
    verbs: tuple[str, ...]

    def apply(self, docs: list[Doc]) -> list[Doc]:
        doc_hits = 0
        for doc in docs:
            if _doc_id(doc) != (self.kind, self.name):
                continue
            doc_hits += 1
            rules = doc.get("rules")
            if not isinstance(rules, list):
                _die(f"{self.file}: {self.kind}/{self.name} has no rules list")
            for resource in self.resources:
                rule_hits = 0
                for rule in rules:
                    if not isinstance(rule, dict):
                        continue
                    declared = rule.get("resources")
                    if isinstance(declared, list) and resource in declared:
                        rule["verbs"] = list(self.verbs)
                        rule_hits += 1
                if rule_hits != 1:
                    _die(
                        f"{self.file}: {self.kind}/{self.name} matched {rule_hits} "
                        f"rules for resource {resource} (want 1) — upstream RBAC changed"
                    )
        if doc_hits != 1:
            _die(
                f"{self.file}: SetRuleVerbs target {self.kind}/{self.name} matched "
                f"{doc_hits} docs (want 1)"
            )
        return docs

    def describe(self) -> str:
        return f"scope {self.kind}/{self.name} {list(self.resources)} verbs to {list(self.verbs)}"


# Restricted-PSS hardening for the controller: agent-sandbox-system enforces the
# `restricted` Pod Security Standard, and upstream ships the controller with no
# securityContext, so it is rejected at admission without this. The /tmp
# emptyDir is required because readOnlyRootFilesystem otherwise crashes the
# controller — it writes webhook certs to /tmp/k8s-webhook-server.
#
# dnsConfig cuts DNS amplification (mirrors the reducto.dnsConfig helm helper):
# ndots:2 skips the search-domain walk for external names, no-aaaa suppresses
# the wasted AAAA query on this IPv4 cluster (glibc >=2.36; ignored otherwise).
_CONTROLLER_HARDENING: Doc = {
    "spec": {
        "template": {
            "spec": {
                "dnsConfig": {
                    "options": [
                        {"name": "ndots", "value": "2"},
                        {"name": "no-aaaa"},
                    ]
                },
                "securityContext": {
                    "runAsNonRoot": True,
                    "seccompProfile": {"type": "RuntimeDefault"},
                },
                "containers": [
                    {
                        "name": "agent-sandbox-controller",
                        "image": CONTROLLER_IMAGE,
                        "securityContext": {
                            "allowPrivilegeEscalation": False,
                            "readOnlyRootFilesystem": True,
                            "capabilities": {"drop": ["ALL"]},
                        },
                        "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}],
                    }
                ],
                "volumes": [{"name": "tmp", "emptyDir": {}}],
            }
        }
    }
}

PATCHES: list[Patch] = [
    # core.yaml — the namespace is owned by kubectl_manifest.agent_sandbox_namespace
    # in agent-sandbox.tf (so it applies first with our PSS labels), and the core
    # controller Deployment is superseded by the --extensions one in extensions.yaml.
    RemoveDoc(file="core.yaml", kind="Namespace", name="agent-sandbox-system"),
    RemoveDoc(file="core.yaml", kind="Deployment", name="agent-sandbox-controller"),
    # extensions.yaml — harden the sole controller Deployment for restricted PSS.
    MergeDoc(
        file="extensions.yaml",
        kind="Deployment",
        name="agent-sandbox-controller",
        merge=_CONTROLLER_HARDENING,
    ),
    # Strip cluster-wide WRITE (create/delete/patch/update) on the workload
    # resources the controller manages — the node-root / self-respawning-fleet
    # vector: a harvested controller token could otherwise create or mutate a
    # pod (e.g. `set image` for RCE) on any node. Reads (get/list/watch) stay
    # cluster-wide for the controller's informer, which has no watch-namespace
    # flag. The write verbs are re-granted per sandbox namespace by a Role in
    # agent-sandbox.tf. The controller SA is bound to BOTH the core ClusterRole
    # (pods/pvc/services) and the -extensions ClusterRole (pods, networkpolicies),
    # so both must be narrowed.
    SetRuleVerbs(
        file="core.yaml",
        kind="ClusterRole",
        name="agent-sandbox-controller",
        resources=("pods", "persistentvolumeclaims", "services"),
        verbs=("get", "list", "watch"),
    ),
    SetRuleVerbs(
        file="extensions.yaml",
        kind="ClusterRole",
        name="agent-sandbox-controller-extensions",
        resources=("pods", "networkpolicies"),
        verbs=("get", "list", "watch"),
    ),
    # Strip cluster-wide WRITE on leases too. A harvested token could otherwise
    # delete/patch other controllers' leader-election leases (karpenter, kyverno)
    # and stall them fleet-wide. Reads stay cluster-wide; the controller's own
    # lease lives in agent-sandbox-system, where the namespaced Role re-grants
    # write. Both ClusterRoles carry a leases rule, so both are narrowed.
    SetRuleVerbs(
        file="core.yaml",
        kind="ClusterRole",
        name="agent-sandbox-controller",
        resources=("leases",),
        verbs=("get", "list", "watch"),
    ),
    SetRuleVerbs(
        file="extensions.yaml",
        kind="ClusterRole",
        name="agent-sandbox-controller-extensions",
        resources=("leases",),
        verbs=("get", "list", "watch"),
    ),
]


def _fetch(asset: str) -> str:
    expected = ASSET_SHA256.get(asset)
    if expected is None:
        _die(f"{asset}: no pinned sha256 in ASSET_SHA256 — add one before vendoring")
    url = f"{BASE_URL}/{asset}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        data = resp.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != expected:
        _die(
            f"{asset}: sha256 {digest} != pinned {expected} — upstream asset "
            f"changed under tag {VERSION}; verify the change and update ASSET_SHA256"
        )
    return data.decode()


def _render(file: str) -> str:
    docs = [d for d in yaml.safe_load_all(_fetch(BUNDLES[file])) if d is not None]
    for patch in PATCHES:
        if patch.file == file:
            docs = patch.apply(docs)
    return yaml.safe_dump_all(docs, sort_keys=False, default_flow_style=False)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify committed files match a fresh regeneration",
    )
    args = parser.parse_args()

    drift = False
    for file in BUNDLES:
        rendered = _render(file)
        path = HERE / file
        if args.check:
            if path.read_text() != rendered:
                print(
                    f"DRIFT: {file} differs from regeneration — run `patch.py`",
                    file=sys.stderr,
                )
                drift = True
            else:
                print(f"ok: {file}")
        else:
            path.write_text(rendered)
            applied = (
                ", ".join(p.describe() for p in PATCHES if p.file == file)
                or "no patches"
            )
            print(f"wrote {file} ({applied})")
    return 1 if drift else 0


if __name__ == "__main__":
    raise SystemExit(main())
