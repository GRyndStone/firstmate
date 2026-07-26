#!/usr/bin/env bash
# Modular usage-source adapters for the usage-burndown dispatch engine.
#
# This library owns provider recognition and the role of each reported usage
# window. A gate window can only make a provider temporarily ineligible. A
# budget window alone supplies optimizer inputs. Unknown window periods stay
# null; the optimizer may derive them from reset history, but this adapter never
# invents a duration.
#
# Plug surface (one JSON object per source observation):
#   source_id, class, provider, evidence (fresh|stale|unknown), unit,
#   windows[{id,kind,role,remaining,resets_at_epoch,window_seconds,
#            window_seconds_source}],
#   gate_windows[], binding{...budget window...}, binding_reason, diagnostics[],
#   optional rate_limit_reset_credits{evidence,available_count,source,error,items[]}
#   for provider=codex only (openai-class rate-limit reset credits).
#
# The registry is the single owner of provider identities, adapter classes,
# meter kinds, and provider-specific window-role policy.
# Codex rate-limit reset credits are observed separately from quota-axi windows:
# quota-axi's normalizeCredits keeps only balance/unlimited and drops
# rateLimitResetCredits (cli-rpc) / rate_limit_reset_credits (HTTP). See
# docs/usage-burndown-dispatch.md "Codex rate-limit reset pressure".
# Sourced only; not executed as a main program.

_FM_USAGE_SOURCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_USAGE_SOURCE_LIB_DIR="."

# Registry columns:
#   provider, adapter class, meter kind, compact window-role policy JSON,
#   target_percent (safe budget floor for scoring; default known-provider floor 5,
#   claude 10 so that provider keeps a larger buffer).
# A provider with no role policy uses the single-window fallback: exactly one
# usable non-model window is both gate and budget. Multiple unclassified windows
# degrade to unknown rather than guessing which pool is durable.
# Per-provider target floors sit here next to window-role policy so they are
# registry data, not a special-case branch inside the scoring expression.
fm_usage_source_registry() {
  printf '%s\t%s\t%s\t%s\t%s\n' \
    claude anthropic-class quota-axi '{"budget":["seven_day"],"gate":["five_hour"],"ignore":[]}' 10 \
    codex openai-class quota-axi '{"budget":["weekly"],"gate":["five_hour"],"ignore":[]}' 5 \
    grok grok-class quota-axi '{"budget":["credits"],"gate":["grokbuild","product:grokbuild"],"ignore":["api","product:api","grokimagine","product:grokimagine","chat","product:chat","voice","product:voice"]}' 5 \
    gemini gemini-class unmetered '{"budget":[],"gate":[],"ignore":[]}' 5 \
    openrouter openrouter-class unmetered '{"budget":[],"gate":[],"ignore":[]}' 5 \
    cursor cursor-class quota-axi '{"budget":[],"gate":[],"ignore":[]}' 5 \
    copilot copilot-class quota-axi '{"budget":[],"gate":[],"ignore":[]}' 5
}

# Known-provider default when a registry row omits an explicit target (must stay 5,
# never 0 or 10 — those would invent a constant the captain did not name).
FM_USAGE_SOURCE_DEFAULT_TARGET_PERCENT=${FM_USAGE_SOURCE_DEFAULT_TARGET_PERCENT:-5}

_fm_usage_source_registry_field() { # <provider> <field-number>
  local provider=${1:-} field=${2:-} value
  value=$(fm_usage_source_registry | awk -F '\t' -v provider="$provider" -v field="$field" '
    $1 == provider { print $field; exit }
  ')
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

fm_usage_source_provider_ids() {
  fm_usage_source_registry | awk -F '\t' 'NF >= 4 { print $1 }'
}

# Per-provider target floor in percent remaining. Declared beside window-role
# policy in the registry. Unrecognized providers fail closed (return 64).
# A known provider row without a numeric target uses the stated default of 5.
fm_usage_source_target_percent() { # <provider>
  local provider=${1:-} value
  if ! fm_usage_source_provider_known "$provider"; then
    printf "fm-usage-source: unrecognized provider token '%s'\n" "$provider" >&2
    return 64
  fi
  value=$(_fm_usage_source_registry_field "$provider" 5 2>/dev/null) || value=
  if printf '%s\n' "$value" | awk '
    BEGIN { ok = 0 }
    $0 ~ /^[0-9]+([.][0-9]+)?$/ && $0 + 0 >= 0 && $0 + 0 <= 100 { ok = 1 }
    END { exit !ok }
  '; then
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' "$FM_USAGE_SOURCE_DEFAULT_TARGET_PERCENT"
}

fm_usage_source_provider_ids_csv() {
  fm_usage_source_provider_ids | awk '
    BEGIN { separator = "" }
    { printf "%s%s", separator, $0; separator = ", " }
    END { print "" }
  '
}

fm_usage_source_provider_known() { # <provider>
  _fm_usage_source_registry_field "${1:-}" 1 >/dev/null
}

fm_usage_source_class() { # <provider>
  local provider=${1:-}
  if ! _fm_usage_source_registry_field "$provider" 2; then
    printf "fm-usage-source: unrecognized provider token '%s'\n" "$provider" >&2
    return 64
  fi
}

fm_usage_source_meter_kind() { # <provider>
  local provider=${1:-}
  if ! _fm_usage_source_registry_field "$provider" 3; then
    printf "fm-usage-source: unrecognized provider token '%s'\n" "$provider" >&2
    return 64
  fi
}

fm_usage_source_window_policy() { # <provider>
  local provider=${1:-}
  if ! _fm_usage_source_registry_field "$provider" 4; then
    printf "fm-usage-source: unrecognized provider token '%s'\n" "$provider" >&2
    return 64
  fi
}

# Fetch live multi-provider quota JSON from the configured meter command.
# Always passes --allow-keychain-prompt so macOS uses Keychain credentials for
# Claude (and other providers that store tokens there) instead of falling back
# to the file credential store under ~/.claude/.credentials.json, which can
# hold a non-refreshable sentinel shape and yield 401 "Claude sign-in required".
# On non-macOS hosts the flag is accepted by quota-axi and is a no-op when no
# Keychain is present. Callers must never print credential values.
# Args: optional override command (default FM_DISPATCH_QUOTA_AXI or quota-axi).
# Prints JSON on stdout. Returns the meter command's exit status, or 127 if missing.
fm_usage_source_fetch_quota_json() {
  local cmd=${1:-${FM_DISPATCH_QUOTA_AXI:-quota-axi}}
  if ! command -v "$cmd" >/dev/null 2>&1; then
    return 127
  fi
  "$cmd" --allow-keychain-prompt --json
}

# Parse a raw rateLimitResetCredits / rate_limit_reset_credits object into the
# observation fragment used by the burndown engine.
# Only status=="available" items whose expiresAt (epoch seconds) is absent or
# strictly greater than now_epoch count. availableCount alone is used only when
# no credits array is present (HTTP shape). Unreadable shapes are loud errors
# (evidence=unreadable), never a silent zero.
# Args: <raw_json_or_null> <now_epoch>
fm_usage_source_parse_codex_rate_limit_reset_credits() {
  local raw=${1:-null} now_epoch=${2:-0}
  if [ -z "$raw" ]; then
    raw=null
  fi
  # jq -e exits non-zero for JSON null/false; use `empty` for a pure parse check.
  if ! printf '%s\n' "$raw" | jq empty >/dev/null 2>&1; then
    jq -cn '{
      evidence:"unreadable",
      available_count:null,
      source:"parse-error",
      error:"rateLimitResetCredits payload is not valid JSON",
      items:[]
    }'
    return 0
  fi
  jq -cn --argjson raw "$raw" --argjson now "$now_epoch" '
    def nonneg_int:
      (type == "number") and (. == floor) and (. >= 0);
    def item_expiry:
      .expiresAt // .expires_at // null;
    def item_status:
      (.status // "") | ascii_downcase;
    def available_item:
      (item_status == "available")
      and (
        (item_expiry | type) != "number"
        or item_expiry > $now
      );
    if $raw == null then
      {
        evidence:"fresh",
        available_count:0,
        source:"absent-as-zero",
        error:null,
        all_expired:false,
        items:[]
      }
    elif ($raw | type) != "object" then
      {
        evidence:"unreadable",
        available_count:null,
        source:"type-error",
        error:"rateLimitResetCredits is not an object",
        all_expired:false,
        items:[]
      }
    elif ($raw._fm_error | type) == "string" and ($raw._fm_error | length) > 0 then
      {
        evidence:"unreadable",
        available_count:null,
        source:"probe-error",
        error:$raw._fm_error,
        all_expired:false,
        items:[]
      }
    elif (($raw.credits // $raw.Credits // null) | type) == "array" then
      ($raw.credits // $raw.Credits) as $credits
      | ([
          $credits[]?
          | select(type == "object")
          | {
              status:(.status // null),
              reset_type:(.resetType // .reset_type // null),
              expires_at_epoch:(item_expiry),
              granted_at_epoch:(.grantedAt // .granted_at // null)
            }
        ]) as $items
      | ([ $items[] | select(
            ((.status // "") | ascii_downcase) == "available"
            and (
              (.expires_at_epoch | type) != "number"
              or .expires_at_epoch > $now
            )
          ) ]) as $avail
      | ($items | length) as $total
      | ($avail | length) as $n
      | {
          evidence:"fresh",
          available_count:$n,
          source:(
            if $total == 0 then "credits-array-empty"
            elif $n == 0 and ($items | any(
              ((.status // "") | ascii_downcase) == "available"
              and (.expires_at_epoch | type) == "number"
              and .expires_at_epoch <= $now
            )) then "credits-array-all-expired"
            elif $n == 0 then "credits-array-none-available"
            else "credits-array-filtered"
            end
          ),
          error:null,
          all_expired:(
            $total > 0 and $n == 0 and ($items | any(
              ((.status // "") | ascii_downcase) == "available"
              and (.expires_at_epoch | type) == "number"
              and .expires_at_epoch <= $now
            ))
          ),
          items:$items
        }
    else
      ($raw.availableCount // $raw.available_count // null) as $ac
      | if $ac == null then
          {
            evidence:"fresh",
            available_count:0,
            source:"absent-count-as-zero",
            error:null,
            all_expired:false,
            items:[]
          }
        elif ($ac | nonneg_int) then
          {
            evidence:"fresh",
            available_count:($ac | floor),
            source:"available-count-field",
            error:null,
            all_expired:false,
            items:[]
          }
        else
          {
            evidence:"unreadable",
            available_count:null,
            source:"available-count-unreadable",
            error:("availableCount is not a non-negative integer (got "
              + ($ac | type) + ")"),
            all_expired:false,
            items:[]
          }
        end
    end
  '
}

# Live, read-only observation of Codex rateLimitResetCredits via app-server RPC
# account/rateLimits/read. Observe only: never redeem or consume a reset.
# Never prints credentials, tokens, account ids, or credit ids.
# Optional override: FM_USAGE_CODEX_RESET_CREDITS_JSON (raw object or full RPC
# result) for fixtures. Optional binary: FM_USAGE_CODEX_BINARY or CODEX_BINARY
# or `codex` on PATH.
# Prints the raw rateLimitResetCredits object (or {_fm_error:...}) on stdout.
fm_usage_source_fetch_codex_rate_limit_reset_credits_raw() {
  local override=${FM_USAGE_CODEX_RESET_CREDITS_JSON:-}
  local binary
  if [ -n "$override" ]; then
    if ! printf '%s\n' "$override" | jq -e . >/dev/null 2>&1; then
      jq -cn '{_fm_error:"FM_USAGE_CODEX_RESET_CREDITS_JSON is not valid JSON"}'
      return 0
    fi
    printf '%s\n' "$override" | jq -c '
      if type == "object" and (has("rateLimitResetCredits") or has("rate_limit_reset_credits")) then
        .rateLimitResetCredits // .rate_limit_reset_credits
      elif type == "object" and (has("availableCount") or has("available_count") or has("credits") or has("_fm_error")) then
        .
      else
        {_fm_error:"FM_USAGE_CODEX_RESET_CREDITS_JSON has no rateLimitResetCredits object"}
      end
    '
    return 0
  fi
  binary=${FM_USAGE_CODEX_BINARY:-${CODEX_BINARY:-}}
  if [ -z "$binary" ]; then
    binary=$(command -v codex 2>/dev/null || true)
  fi
  if [ -z "$binary" ] || [ ! -x "$binary" ]; then
    jq -cn '{_fm_error:"codex binary unavailable for rateLimitResetCredits probe"}'
    return 0
  fi
  # Python owns the JSON-RPC session; bash only supplies the binary path.
  # stdout is the raw rateLimitResetCredits object or {_fm_error}.
  FM_USAGE_CODEX_BINARY_PATH="$binary" python3 - <<'PY'
import json, os, subprocess, sys, time

binary = os.environ["FM_USAGE_CODEX_BINARY_PATH"]
proc = subprocess.Popen(
    [binary, "-s", "read-only", "-a", "untrusted", "app-server"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
    env={**os.environ, "NO_COLOR": "1", "TERM": "dumb"},
)
responses = {}

def fail(msg: str) -> None:
    print(json.dumps({"_fm_error": msg}))
    try:
        proc.terminate()
        proc.wait(timeout=2)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
    sys.exit(0)

def wait_for(req_id: int, timeout: float = 12.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if req_id in responses:
            return responses.pop(req_id)
        if proc.stdout is None:
            break
        line = proc.stdout.readline()
        if not line:
            time.sleep(0.05)
            continue
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        if isinstance(msg, dict) and isinstance(msg.get("id"), int):
            if "error" in msg and msg["error"] is not None:
                responses[msg["id"]] = {"_rpc_error": msg["error"]}
            else:
                responses[msg["id"]] = msg.get("result", msg.get("params"))
    fail("timed out waiting for codex app-server rateLimits/read")

def send(req_id: int, method: str, params=None) -> None:
    if proc.stdin is None:
        fail("codex app-server stdin closed")
    proc.stdin.write(json.dumps({"id": req_id, "method": method, "params": params or {}}) + "\n")
    proc.stdin.flush()

try:
    send(1, "initialize", {"clientInfo": {"name": "firstmate-usage", "version": "1"}})
    init = wait_for(1, 15)
    if isinstance(init, dict) and "_rpc_error" in init:
        fail("codex app-server initialize failed")
    send(2, "account/rateLimits/read")
    limits = wait_for(2, 10)
    if isinstance(limits, dict) and "_rpc_error" in limits:
        fail("account/rateLimits/read returned an RPC error")
    if not isinstance(limits, dict):
        fail("account/rateLimits/read returned a non-object")
    raw = limits.get("rateLimitResetCredits")
    if raw is None:
        raw = limits.get("rate_limit_reset_credits")
    if raw is None:
        # Successful read with no reset-credits section: genuine zero.
        print(json.dumps(None))
    else:
        # Drop credit ids from the live probe so logs never carry account-bound ids.
        if isinstance(raw, dict) and isinstance(raw.get("credits"), list):
            scrubbed = dict(raw)
            items = []
            for item in raw["credits"]:
                if not isinstance(item, dict):
                    continue
                items.append({
                    k: item[k]
                    for k in (
                        "resetType", "reset_type", "status",
                        "grantedAt", "granted_at", "expiresAt", "expires_at",
                        "title", "description",
                    )
                    if k in item
                })
            scrubbed["credits"] = items
            # Prefer camelCase count when present; keep both shapes if supplied.
            print(json.dumps(scrubbed))
        else:
            print(json.dumps(raw))
except Exception as exc:
    fail(f"codex rateLimitResetCredits probe failed: {type(exc).__name__}")
finally:
    try:
        proc.terminate()
        proc.wait(timeout=2)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
PY
}

# Inject codex rateLimitResetCredits into a quota-axi JSON blob for provider=codex.
# Live path uses the app-server probe (observe only). Fixture path may already
# carry the field; it is left alone. Always returns a full quota JSON object.
# Args: <quota_json> <now_epoch>
fm_usage_source_enrich_codex_reset_credits() {
  local quota_json=$1 now_epoch=${2:-0}
  local has_codex raw_reset
  has_codex=$(printf '%s\n' "$quota_json" | jq -r '
    [.providers[]? | select(.provider == "codex")] | length
  ' 2>/dev/null || printf '0')
  if [ "$has_codex" = 0 ]; then
    printf '%s\n' "$quota_json"
    return 0
  fi
  # If the meter (or fixture) already carried the field, keep it.
  if printf '%s\n' "$quota_json" | jq -e '
    [.providers[]? | select(.provider == "codex")
     | select(has("rateLimitResetCredits") or has("rate_limit_reset_credits")
              or has("rate_limit_reset_credits_error"))] | length > 0
  ' >/dev/null 2>&1; then
    printf '%s\n' "$quota_json"
    return 0
  fi
  raw_reset=$(fm_usage_source_fetch_codex_rate_limit_reset_credits_raw) \
    || raw_reset='{"_fm_error":"codex rateLimitResetCredits probe failed"}'
  if ! printf '%s\n' "$raw_reset" | jq -e . >/dev/null 2>&1; then
    raw_reset='{"_fm_error":"codex rateLimitResetCredits probe returned non-JSON"}'
  fi
  jq -cn --argjson quota "$quota_json" --argjson raw "$raw_reset" '
    $quota
    | .providers |= map(
        if .provider == "codex" then
          . + {rateLimitResetCredits: $raw}
        else .
        end
      )
  '
}

# Extract and normalize codex reset-credits from a provider object inside
# quota-axi JSON. Missing field => genuine zero (fixture / no grants).
# Args: <quota_json> <now_epoch>
fm_usage_source_codex_reset_credits_from_quota_json() {
  local quota_json=$1 now_epoch=${2:-0}
  local raw
  raw=$(printf '%s\n' "$quota_json" | jq -c '
    ([.providers[]? | select(.provider == "codex")][0]) as $p
    | if $p == null then null
      elif ($p.rateLimitResetCredits? != null) then $p.rateLimitResetCredits
      elif ($p.rate_limit_reset_credits? != null) then $p.rate_limit_reset_credits
      else null
      end
  ' 2>/dev/null || printf 'null')
  fm_usage_source_parse_codex_rate_limit_reset_credits "$raw" "$now_epoch"
}

# True when the provider is expected to yield scorable meter evidence.
# Unmetered recognized providers (no adapter wired yet) may honestly report
# evidence=unknown without it being a read failure.
fm_usage_source_provider_is_metered() { # <provider>
  local kind
  kind=$(fm_usage_source_meter_kind "${1:-}" 2>/dev/null) || return 1
  [ "$kind" = quota-axi ]
}

# Build one observation object for provider from a full quota-axi JSON blob.
# now_epoch is required for T and stale-window currentness.
fm_usage_source_observe() { # <provider> <quota_json> <now_epoch>
  local provider=$1 quota_json=$2 now_epoch=$3
  local class meter_kind role_policy obs reset_credits
  if ! fm_usage_source_provider_known "$provider"; then
    printf "fm-usage-source: unrecognized provider token '%s'\n" "$provider" >&2
    return 64
  fi
  class=$(fm_usage_source_class "$provider") || return $?
  meter_kind=$(fm_usage_source_meter_kind "$provider") || return $?
  role_policy=$(fm_usage_source_window_policy "$provider") || return $?
  target_percent=$(fm_usage_source_target_percent "$provider") || return $?

  case "$meter_kind" in
    unmetered)
      jq -cn \
        --arg source_id "$provider" \
        --arg class "$class" \
        --arg provider "$provider" \
        --argjson target_percent "$target_percent" \
        '{
          source_id:$source_id,
          class:$class,
          provider:$provider,
          evidence:"unknown",
          unit:"percent",
          windows:[],
          gate_windows:[],
          target_percent:$target_percent,
          diagnostics:["no usage meter wired for this recognized provider yet; see docs/usage-burndown-dispatch.md"]
        }'
      return 0
      ;;
    quota-axi) ;;
    *)
      printf "fm-usage-source: provider '%s' has unsupported meter kind '%s'\n" "$provider" "$meter_kind" >&2
      return 70
      ;;
  esac

  obs=$(printf '%s\n' "$quota_json" | jq -ec \
    --arg provider "$provider" \
    --arg class "$class" \
    --argjson policy "$role_policy" \
    --argjson target_percent "$target_percent" \
    --argjson now "$now_epoch" '
    # quota-axi emits fractional seconds and +00:00 offsets.
    # fromdateiso8601 only accepts whole-second ...Z forms; normalize both.
    def iso_epoch:
      if type != "string" then null
      else
        try (
          sub("\\.[0-9]+"; "") as $s
          | if ($s | test("Z$")) then
              $s | fromdateiso8601
            elif ($s | test("[+-][0-9]{2}:?[0-9]{2}$")) then
              ($s | capture("(?<base>.*)(?<sign>[+-])(?<hh>[0-9]{2}):?(?<mm>[0-9]{2})$")) as $m
              | (($m.base + "Z") | fromdateiso8601) as $naive
              | ((($m.hh | tonumber) * 3600) + (($m.mm | tonumber) * 60)) as $off
              | if $m.sign == "+" then $naive - $off else $naive + $off end
            else null
            end
        ) catch null
      end;
    def general_window_ok:
      ((.kind? // "") != "model")
      and ((.percentRemaining? | type) == "number")
      and (.percentRemaining >= 0)
      and (.percentRemaining <= 100);
    def stale_window_is_current($refreshed):
      (.resetsAt | iso_epoch) as $reset
      | (.windowSeconds? // null) as $duration
      | ($refreshed != null)
        and ($refreshed <= $now)
        and ($reset != null)
        and ($reset > $now)
        and ($reset > $refreshed)
        and (($duration | type) == "number")
        and ($duration > 0)
        and (($reset - $refreshed) <= $duration);
    def configured_roles:
      (($policy.budget // []) + ($policy.gate // []) + ($policy.ignore // []));
    def role_for($id; $count):
      if (($policy.budget // []) | index($id)) != null then "budget"
      elif (($policy.gate // []) | index($id)) != null then "gate"
      elif (($policy.ignore // []) | index($id)) != null then "ignored"
      elif (configured_roles | length) > 0 then "unclassified"
      elif $count == 1 then "both"
      else "unclassified"
      end;
    def role_source_for($id; $count):
      if (configured_roles | length) > 0 then "provider-policy"
      elif $count == 1 then "single-window-fallback"
      else "unclassified"
      end;
    ([.providers[]? | select(.provider == $provider)][0]) as $p
    | if $p == null then
        {
          source_id:$provider,
          class:$class,
          provider:$provider,
          evidence:"unknown",
          unit:"percent",
          windows:[],
          gate_windows:[],
          target_percent:$target_percent,
          diagnostics:["provider absent from quota evidence"]
        }
      else
        (($p.state.status? // "unknown") as $status
        | ($p.state.refreshedAt? | iso_epoch) as $refreshed
        | ([($p.windows // [])[]
            | select(general_window_ok)
            | select(
                $status == "fresh"
                or ($status == "stale" and stale_window_is_current($refreshed))
              )
            | . as $w
            | ($w.resetsAt | iso_epoch) as $reset
            | select($reset != null and $reset > $now)
            | {
                id: $w.id,
                label: ($w.label // null),
                kind: ($w.kind // "session"),
                remaining: $w.percentRemaining,
                resets_at_epoch: $reset,
                window_seconds: (
                  if ($w.windowSeconds? | type) == "number" and $w.windowSeconds > 0
                  then $w.windowSeconds
                  else null
                  end
                ),
                window_seconds_source: (
                  if ($w.windowSeconds? | type) == "number" and $w.windowSeconds > 0
                  then "meter"
                  else "missing"
                  end
                ),
                T: ($reset - $now)
              }
          ]) as $raw
        | ($raw | length) as $raw_count
        | ($raw | map(
            . + {
              role: role_for(.id; $raw_count),
              role_source: role_source_for(.id; $raw_count)
            }
          )) as $classified
        | ([$classified[] | select(.role == "budget" or .role == "both")]) as $budgets
        | ([$classified[] | select(.role == "gate" or .role == "both")]) as $gates
        | if ($budgets | length) != 1 then
            {
              source_id:$provider,
              class:$class,
              provider:$provider,
              evidence:"unknown",
              unit:"percent",
              windows:$classified,
              gate_windows:$gates,
              target_percent:$target_percent,
              diagnostics:(
                if ($raw | length) == 0 then
                  ["no usable non-model windows"]
                elif ($budgets | length) == 0 then
                  ["no budget window can be classified without guessing"]
                else
                  ["multiple budget windows classified; refusing to guess which one binds"]
                end
                + (if $status != "fresh" then ["quota status is \($status)"] else [] end)
              )
            }
          else
            ($budgets[0]) as $budget
            | {
                source_id:$provider,
                class:$class,
                provider:$provider,
                evidence:(if $status == "fresh" then "fresh" else "stale" end),
                unit:"percent",
                windows:$classified,
                gate_windows:$gates,
                target_percent:$target_percent,
                binding: {
                  id:$budget.id,
                  role:"budget",
                  role_source:$budget.role_source,
                  remaining:$budget.remaining,
                  resets_at_epoch:$budget.resets_at_epoch,
                  T:$budget.T,
                  window_seconds:$budget.window_seconds,
                  window_seconds_source:$budget.window_seconds_source
                },
                binding_reason:(
                  if $budget.role_source == "single-window-fallback"
                  then "only usable window acts as both eligibility gate and scored budget"
                  else "provider policy marks this as the durable budget; gate windows never affect score"
                  end
                ),
                diagnostics:(
                  [$classified[]
                    | select(.role == "unclassified")
                    | "unclassified window \(.id) was not used"]
                )
              }
          end
        )
      end
    ') || return $?

  # Codex alone carries rate-limit reset credits. Attach a real observation.
  # An unreadable count is a loud, named diagnostic - never a silent N=0 - but
  # it must not poison otherwise-valid window evidence (see
  # docs/usage-burndown-dispatch.md "Codex rate-limit reset pressure").
  if [ "$provider" = codex ]; then
    reset_credits=$(fm_usage_source_codex_reset_credits_from_quota_json \
      "$quota_json" "$now_epoch")
    obs=$(jq -cn --argjson o "$obs" --argjson r "$reset_credits" '
      $o as $base
      | $base + {
          rate_limit_reset_credits:$r,
          diagnostics:(
            ($base.diagnostics // [])
            + (
                if $r.evidence == "unreadable" then
                  ["codex rate-limit reset credits unreadable: "
                    + ($r.error // "unknown cause")]
                else []
                end
              )
          )
        }
    ')
  fi
  printf '%s\n' "$obs"
}

# Observe every distinct provider listed in a profiles JSON array.
fm_usage_source_observe_profiles() { # <profiles_json> <quota_json> <now_epoch>
  local profiles_json=$1 quota_json=$2 now_epoch=$3
  local providers p obs out class
  providers=$(printf '%s\n' "$profiles_json" | jq -r '
    [.[] | (.provider // .harness // empty) | select(type == "string" and length > 0)]
    | unique | .[]
  ')
  out='[]'
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! fm_usage_source_provider_known "$p"; then
      printf "fm-usage-source: unrecognized provider token '%s'\n" "$p" >&2
      return 64
    fi
    if ! obs=$(fm_usage_source_observe "$p" "$quota_json" "$now_epoch"); then
      class=$(fm_usage_source_class "$p") || return $?
      target_percent=$(fm_usage_source_target_percent "$p") || return $?
      obs=$(jq -cn \
        --arg provider "$p" \
        --arg class "$class" \
        --argjson target_percent "$target_percent" \
        '{source_id:$provider,class:$class,provider:$provider,evidence:"unknown",unit:"percent",windows:[],gate_windows:[],target_percent:$target_percent,diagnostics:["adapter failed"]}')
    fi
    out=$(jq -cn --argjson acc "$out" --argjson o "$obs" '$acc + [$o]')
  done <<< "$providers"
  printf '%s\n' "$out"
}
