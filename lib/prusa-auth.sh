# shellcheck shell=bash
# Shared Prusa Connect authentication, sourced by prusa-connect-fetch and
# prusa-connect-command.
#
# There is one implementation on purpose. Prusa rotates the refresh token on
# every use, so two copies of this logic could each write back a rotation the
# other had already invalidated, locking the plugin out of the account.
#
# Every failure is reported as JSON on stdout and exits 0, so a caller's UI can
# render the reason rather than guess why a process died. A failure the user can
# fix carries "needsLogin": true.
#
# The refresh token never reaches argv: it goes to curl over stdin.

readonly PRUSA_PLUGIN_ID="hegjon.prusa-connect"
readonly PRUSA_CLIENT_ID="MRHTlZhZqkNrrQ6FUPtjyusAz8nc59ErHXP8XkS4"
readonly PRUSA_TOKEN_URL="https://account.prusa3d.com/o/token/"

readonly PRUSA_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/prusa-connect"
readonly PRUSA_ACCOUNT_FILE="$PRUSA_STATE_DIR/account"
readonly PRUSA_CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/omarchy-prusa-connect"
readonly PRUSA_TOKEN_FILE="$PRUSA_CACHE_DIR/access-token"
readonly PRUSA_REFRESH_LOCK="$PRUSA_CACHE_DIR/refresh.lock"

die() {
  jq -cn --arg m "$1" '{error: $m}'
  exit 0
}

die_needs_login() {
  jq -cn --arg m "$1" '{error: $m, needsLogin: true}'
  exit 0
}

# Failures are recorded rather than raised, because these functions run inside
# command substitutions and `exit` there ends only the subshell — the JSON would
# be captured as the function's value and used as if it were a token. Callers
# check the return status and call prusa_fail.
PRUSA_ERROR=""
PRUSA_ERROR_NEEDS_LOGIN=0

prusa_set_error() {
  PRUSA_ERROR="$1"
  PRUSA_ERROR_NEEDS_LOGIN="${2:-0}"
  return 1
}

prusa_fail() {
  if [[ ${PRUSA_ERROR_NEEDS_LOGIN:-0} == 1 ]]; then
    die_needs_login "${PRUSA_ERROR:-Not signed in to Prusa Connect}"
  fi
  die "${PRUSA_ERROR:-Prusa Connect request failed}"
}

prusa_release_refresh_lock() {
  [[ -n ${PRUSA_LOCK_FD:-} ]] || return 0
  exec {PRUSA_LOCK_FD}>&- 2>/dev/null
  PRUSA_LOCK_FD=""
}

prusa_urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

# One HTTP request. Takes a curl config (one option per line, as `curl
# --config` reads it) and sets PRUSA_HTTP_CODE and PRUSA_HTTP_BODY, so a caller
# can act on the status without a subshell swallowing it. The config is handed
# to curl on stdin, so a bearer token in it never appears in argv.
#
# Call it directly, not inside $(...): the whole point is that the results land
# in the caller's shell.
prusa_http() {
  local response
  response=$(printf '%s\nsilent\nshow-error\n' "$1" | curl --config - -m 30 -w '\n%{http_code}')
  PRUSA_HTTP_CODE=$(tail -n1 <<<"$response")
  PRUSA_HTTP_BODY=$(sed '$d' <<<"$response")
}

# The failure arms every Connect request shares. Anything unrecognised returns,
# so the caller can add the arms that mean something for its own endpoint.
prusa_die_on_common_http_failure() {
  case "$PRUSA_HTTP_CODE" in
    401|403)
      # The cached token was rejected; drop it so the next run renews cleanly.
      rm -f "$PRUSA_TOKEN_FILE"
      die_needs_login "Prusa Connect rejected the session — run prusa-connect-login" ;;
    429) die "Prusa Connect is rate limiting — try again shortly" ;;
    "")  die "Could not reach Prusa Connect" ;;
  esac
}

prusa_require_commands() {
  local cmd
  for cmd in curl jq secret-tool; do
    command -v "$cmd" >/dev/null || die "required command not found: $cmd"
  done
  mkdir -p "$PRUSA_CACHE_DIR" 2>/dev/null
  chmod 700 "$PRUSA_CACHE_DIR" 2>/dev/null
}

# Sets PRUSA_ACCOUNT.
prusa_account() {
  # Not `return $(prusa_set_error ...)`: that runs the setter in a subshell and
  # the recorded error is lost with it, which is the whole trap this avoids.
  if [[ ! -r $PRUSA_ACCOUNT_FILE ]]; then
    prusa_set_error "Not signed in to Prusa Connect" 1
    return 1
  fi
  PRUSA_ACCOUNT=$(head -n1 "$PRUSA_ACCOUNT_FILE")
  if [[ -z $PRUSA_ACCOUNT ]]; then
    prusa_set_error "Not signed in to Prusa Connect" 1
    return 1
  fi
}

prusa_read_refresh_token() {
  secret-tool lookup application "$PRUSA_PLUGIN_ID" account "$1" 2>/dev/null
}

prusa_write_refresh_token() {
  printf '%s' "$2" | secret-tool store \
    --label="Prusa Connect refresh token" \
    application "$PRUSA_PLUGIN_ID" account "$1" 2>/dev/null
}

prusa_read_cached_access_token() {
  [[ -r $PRUSA_TOKEN_FILE ]] || return 1
  local expiry token
  # `read` reports failure at end of file even when it filled the variables,
  # and older caches were written without a trailing newline, so judge by
  # what was read rather than by read's status.
  IFS=$'\t' read -r expiry token <"$PRUSA_TOKEN_FILE" || [[ -n ${token:-} ]] || return 1
  [[ ${expiry:-} =~ ^[0-9]+$ && -n ${token:-} ]] || return 1
  # Refresh a minute early so a token cannot expire mid-request.
  (( expiry > $(date +%s) + 60 )) || return 1
  printf '%s' "$token"
}

# Sets PRUSA_ACCESS_TOKEN.
#
# Serialized across processes. Prusa rotates the refresh token on every use, so
# two refreshes racing each other leave the keyring holding whichever token was
# written last while Prusa considers only the last *issued* one valid — and the
# account is then locked out until someone pastes a new token by hand. This is
# reachable in normal use: the widget polls on a timer while a person runs the
# CLI, and it has happened.
prusa_refresh_access_token() {
  local account="$1"
  local refresh body response code payload access rotated expires_in tmp

  exec {PRUSA_LOCK_FD}>"$PRUSA_REFRESH_LOCK" 2>/dev/null || PRUSA_LOCK_FD=""
  if [[ -n ${PRUSA_LOCK_FD:-} ]]; then
    flock "$PRUSA_LOCK_FD" 2>/dev/null
    # Another process may have refreshed while this one waited, so take its
    # result rather than spending a rotation of our own.
    if PRUSA_ACCESS_TOKEN=$(prusa_read_cached_access_token); then
      exec {PRUSA_LOCK_FD}>&-
      return 0
    fi
  fi

  refresh=$(prusa_read_refresh_token "$account")
  [[ -n $refresh ]] ||
    { prusa_release_refresh_lock
      prusa_set_error "No Prusa Connect credentials in the keyring" 1; return 1; }

  body="grant_type=refresh_token&client_id=$(prusa_urlencode "$PRUSA_CLIENT_ID")"
  body+="&refresh_token=$(prusa_urlencode "$refresh")"

  prusa_http "$(printf 'url = "%s"\nheader = "Content-Type: application/x-www-form-urlencoded"\ndata = "%s"' \
    "$PRUSA_TOKEN_URL" "$body")"
  unset body refresh

  code="$PRUSA_HTTP_CODE"
  payload="$PRUSA_HTTP_BODY"
  unset PRUSA_HTTP_BODY

  if [[ $code != 200 ]]; then
    case "$(jq -r '.error // empty' <<<"$payload" 2>/dev/null)" in
      invalid_grant)
        prusa_release_refresh_lock
        prusa_set_error "Prusa Connect sign-in has expired — run prusa-connect-login" 1
        return 1 ;;
      *)
        prusa_release_refresh_lock
        prusa_set_error "Could not renew the Prusa Connect session (HTTP $code)"
        return 1 ;;
    esac
  fi

  access=$(jq -r '.access_token // empty' <<<"$payload")
  rotated=$(jq -r '.refresh_token // empty' <<<"$payload")
  expires_in=$(jq -r '.expires_in // 3600' <<<"$payload")
  unset payload
  [[ -n $access ]] ||
    { prusa_release_refresh_lock; prusa_set_error "Prusa returned no access token"; return 1; }

  # Prusa rotates the refresh token; persist it at once or the next run locks us out.
  if [[ -n $rotated ]]; then
    prusa_write_refresh_token "$account" "$rotated" ||
      { prusa_release_refresh_lock
        prusa_set_error "Could not update the keyring — is your login keyring unlocked?"; return 1; }
  fi
  unset rotated

  [[ $expires_in =~ ^[0-9]+$ ]] || expires_in=3600
  tmp=$(mktemp "$PRUSA_CACHE_DIR/token.XXXXXX") ||
    { prusa_release_refresh_lock; prusa_set_error "Could not cache the access token"; return 1; }
  printf '%s\t%s\n' "$(( $(date +%s) + expires_in ))" "$access" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$PRUSA_TOKEN_FILE"

  PRUSA_ACCESS_TOKEN="$access"
  prusa_release_refresh_lock
}

# Sets PRUSA_ACCESS_TOKEN to a usable token, renewing a spent one. Returns
# non-zero on failure with the reason in PRUSA_ERROR; call prusa_fail to report.
prusa_ensure_access_token() {
  prusa_account || return 1
  if PRUSA_ACCESS_TOKEN=$(prusa_read_cached_access_token); then
    return 0
  fi
  prusa_refresh_access_token "$PRUSA_ACCOUNT" || return 1
  [[ -n ${PRUSA_ACCESS_TOKEN:-} ]] ||
    { prusa_set_error "No Prusa Connect access token"; return 1; }
}
