#!/bin/bash
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/data/.hermes}"
PROFILE_GATEWAYS="${HERMES_PROFILE_GATEWAYS:-}"
PROFILE_GATEWAYS_FILE="${HERMES_PROFILE_GATEWAYS_FILE:-$HERMES_HOME/profile-gateways.txt}"
PROFILE_GATEWAY_RESTART_DELAY="${HERMES_PROFILE_GATEWAY_RESTART_DELAY:-5}"

log() {
  printf '[%s] [start] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# Mirror dashboard-ref-only's startup: create every directory hermes expects
# and seed a default config.yaml if the volume is empty. Without these,
# `hermes dashboard` endpoints that hit logs/, sessions/, cron/, etc. can fail
# with opaque errors even though no auth is actually involved.
mkdir -p "$HERMES_HOME/cron" "$HERMES_HOME/sessions" "$HERMES_HOME/logs" \
         "$HERMES_HOME/memories" "$HERMES_HOME/skills" "$HERMES_HOME/pairing" \
         "$HERMES_HOME/hooks" "$HERMES_HOME/image_cache" "$HERMES_HOME/audio_cache" \
         "$HERMES_HOME/workspace"

if [ ! -f "$HERMES_HOME/config.yaml" ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example "$HERMES_HOME/config.yaml"
fi

[ ! -f "$HERMES_HOME/.env" ] && touch "$HERMES_HOME/.env"

# Clear stale gateway PID files left over from the previous container.
# /data is a persistent volume, so PID files survive restarts even though the
# processes do not.
rm -f "$HERMES_HOME/gateway.pid"

profiles=()
if [ -n "$PROFILE_GATEWAYS" ]; then
  IFS=',' read -ra env_profiles <<< "$PROFILE_GATEWAYS"
  for profile in "${env_profiles[@]}"; do
    profile="$(printf '%s' "$profile" | xargs)"
    [ -n "$profile" ] && profiles+=("$profile")
  done
fi

if [ -f "$PROFILE_GATEWAYS_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(printf '%s' "$line" | xargs)"
    [[ -z "$line" || "$line" == \#* ]] && continue
    profiles+=("$line")
  done < "$PROFILE_GATEWAYS_FILE"
fi

# Deduplicate profiles while preserving order.
unique_profiles=()
for profile in "${profiles[@]}"; do
  seen=0
  for existing in "${unique_profiles[@]}"; do
    if [ "$existing" = "$profile" ]; then
      seen=1
      break
    fi
  done
  [ "$seen" -eq 0 ] && unique_profiles+=("$profile")
done
profiles=("${unique_profiles[@]}")

for profile in "${profiles[@]}"; do
  rm -f "$HERMES_HOME/profiles/$profile/gateway.pid"
done

profile_pids=()

start_profile_gateway() {
  local profile="$1"
  local profile_dir="$HERMES_HOME/profiles/$profile"
  local log_dir="$profile_dir/logs"
  local log_file="$log_dir/start-profile-gateway.log"

  if [ ! -d "$profile_dir" ]; then
    log "profile '$profile' does not exist at $profile_dir; skipping"
    return 0
  fi

  mkdir -p "$log_dir"
  log "starting profile gateway '$profile'"
  HERMES_HOME="$HERMES_HOME" hermes --profile "$profile" gateway run >> "$log_file" 2>&1 &
  profile_pids+=("$!")
  log "profile gateway '$profile' pid=${profile_pids[-1]} log=$log_file"
}

stop_children() {
  log "shutdown requested; stopping ${#profile_pids[@]} profile gateway(s)"
  for pid in "${profile_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait || true
}
trap stop_children TERM INT

for profile in "${profiles[@]}"; do
  start_profile_gateway "$profile"
done

if [ "${#profiles[@]}" -gt 0 ]; then
  log "configured profile gateways: ${profiles[*]}"
  (
    while true; do
      sleep "$PROFILE_GATEWAY_RESTART_DELAY"
      for i in "${!profiles[@]}"; do
        profile="${profiles[$i]}"
        pid="${profile_pids[$i]:-}"
        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
          log "profile gateway '$profile' is not running; restarting"
          # Keep array index aligned with profiles.
          local_profile_dir="$HERMES_HOME/profiles/$profile"
          local_log_dir="$local_profile_dir/logs"
          local_log_file="$local_log_dir/start-profile-gateway.log"
          if [ -d "$local_profile_dir" ]; then
            mkdir -p "$local_log_dir"
            HERMES_HOME="$HERMES_HOME" hermes --profile "$profile" gateway run >> "$local_log_file" 2>&1 &
            profile_pids[$i]="$!"
            log "profile gateway '$profile' restarted pid=${profile_pids[$i]}"
          fi
        fi
      done
    done
  ) &
  monitor_pid="$!"
  profile_pids+=("$monitor_pid")
else
  log "no extra profile gateways configured; set HERMES_PROFILE_GATEWAYS or $PROFILE_GATEWAYS_FILE"
fi

exec python /app/server.py
