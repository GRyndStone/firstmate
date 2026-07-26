#!/usr/bin/env python3
"""KURU-native usage-evidence contract check.

    usage_evidence_contract.py check --evidence <json> [--contract <json>]
                                     [--provider <id>]...

This is a subordinate mechanical mechanism. It observes and refuses. It holds no
authority over intent, product values, architecture, scope, or attainment, it
decides nothing a human or the orchestrator decides, and it makes **no subprocess
call at all**: no shell-out to firstmate, to quota-axi, or to any external router.
It reads caller-supplied organ-evidence JSON and a pinned contract, and it reports.

WHY THIS EXISTS

KURU decision 0028 puts usage evidence on the organ-evidence relationship: organs
report windows, the Brain routes. `tools/usage-burndown` already implements the
routing half natively, and when supplied evidence does not match the window shape
it expects, it degrades to posture `unknown` — honestly, but silently.

Silent degradation is indistinguishable from "this provider has no quota pressure".
That is not a hypothetical. Between quota-axi 0.1.5 and 0.1.13 the upstream organ
renamed its normalized product identifiers:

    product:grokbuild   -> product:grok_build
    product:grokimagine -> product:imagine

A consumer keyed on the published names started reading nothing, with no error and
no failed exit. Separately, the Grok adapter decoded each billing period, used it
internally for validation, then discarded it before emitting — so every emitted
window lacked `windowSeconds`, and a router with no window length cannot compute
time-to-reset for that source.

Both are decoder regressions that *look* like an absence of quota. A router cannot
tell them apart, and it should not have to. This mechanism is the loud half of the
contract: it fails on evidence that has stopped conforming, so a decoder regression
surfaces as a red check on the day it ships rather than as months of quietly wrong
routing.

WHAT IT DOES NOT DO

It does not decode any vendor API, read any credential store, or contact any
provider. That is organ work and it stays in the organ, by specification. This
mechanism only judges evidence it is handed against a contract it is handed.

Exit codes follow the tools/ convention: 0 ok; 2 usage; 11 malformed input;
12 contract violation.
"""
from __future__ import annotations

import json
import sys
from typing import Any

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_MALFORMED = 11
EXIT_VIOLATION = 12

# A window whose kind is "model" is an additional per-model bound, not a general
# capacity window. The contract governs general windows; model windows are
# reported but never required.
MODEL_KIND = "model"


class Violation:
    """One contract breach, with enough detail to act without re-deriving it."""

    __slots__ = ("provider", "code", "detail")

    def __init__(self, provider: str, code: str, detail: str) -> None:
        self.provider = provider
        self.code = code
        self.detail = detail

    def as_dict(self) -> dict[str, str]:
        return {"provider": self.provider, "code": self.code, "detail": self.detail}


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _general_windows(provider_blob: dict[str, Any]) -> list[dict[str, Any]]:
    windows = provider_blob.get("windows")
    if not isinstance(windows, list):
        return []
    return [
        w
        for w in windows
        if isinstance(w, dict) and w.get("kind") != MODEL_KIND
    ]


def check_provider(
    provider_blob: dict[str, Any],
    expectations: dict[str, Any],
) -> list[Violation]:
    """Judge one provider's evidence against its pinned expectations."""
    name = provider_blob.get("provider")
    if not isinstance(name, str) or not name:
        return [Violation("<unnamed>", "provider-unnamed",
                          "provider entry has no string 'provider' field")]

    out: list[Violation] = []
    state = provider_blob.get("state")
    status = state.get("status") if isinstance(state, dict) else None
    if not isinstance(status, str) or not status:
        out.append(Violation(name, "state-missing",
                             "provider has no state.status; freshness is unknowable"))
        status = "unknown"

    general = _general_windows(provider_blob)

    # A provider the organ reports as fresh must actually carry general windows.
    # An empty list from a fresh decoder is the exact silent-nothing failure this
    # check exists to catch: it reads downstream as "no quota pressure".
    if status == "fresh" and not general and expectations.get("requireWindows", True):
        out.append(Violation(
            name, "fresh-but-empty",
            "state.status is 'fresh' but no general (non-model) windows were "
            "emitted; a decoder that returns nothing is indistinguishable from "
            "a provider with no limits",
        ))

    required_fields = expectations.get("requireWindowFields", [])
    for w in general:
        wid = w.get("id")
        label = wid if isinstance(wid, str) and wid else "<unnamed window>"
        for field in required_fields:
            if field not in w or w[field] is None:
                out.append(Violation(
                    name, "window-field-missing",
                    f"window '{label}' is missing required field '{field}'",
                ))
                continue
            value = w[field]
            if field == "windowSeconds":
                # The realized Grok regression: period decoded, used for
                # validation, then discarded. Without a window length the router
                # has no time-to-reset and must guess.
                if not _is_number(value) or value <= 0:
                    out.append(Violation(
                        name, "window-seconds-invalid",
                        f"window '{label}' has windowSeconds={value!r}; a router "
                        "cannot compute time-to-reset without a positive window "
                        "length",
                    ))
            elif field == "percentRemaining":
                if not _is_number(value) or not (0 <= value <= 100):
                    out.append(Violation(
                        name, "percent-out-of-range",
                        f"window '{label}' has percentRemaining={value!r}, "
                        "outside [0, 100]",
                    ))

    seen = {w.get("id") for w in general if isinstance(w.get("id"), str)}

    # Identifier drift, part one: a PARTIAL rename. The realized failure renamed
    # two of six Grok ids, so an "any overlap survives" test would have passed it
    # happily. Ids pinned as required must each still be present; the whole point
    # is that a consumer keyed on one of them stops reading anything.
    for required_id in expectations.get("requiredWindowIds", []):
        if general and required_id not in seen:
            out.append(Violation(
                name, "identifier-drift",
                f"pinned window id '{required_id}' is absent from the emitted ids "
                f"{sorted(seen)}; the organ renamed or dropped it, and every "
                "consumer keyed on that name now reads nothing while the provider "
                "still looks healthy",
            ))

    # Identifier drift, part two: a WHOLESALE vocabulary change, where nothing the
    # contract knows about survives. Caught separately because it needs no per-id
    # pin to be obviously wrong.
    known = expectations.get("knownWindowIds")
    if known and general and not (seen & set(known)):
        out.append(Violation(
            name, "vocabulary-drift",
            f"none of the pinned normalized window ids {sorted(known)} appear in "
            f"the emitted ids {sorted(seen)}; the organ's identifier vocabulary "
            "changed wholesale",
        ))

    return out


def check(evidence: dict[str, Any], contract: dict[str, Any],
          only: list[str] | None = None) -> list[Violation]:
    """Judge a whole evidence blob. Returns every violation found."""
    providers = evidence.get("providers")
    if not isinstance(providers, list):
        return [Violation("<root>", "no-providers",
                          "evidence has no 'providers' array")]

    per_provider = contract.get("providers", {})
    defaults = contract.get("defaults", {})
    required = contract.get("requiredProviders", [])

    out: list[Violation] = []
    seen_names = []
    for blob in providers:
        if not isinstance(blob, dict):
            out.append(Violation("<root>", "provider-not-object",
                                 "providers[] entry is not an object"))
            continue
        name = blob.get("provider")
        if isinstance(name, str):
            seen_names.append(name)
            if only and name not in only:
                continue
        expectations = dict(defaults)
        if isinstance(name, str) and name in per_provider:
            expectations.update(per_provider[name])
        out.extend(check_provider(blob, expectations))

    # A provider the contract requires must be present at all. Its silent
    # disappearance from the evidence is itself a contract break.
    for name in required:
        if only and name not in only:
            continue
        if name not in seen_names:
            out.append(Violation(
                name, "provider-absent",
                "contract requires this provider but it is absent from the "
                "evidence; the organ stopped reporting it",
            ))
    return out


def _load(path: str) -> Any:
    if path == "-":
        return json.load(sys.stdin)
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def main(argv: list[str]) -> int:
    if not argv or argv[0] != "check":
        sys.stderr.write(__doc__.split("\n\n")[0] + "\n")
        sys.stderr.write("usage: usage_evidence_contract.py check --evidence <json> "
                         "[--contract <json>] [--provider <id>]...\n")
        return EXIT_USAGE

    evidence_path = None
    contract_path = None
    only: list[str] = []
    args = argv[1:]
    while args:
        flag = args[0]
        if flag in ("--evidence", "--contract", "--provider"):
            if len(args) < 2:
                sys.stderr.write(f"error: {flag} requires a value\n")
                return EXIT_USAGE
            if flag == "--evidence":
                evidence_path = args[1]
            elif flag == "--contract":
                contract_path = args[1]
            else:
                only.append(args[1])
            args = args[2:]
        else:
            sys.stderr.write(f"error: unknown flag {flag}\n")
            return EXIT_USAGE

    if not evidence_path:
        sys.stderr.write("error: --evidence is required\n")
        return EXIT_USAGE

    try:
        evidence = _load(evidence_path)
    except (OSError, ValueError) as exc:
        sys.stderr.write(f"error: cannot read evidence: {exc}\n")
        return EXIT_MALFORMED
    if not isinstance(evidence, dict):
        sys.stderr.write("error: evidence must be a JSON object\n")
        return EXIT_MALFORMED

    contract: dict[str, Any] = {}
    if contract_path:
        try:
            contract = _load(contract_path)
        except (OSError, ValueError) as exc:
            sys.stderr.write(f"error: cannot read contract: {exc}\n")
            return EXIT_MALFORMED
        if not isinstance(contract, dict):
            sys.stderr.write("error: contract must be a JSON object\n")
            return EXIT_MALFORMED

    violations = check(evidence, contract, only or None)
    report = {
        "checked": "usage-evidence-contract",
        "providers_checked": sorted({
            p.get("provider") for p in evidence.get("providers", [])
            if isinstance(p, dict) and isinstance(p.get("provider"), str)
        }),
        "violations": [v.as_dict() for v in violations],
        "ok": not violations,
    }
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    if violations:
        # Loud on purpose. A silent pass here is what let a renamed identifier
        # ride for eight releases.
        for v in violations:
            sys.stderr.write(f"CONTRACT VIOLATION [{v.provider}] {v.code}: {v.detail}\n")
        return EXIT_VIOLATION
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
