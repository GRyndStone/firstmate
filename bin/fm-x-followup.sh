#!/usr/bin/env bash
# Post a completion follow-up for an X-mode-linked task, up to three within a
# 7-day window, and manage the link's counter.
#
# An X-mode mention that spawned real work is linked to its task by fm-x-link.sh
# (x_request/x_request_ts/x_followups plus optional reply context in
# state/<id>.meta). When that task reaches a genuine milestone (investigation
# done, build started, shipped, failed), firstmate composes a public-safe outcome
# and posts it here as one of up to three follow-ups, within the window. Past the
# window, past the cap, or after --final, this clears the link so a later call is
# a clean no-op.
#
# Detection (no reply text needed - cheap pre-check before composing a reply):
#   fm-x-followup.sh --check <task-id>
#     exit 0, prints <request_id>  -> a follow-up is due (linked, within window
#                                      and cap)
#     exit 1, silent               -> not linked, or window/cap exhausted (link
#                                      pruned)
#
# Post (after composing the reply to a file or stdin):
#   fm-x-followup.sh <task-id> [--image <path>] [--final] --text-file <path>
#   fm-x-followup.sh <task-id> [--image <path>] [--final] -
#     Linked, within window, and under the cap: posts ONE follow-up via
#       fm-x-reply.sh --followup.
#       On success: increments the counter and KEEPS the link, unless --final
#       was passed or the new count reaches the cap, in which case the link is
#       cleared instead - this is the "we're done" signal.
#       On a relay rejection distinguishing an exhausted cap/window (see
#       fm-x-reply.sh): clears the link and skips quietly, exactly like a
#       locally-detected expiry, so an old relay (which only ever supported one
#       follow-up) or an already-exhausted binding degrades gracefully instead
#       of retrying forever.
#       On any other post failure: leaves the link in place so it can be
#       retried, exit non-zero.
#     Window or cap already exhausted: clears the link, posts nothing, exit 0
#       (silent skip).
#     Not linked: nothing to do, exit 0.
#
# --final marks this as the outcome reply: it always clears the link after a
# successful post, even if follow-ups remain under the cap. Use it for the
# final milestone (shipped, failed) so a task never leaves a stale link lying
# around waiting for a follow-up that will never come.
#
# Dry-run (FMX_DRY_RUN) flows through fm-x-reply.sh: the follow-up is recorded to
# state/x-outbox/<request_id>.json instead of posted, and the counter/link are
# mutated exactly as a live post would (increment-and-keep, or clear on --final
# / cap), so the full loop runs end to end without a public post. With --image,
# the follow-up carries one local image attachment; if the reply text splits
# into a thread, the relay attaches the image to the opener.
#
# The window is FMX_FOLLOWUP_MAX_AGE_SECS (default 604800, 7 days). The cap is
# FMX_FOLLOWUP_MAX_COUNT (default 3). FMX_NOW_OVERRIDE pins "now" for
# deterministic tests. Meta read/write lives in fm-x-lib.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

usage() {
  echo "usage: fm-x-followup.sh --check <task-id> | <task-id> [--image <path>] [--final] --text-file <path> | <task-id> [--image <path>] [--final] -" >&2
}

help() {
  cat <<'EOF'
usage: fm-x-followup.sh --check <task-id>
       fm-x-followup.sh <task-id> [--image <path>] [--final] --text-file <path>
       fm-x-followup.sh <task-id> [--image <path>] [--final] -

Post a completion follow-up (up to 3 per link, within a 7-day window) for an
X-mode-linked task and manage the link's follow-up counter.

Options:
  --check          Print the request_id when a follow-up is due.
  --image <path>   Attach one local image file; threaded replies attach it to the opener tweet or message.
  --final          Clear the link after this post regardless of the remaining count.
  --text-file <path>
                   Read follow-up text from a file.
  -                Read follow-up text from stdin.
  --help           Show this help.
EOF
}

MAX_AGE=${FMX_FOLLOWUP_MAX_AGE_SECS:-604800}
case "$MAX_AGE" in
  ''|*[!0-9]*) MAX_AGE=604800 ;;
esac

MAX_COUNT=${FMX_FOLLOWUP_MAX_COUNT:-3}
case "$MAX_COUNT" in
  ''|*[!0-9]*) MAX_COUNT=3 ;;
esac
[ "$MAX_COUNT" -ge 1 ] 2>/dev/null || MAX_COUNT=3

# Parse mode: --check is detection-only; otherwise it is a post, with the text
# source (--text-file <path> | -) deferred until after the link/window/cap
# check so a missing or exhausted link never consumes stdin or posts.
MODE=post
case "${1:-}" in
  --help|-h) help; exit 0 ;;
esac

FINAL=0
IMAGE_PATH=
if [ "${1:-}" = --check ]; then
  MODE=check
  ID=${2:-}
  if [ -z "$ID" ] || [ "$#" -gt 2 ]; then usage; exit 2; fi
else
  ID=${1:-}
  if [ -z "$ID" ]; then usage; exit 2; fi
  shift
  TS_ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --final)
        FINAL=1
        ;;
      --image)
        shift
        if [ "$#" -lt 1 ] || [ -z "$1" ]; then
          echo "fm-x-followup: missing --image path" >&2
          usage
          exit 2
        fi
        IMAGE_PATH=$1
        ;;
      *) TS_ARGS+=("$1") ;;
    esac
    shift
  done
  if [ "${#TS_ARGS[@]}" -lt 1 ]; then usage; exit 2; fi
fi

case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-x-followup: unsafe task id: $ID" >&2; exit 2 ;;
esac

META="$STATE/$ID.meta"
FOLLOWUP_LOCK_HELD=0
PAYLOAD_TEXT=
PAYLOAD_IMAGE=
# shellcheck disable=SC2329
followup_lock_release() {
  [ -z "$PAYLOAD_TEXT" ] || rm -f "$PAYLOAD_TEXT"
  [ -z "$PAYLOAD_IMAGE" ] || rm -f "$PAYLOAD_IMAGE"
  if [ "$FOLLOWUP_LOCK_HELD" -eq 1 ]; then
    fm_reconcile_lock_release "$STATE" "$ID"
    FOLLOWUP_LOCK_HELD=0
  fi
}
trap followup_lock_release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fm_reconcile_lock_acquire "$STATE" "$ID"
FOLLOWUP_LOCK_HELD=1
META_GENERATION=$(fm_reconcile_meta_generation "$META" 2>/dev/null || true)
RID=$(fmx_meta_get "$META" x_request)
TS=$(fmx_meta_get "$META" x_request_ts)
COUNT=$(fmx_meta_get "$META" x_followups)
REQ_PLATFORM=$(fmx_meta_get "$META" x_platform)
REQ_REPLY_MAX=$(fmx_meta_get "$META" x_reply_max_chars)
case "$COUNT" in
  ''|*[!0-9]*) COUNT=0 ;;
esac

# Not linked: this task did not originate from an X-mode mention. Detection fails;
# a post is simply a no-op success (firstmate need not special-case it).
if [ -z "$RID" ]; then
  if [ "$MODE" = check ]; then
    exit 1
  fi
  echo "fm-x-followup: $ID is not X-linked; nothing to post" >&2
  exit 0
fi

NOW=${FMX_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in
  ''|*[!0-9]*) echo "fm-x-followup: could not read the current time" >&2; exit 1 ;;
esac

# A missing or malformed timestamp cannot prove the follow-up is still in
# window, so treat it like an elapsed window: prune the link and skip. Being at
# or past the cap is pruned the same way.
EXPIRED=0
REASON="follow-up window elapsed"
case "$TS" in
  ''|*[!0-9]*) EXPIRED=1 ;;
  *) [ "$((NOW - TS))" -gt "$MAX_AGE" ] && EXPIRED=1 ;;
esac
if [ "$COUNT" -ge "$MAX_COUNT" ]; then
  EXPIRED=1
  REASON="follow-up cap reached"
fi

if [ "$EXPIRED" = 1 ]; then
  fmx_meta_followup_commit_locked "$META" "$META_GENERATION" "$RID" "$COUNT" clear \
    || echo "fm-x-followup: warning: could not clear the elapsed link in state/$ID.meta" >&2
  if [ "$MODE" = check ]; then
    exit 1
  fi
  echo "fm-x-followup: $REASON for $ID; skipped and cleared the link" >&2
  exit 0
fi

# Linked, within window, and under the cap.
if [ "$MODE" = check ]; then
  printf '%s\n' "$RID"
  exit 0
fi

case "${TS_ARGS[0]:-}" in
  --text-file)
    if [ "${#TS_ARGS[@]}" -lt 2 ]; then usage; exit 2; fi
    TEXT=$(cat -- "${TS_ARGS[1]}") || { echo "fm-x-followup: cannot read text file: ${TS_ARGS[1]}" >&2; exit 1; }
    ;;
  -) TEXT=$(cat) ;;
  *) TEXT=${TS_ARGS[0]:-} ;;
esac
if [ -z "$TEXT" ]; then
  echo "fm-x-followup: empty follow-up text" >&2
  exit 2
fi
PAYLOAD_TEXT="$STATE/.$ID.x-followup-text.${BASHPID:-$$}"
printf '%s' "$TEXT" > "$PAYLOAD_TEXT" || exit 1
if [ -n "$IMAGE_PATH" ] && { [ ! -f "$IMAGE_PATH" ] || [ ! -r "$IMAGE_PATH" ]; }; then
  echo "fm-x-followup: cannot read image file: $IMAGE_PATH" >&2
  exit 1
fi
IMAGE_MEDIA_TYPE=
if [ -n "$IMAGE_PATH" ]; then
  IMAGE_MEDIA_TYPE=$(fmx_image_media_type_from_path "$IMAGE_PATH") || {
    echo "fm-x-followup: unsupported image media type for: $IMAGE_PATH" >&2
    exit 1
  }
  case "$IMAGE_MEDIA_TYPE" in
    image/png) IMAGE_SUFFIX=.png ;;
    image/jpeg|image/pjpeg) IMAGE_SUFFIX=.jpg ;;
    image/gif) IMAGE_SUFFIX=.gif ;;
    image/webp) IMAGE_SUFFIX=.webp ;;
    image/bmp) IMAGE_SUFFIX=.bmp ;;
    image/tiff) IMAGE_SUFFIX=.tiff ;;
    *) exit 1 ;;
  esac
  PAYLOAD_IMAGE="$STATE/.$ID.x-followup-image.${BASHPID:-$$}$IMAGE_SUFFIX"
  cp "$IMAGE_PATH" "$PAYLOAD_IMAGE" || exit 1
fi

followup_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

TEXT_SIZE=$(wc -c < "$PAYLOAD_TEXT" | tr -d '[:space:]') || exit 1
IMAGE_SIZE=0
[ -z "$PAYLOAD_IMAGE" ] || IMAGE_SIZE=$(wc -c < "$PAYLOAD_IMAGE" | tr -d '[:space:]') || exit 1
PAYLOAD_HASH=$({
  printf 'schema=fm-x-followup-payload.v1\n'
  printf 'generation=%s\n' "$META_GENERATION"
  printf 'request_id=%s\n' "$RID"
  printf 'followup_count=%s\n' "$COUNT"
  printf 'final=%s\n' "$FINAL"
  printf 'text_bytes=%s\n' "$TEXT_SIZE"
  cat "$PAYLOAD_TEXT"
  printf '\nimage_bytes=%s\n' "$IMAGE_SIZE"
  printf 'image_media_type=%s\n' "$IMAGE_MEDIA_TYPE"
  [ -z "$PAYLOAD_IMAGE" ] || cat "$PAYLOAD_IMAGE"
} | followup_sha256) || {
  echo "fm-x-followup: no SHA-256 implementation available for payload idempotency" >&2
  exit 1
}
PAYLOAD_DIGEST="sha256:$PAYLOAD_HASH"
EXPECTED_OP_KEY="fmx-$PAYLOAD_HASH"

FOLLOWUP_OP="$STATE/$ID.x-followup-op"

followup_operation_value() {  # <key>
  fm_reconcile_record_value "$FOLLOWUP_OP" "$1"
}

followup_operation_write() {  # <prepared|delivered> <key>
  local state=$1 key=$2 tmp
  tmp="$FOLLOWUP_OP.tmp.${BASHPID:-$$}"
  {
    printf 'schema=fm-x-followup-operation.v2\n'
    printf 'state=%s\n' "$state"
    printf 'generation=%s\n' "$META_GENERATION"
    printf 'request_id=%s\n' "$RID"
    printf 'followup_count=%s\n' "$COUNT"
    printf 'payload_digest=%s\n' "$PAYLOAD_DIGEST"
    printf 'final=%s\n' "$FINAL"
    printf 'idempotency_key=%s\n' "$key"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$FOLLOWUP_OP" || { rm -f "$tmp"; return 1; }
}

OP_STATE=
OP_KEY=
if [ -f "$FOLLOWUP_OP" ] \
  && [ "$(followup_operation_value generation)" = "$META_GENERATION" ] \
  && [ "$(followup_operation_value request_id)" = "$RID" ] \
  && [ "$(followup_operation_value followup_count)" = "$COUNT" ]; then
  if [ "$(followup_operation_value schema)" != fm-x-followup-operation.v2 ] \
    || [ "$(followup_operation_value payload_digest)" != "$PAYLOAD_DIGEST" ] \
    || [ "$(followup_operation_value final)" != "$FINAL" ] \
    || [ "$(followup_operation_value idempotency_key)" != "$EXPECTED_OP_KEY" ]; then
    echo "fm-x-followup: payload differs from the durable operation for $ID; retry the original text, attachment, and finality" >&2
    exit 1
  fi
  OP_STATE=$(followup_operation_value state)
  OP_KEY=$EXPECTED_OP_KEY
fi
case "$OP_STATE:$OP_KEY" in
  prepared:*|delivered:*)
    case "$OP_KEY" in ''|*[!A-Za-z0-9._:-]*) OP_STATE=; OP_KEY= ;; esac
    ;;
  *) OP_STATE=; OP_KEY= ;;
esac
if [ -z "$OP_KEY" ]; then
  rm -f "$FOLLOWUP_OP"
  OP_KEY=$EXPECTED_OP_KEY
  followup_operation_write prepared "$OP_KEY" || {
    echo "fm-x-followup: could not prepare durable follow-up operation for $ID" >&2
    exit 1
  }
  OP_STATE=prepared
fi

# Post the follow-up. fm-x-reply owns text reading, thread-split, dry-run, the
# endpoint, and the never-inline safety; we only pass the text source and any
# recorded reply-platform context through.
declare -a REPLY_ENV=()
declare -a REPLY_ARGS=(--text-file "$PAYLOAD_TEXT")
[ -z "$PAYLOAD_IMAGE" ] || REPLY_ARGS=(--image "$PAYLOAD_IMAGE" "${REPLY_ARGS[@]}")
REPLY_ENV+=("FMX_IDEMPOTENCY_KEY=$OP_KEY")
case "$REQ_PLATFORM" in
  discord|x) REPLY_ENV+=("FMX_REPLY_PLATFORM=$REQ_PLATFORM") ;;
esac
case "$REQ_REPLY_MAX" in
  ''|*[!0-9]*) ;;
  *) REPLY_ENV+=("FMX_REPLY_MAX_CHARS=$REQ_REPLY_MAX") ;;
esac
if [ "$OP_STATE" = delivered ]; then
  post_rc=0
elif [ "${#REPLY_ENV[@]}" -gt 0 ]; then
  set +e
  env "${REPLY_ENV[@]}" "$FM_ROOT/bin/fm-x-reply.sh" "$RID" --followup "${REPLY_ARGS[@]}" >/dev/null
  post_rc=$?
  set -e
else
  set +e
  "$FM_ROOT/bin/fm-x-reply.sh" "$RID" --followup "${REPLY_ARGS[@]}" >/dev/null
  post_rc=$?
  set -e
fi

case "$post_rc" in
  0)
    followup_operation_write delivered "$OP_KEY" || {
      echo "fm-x-followup: posted but could not persist the delivered operation for $ID" >&2
      exit 1
    }
    NEWCOUNT=$((COUNT + 1))
    if [ "$FINAL" = 1 ] || [ "$NEWCOUNT" -ge "$MAX_COUNT" ]; then
      if ! fmx_meta_followup_commit_locked "$META" "$META_GENERATION" "$RID" "$COUNT" clear; then
        echo "fm-x-followup: error: posted but could not clear the link in state/$ID.meta" >&2
        exit 1
      fi
      rm -f "$FOLLOWUP_OP"
    elif ! fmx_meta_followup_commit_locked "$META" "$META_GENERATION" "$RID" "$COUNT" set "$NEWCOUNT"; then
      if ! fmx_meta_followup_commit_locked "$META" "$META_GENERATION" "$RID" "$COUNT" clear; then
        echo "fm-x-followup: error: posted but could not record the follow-up count or clear the link in state/$ID.meta" >&2
        exit 1
      fi
      rm -f "$FOLLOWUP_OP"
      echo "fm-x-followup: warning: posted but could not record the follow-up count in state/$ID.meta; cleared the link to avoid duplicate follow-ups" >&2
    else
      rm -f "$FOLLOWUP_OP"
    fi
    printf '%s\n' "$RID"
    exit 0
    ;;
  9)
    # fm-x-reply.sh distinguishes a relay rejection of this specific follow-up
    # (cap or window exhausted relay-side) with exit 9. Treat it exactly like a
    # locally-detected expiry: clear the link and skip quietly. This is also the
    # graceful-degradation path against an old relay that only ever supported
    # one follow-up, or a binding the relay already considers exhausted for any
    # other reason - either way, retrying would never succeed.
    if fmx_meta_followup_commit_locked "$META" "$META_GENERATION" "$RID" "$COUNT" clear; then
      rm -f "$FOLLOWUP_OP"
    else
      echo "fm-x-followup: warning: could not clear the rejected link in state/$ID.meta" >&2
    fi
    echo "fm-x-followup: relay rejected the follow-up for $ID (cap or window exhausted); skipped and cleared the link" >&2
    exit 0
    ;;
  *)
    # Post failed for another reason (network, auth, transport): leave the link
    # so firstmate can retry on a later pass.
    echo "fm-x-followup: follow-up post failed for $ID; left the link in place to retry" >&2
    exit 1
    ;;
esac
