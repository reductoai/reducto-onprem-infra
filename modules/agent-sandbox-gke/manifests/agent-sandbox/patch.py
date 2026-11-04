#!/usr/bin/env python3
"""Regenerate the vendored agent-sandbox manifests from an upstream release.

GKE copy of reductoai/api terragrunt/modules/aws-eks-addons/manifests/agent-sandbox/patch.py
(same VERSION, asset sha256s, controller digest, and RBAC narrowing). The only
difference is _CONTROLLER_HARDENING: the hosted copy pins the controller to the
EKS `node-type: system` pool with a CriticalAddonsOnly toleration, which a
customer GKE cluster does not have, so this copy drops that placement. Keep the
two in step on every version bump.

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
import http.client
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn, Protocol

import yaml

# To bump: edit VERSION, refresh ASSET_SHA256 + CONTROLLER_IMAGE_DIGESTS below
# from the new release, run `patch.py`, diff the rendered bundles and read the
# release notes' "Breaking Changes". The marker
# below (this repo has no renovate custom manager for it yet: bump by hand, in
# step with the hosted copy); a bump fails `--check` on purpose until
# the sha256s and digest are refreshed.
# renovate: datasource=github-releases depName=kubernetes-sigs/agent-sandbox
VERSION = "v1.0.7"
BASE_URL = (
    f"https://github.com/kubernetes-sigs/agent-sandbox/releases/download/{VERSION}"
)
HERE = Path(__file__).parent

# GitHub release assets are mutable under a tag (a maintainer, or anyone with
# repo write, can replace an asset without moving the tag). Pin the sha256 of
# each asset so a tampered or silently-changed upstream fails the fetch loudly
# instead of vendoring different YAML on the next regen. Keyed by asset name.
ASSET_SHA256: dict[str, str] = {
    "sandbox.yaml": "437e6875cf7dfbd1c1230de3641f73bb9dad595a581366ef7f98f9b2813dd686",
    "extensions.yaml": "f336a8056a86c38c7631ce8fb5966fb6c2a93c9c6f8f2c7c511ead11a8dccf7f",
}

# Controller image pinned by digest (immutable) while keeping the tag readable.
# Runtimes resolve tag@digest by DIGEST (the tag is ignored), so a stale digest
# would silently deploy the old controller under a new-looking tag. Keyed by
# VERSION like ASSET_SHA256 so a bump without a matching digest fails loudly
# here instead. Resolve per bump with:
#   crane digest registry.k8s.io/agent-sandbox/agent-sandbox-controller:<VERSION>
CONTROLLER_IMAGE_DIGESTS: dict[str, str] = {
    "v1.0.7": "sha256:f254384c24605436ce35d7077427559e24bda8f5691cff5a54a4c2e030d81083",
}

# Vendored filename -> upstream release asset it is downloaded from. Upstream
# ships the core bundle as `sandbox.yaml` (renamed from `manifest.yaml` in
# v0.5.2); we vendor it as `core.yaml` to match how it is referenced everywhere
# (kubectl_manifest.agent_sandbox_core). The exact download URLs (for VERSION
# above) are:
#   core.yaml:       https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.7/sandbox.yaml
#   extensions.yaml: https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.7/extensions.yaml
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
        and base
        and not _all_named(base)
    ):
        # Replacing an upstream list wholesale would drop its entries with no
        # trace in the rendered diff (before and after both show only ours).
        _die(
            f"_merge: upstream now ships a list we would replace blindly: {base!r:.120}"
        )
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
# emptyDir keeps a writable scratch dir under readOnlyRootFilesystem (v1.0 has
# no webhook, so it no longer writes certs there).
#
# dnsConfig cuts DNS amplification (mirrors the reducto.dnsConfig helm helper):
# ndots:2 skips the search-domain walk for external names, no-aaaa suppresses
# the wasted AAAA query on this IPv4 cluster (glibc >=2.36; ignored otherwise).
#
# HA: two replicas behind leader election (upstream ships one). A rollout or a
# node disruption hands the lease over in seconds instead of leaving claims
# waiting for a single pod to come back; maxUnavailable 0 keeps one replica up
# through the rollout and the PDB in controller.tf keeps one up through
# node upgrades. Spread across nodes (hard) and zones (soft).
_CONTROLLER_HARDENING: Doc = {
    "spec": {
        "replicas": 2,
        "strategy": {
            "type": "RollingUpdate",
            "rollingUpdate": {"maxUnavailable": 0, "maxSurge": 1},
        },
        "template": {
            "spec": {
                # At priority 0, other workloads can preempt it. GKE admits
                # system-cluster-critical outside kube-system only with a
                # ResourceQuota scoped to that class in the namespace; the
                # module renders one (controller.tf). No nodeSelector or
                # toleration: GKE has no shared system-pool label, and the
                # sandbox pool's taints keep the controller off sandbox nodes.
                "priorityClassName": "system-cluster-critical",
                "topologySpreadConstraints": [
                    {
                        "maxSkew": 1,
                        # minDomains: with one eligible node both replicas would otherwise
                        # satisfy maxSkew on that single node.
                        "minDomains": 2,
                        "topologyKey": "kubernetes.io/hostname",
                        "whenUnsatisfiable": "DoNotSchedule",
                        "labelSelector": {
                            "matchLabels": {"app": "agent-sandbox-controller"}
                        },
                    },
                    {
                        "maxSkew": 1,
                        "topologyKey": "topology.kubernetes.io/zone",
                        "whenUnsatisfiable": "ScheduleAnyway",
                        "labelSelector": {
                            "matchLabels": {"app": "agent-sandbox-controller"}
                        },
                    },
                ],
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
                        # Memory req==lim so a node never overcommits; CPU request
                        # only (Burstable by design: a CPU limit would CFS-throttle
                        # the leader on a warm-pool refill). Upstream ships neither
                        # resources nor probes; controller-runtime serves /healthz +
                        # /readyz on 8081.
                        "resources": {
                            "requests": {"cpu": "200m", "memory": "512Mi"},
                            "limits": {"memory": "512Mi"},
                        },
                        "securityContext": {
                            "allowPrivilegeEscalation": False,
                            "readOnlyRootFilesystem": True,
                            "capabilities": {"drop": ["ALL"]},
                        },
                        "startupProbe": {
                            "httpGet": {"path": "/healthz", "port": "healthz"},
                            "periodSeconds": 5,
                            "failureThreshold": 30,
                        },
                        "livenessProbe": {
                            "httpGet": {"path": "/healthz", "port": "healthz"},
                            "periodSeconds": 20,
                            "failureThreshold": 3,
                        },
                        "readinessProbe": {
                            "httpGet": {"path": "/readyz", "port": "healthz"},
                            "periodSeconds": 10,
                        },
                        "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}],
                    }
                ],
                "volumes": [{"name": "tmp", "emptyDir": {}}],
            }
        },
    }
}

PATCHES: list[Patch] = [
    # core.yaml — the namespace is owned by kubectl_manifest.controller_namespace
    # in controller.tf (so it applies first with our PSS labels), and the core
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
    # controller.tf. The controller SA is bound to BOTH the core ClusterRole
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

if _unknown := {patch.file for patch in PATCHES} - BUNDLES.keys():
    _die(f"PATCHES target bundle(s) that do not exist: {sorted(_unknown)}")

# Upstream bundles are ~200 KB; anything larger is not the asset we pinned.
MAX_ASSET_BYTES = 4 * 1024 * 1024


def _download(url: str) -> bytes:
    """Three attempts with backoff: a GitHub hiccup must not red the bump PR
    this check exists to gate."""
    last: Exception | None = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                return resp.read(MAX_ASSET_BYTES + 1)
        # URLError covers connect failures; a body cut mid-read surfaces as
        # IncompleteRead/HTTPException or a bare OSError (connection reset).
        except (urllib.error.URLError, http.client.HTTPException, OSError) as e:
            last = e
            time.sleep(2**attempt)
    _die(f"{url}: download failed after 3 attempts: {last}")


def _fetch(asset: str) -> str:
    expected = ASSET_SHA256.get(asset)
    if expected is None:
        _die(f"{asset}: no pinned sha256 in ASSET_SHA256 — add one before vendoring")
    url = f"{BASE_URL}/{asset}"
    data = _download(url)
    if len(data) > MAX_ASSET_BYTES:
        _die(
            f"{asset}: response exceeds {MAX_ASSET_BYTES} bytes — not the pinned asset"
        )
    digest = hashlib.sha256(data).hexdigest()
    if digest != expected:
        _die(
            f"{asset}: sha256 {digest} != pinned {expected} — upstream asset "
            f"changed under tag {VERSION}; verify the change and update ASSET_SHA256"
        )
    return data.decode()


def _check_controller(docs: list[Doc]) -> None:
    """Memory request must equal its limit (an upstream memory request we do not
    also cap would make the pod overcommit the node) and CPU must stay unlimited
    (a CPU limit throttles the leader under load)."""
    for doc in docs:
        if _doc_id(doc) != ("Deployment", "agent-sandbox-controller"):
            continue
        spec = doc.get("spec")
        template = spec.get("template") if isinstance(spec, dict) else None
        pod = template.get("spec") if isinstance(template, dict) else None
        containers = pod.get("containers") if isinstance(pod, dict) else None
        if not isinstance(containers, list) or len(containers) != 1:
            _die("controller Deployment must render exactly one container")
        container = containers[0]
        resources = container.get("resources") if isinstance(container, dict) else None
        requests = resources.get("requests") if isinstance(resources, dict) else None
        limits = resources.get("limits") if isinstance(resources, dict) else None
        if (
            not isinstance(requests, dict)
            or not isinstance(limits, dict)
            or "memory" not in limits
            or requests.get("memory") != limits.get("memory")
            or "cpu" in limits
        ):
            _die(
                f"controller resources must set memory request == limit and no cpu limit: {resources!r}"
            )


def _render(file: str) -> str:
    docs = [d for d in yaml.safe_load_all(_fetch(BUNDLES[file])) if d is not None]
    for patch in PATCHES:
        if patch.file == file:
            docs = patch.apply(docs)
    if file == "extensions.yaml":
        _check_controller(docs)
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
