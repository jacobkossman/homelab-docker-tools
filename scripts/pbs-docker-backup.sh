#!/usr/bin/env bash
# pbs-docker-backup.sh — back up every app folder in BASE to Proxmox Backup Server,
# one app at a time, so an app is only stopped while its own folder is backed up.
#
# Run as root (container data is often owned by other users).
# Settings live in /etc/pbs-docker-backup.env (see examples/pbs-docker-backup.env.example):
#   BASE=/home/<user>/docker               folder with one subfolder per app
#   PBS_REPOSITORY='<user>@pbs!<token>@<pbs-host>:8007:<datastore>'
#   PBS_PASSWORD='<token secret>'
#   PBS_FINGERPRINT='<fingerprint>'
#   # optional
#   PBS_NAMESPACE=docker                   parent namespace (default docker)
#   HOST_NAME=myvm                         name used in PBS and HA (default: hostname -s)
#   EXCLUDES="recordings clips ..."        globs skipped in every app ("" = none)
#   MQTT_HOST=homeassistant.local          report status to Home Assistant over MQTT
#   MQTT_PORT=1883                         (needs mosquitto-clients)
#   MQTT_USER=<user>
#   MQTT_PASS='<password>'
#
# HA entities (via MQTT discovery), device "Docker backup <host>":
#   sensor.docker_backup_<host>_status        ok / failed / running, attributes per run
#   sensor.docker_backup_<host>_last_success  timestamp
# plus a non-retained JSON event on pbs-docker-backup/<host>/event when a run fails.
#
# Each app becomes its own backup group in PBS: host/<app>, in namespace docker/<host>.
# Create the docker/<host> namespace in the PBS UI once per host before the first run.
#
# Per-app markers (empty files in the app folder):
#   .nobackup        skip this folder entirely
#   .stopforbackup   stop its containers during its backup (databases, sqlite)
# Per-app exclusions: put a .pxarexclude file in the folder (one glob per line,
# a leading / anchors the pattern to the app folder, e.g. /config/metadata).
#
# Named Docker volumes used by an app's containers are backed up in the same
# snapshot as extra archives, vol-<volume>.pxar. To restore one, stop the app and
# restore that archive into the volume's path (docker volume inspect <volume>).

set -euo pipefail

CONF="${CONF:-/etc/pbs-docker-backup.env}"
[ -r "$CONF" ] || { echo "error: cannot read $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
export PBS_REPOSITORY PBS_PASSWORD PBS_FINGERPRINT
: "${BASE:?BASE not set in $CONF}"
HOST="${HOST_NAME:-$(hostname -s)}"
NS="${PBS_NAMESPACE:-docker}/$HOST"

# regenerable data skipped in every app (globs, matched at any depth)
# (read -a splits on spaces without expanding globs like *.tmp against the cwd)
EXCLUDE_ARGS=()
read -ra _patterns <<< "${EXCLUDES-recordings clips transcodes cache logs MediaCover}"
for pattern in ${_patterns[@]+"${_patterns[@]}"}; do
  EXCLUDE_ARGS+=(--exclude "$pattern")
done

log() { echo "$(date '+%F %T') $*"; }

# --- MQTT status reporting (skipped when MQTT_HOST is unset) -------------------
MQ_BASE="pbs-docker-backup/$HOST"
MQ_DIR=""
if [ -n "${MQTT_HOST:-}" ]; then
  if command -v mosquitto_pub >/dev/null; then
    # credentials go in a private options file, not on the command line (visible in ps)
    MQ_DIR="$(mktemp -d)"
    (umask 077; printf -- '-h %s\n-p %s\n-u %s\n-P %s\n' \
      "$MQTT_HOST" "${MQTT_PORT:-1883}" "${MQTT_USER:-}" "${MQTT_PASS:-}" > "$MQ_DIR/mosquitto_pub")
  else
    log "WARNING: MQTT_HOST set but mosquitto_pub not installed (apt install mosquitto-clients)"
  fi
fi

mqtt_pub() {
  [ -n "$MQ_DIR" ] || return 0
  XDG_CONFIG_HOME="$MQ_DIR" mosquitto_pub -r -t "$1" -m "$2" || log "WARNING: MQTT publish to $1 failed"
}

# one-off (not retained) failure event, so HA automations don't re-fire after a restart
mqtt_failed_event() {
  [ -n "$MQ_DIR" ] || return 0
  XDG_CONFIG_HOME="$MQ_DIR" mosquitto_pub -t "$MQ_BASE/event" -m "$1" || log "WARNING: MQTT publish to $MQ_BASE/event failed"
}

json_list() {
  local out="" x
  for x in "$@"; do out+="\"$x\","; done
  printf '[%s]' "${out%,}"
}

mqtt_discovery() {
  local dev="{\"identifiers\":[\"pbs_docker_backup_$HOST\"],\"name\":\"Docker backup $HOST\",\"manufacturer\":\"pbs-docker-backup\"}"
  mqtt_pub "homeassistant/sensor/pbs_docker_backup_$HOST/status/config" \
    "{\"name\":\"Status\",\"unique_id\":\"pbs_docker_backup_${HOST}_status\",\"state_topic\":\"$MQ_BASE/state\",\"json_attributes_topic\":\"$MQ_BASE/attributes\",\"icon\":\"mdi:backup-restore\",\"device\":$dev}"
  mqtt_pub "homeassistant/sensor/pbs_docker_backup_$HOST/last_success/config" \
    "{\"name\":\"Last success\",\"unique_id\":\"pbs_docker_backup_${HOST}_last_success\",\"state_topic\":\"$MQ_BASE/last_success\",\"device_class\":\"timestamp\",\"device\":$dev}"
}

# compose v2 plugin if present, else legacy docker-compose
compose() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi
}

# running container ids belonging to the compose project in folder $1
running_in() {
  docker ps -q --filter "label=com.docker.compose.project.working_dir=$1"
}

# named volumes ("name|host path") used by any container, running or not, of folder $1
volumes_in() {
  local ids
  ids="$(docker ps -aq --filter "label=com.docker.compose.project.working_dir=$1")"
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086
  docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}|{{.Source}}{{"\n"}}{{end}}{{end}}' $ids |
    grep -v '^$' | sort -u
}

# only read files that changed since the last snapshot, if the client supports it
EXTRA=()
if proxmox-backup-client help backup 2>&1 | grep -q 'change-detection-mode'; then
  EXTRA+=(--change-detection-mode metadata)
fi

# app currently stopped by us; restarted on exit if the script dies mid-backup
STOPPED_DIR=""
start_app() {
  local dir="$1"
  log "starting $(basename "$dir")"
  (cd "$dir" && compose start) || log "WARNING: failed to start $(basename "$dir")"
}
REPORTED=0
on_exit() {
  local rc=$?
  if [ -n "$STOPPED_DIR" ]; then start_app "$STOPPED_DIR"; fi
  # script died before its summary: still tell HA
  if [ "$rc" -ne 0 ] && [ "$REPORTED" -eq 0 ]; then
    local attrs="{\"host\":\"$HOST\",\"last_run\":\"$(date -Is)\",\"error\":\"script exited early with code $rc\"}"
    mqtt_pub "$MQ_BASE/attributes" "$attrs"
    mqtt_pub "$MQ_BASE/state" "failed"
    mqtt_failed_event "$attrs"
  fi
  if [ -n "$MQ_DIR" ]; then rm -rf "$MQ_DIR"; fi
}
trap on_exit EXIT

OK=(); FAILED=(); SKIPPED=()
START=$(date +%s)
mqtt_discovery
mqtt_pub "$MQ_BASE/state" "running"

[ -d "$BASE" ] || { log "error: BASE folder not found: $BASE"; exit 1; }

shopt -s nullglob
for dir in "$BASE"/*/; do
  dir="$(readlink -f "${dir%/}")"
  app="$(basename "$dir")"
  [[ "$app" == .* ]] && continue
  if [ -e "$dir/.nobackup" ]; then
    SKIPPED+=("$app")
    continue
  fi
  # archive and group names allow only letters, digits, '_' and '-'
  name="$(printf '%s' "$app" | tr -c 'A-Za-z0-9_-' '_')"

  if [ -e "$dir/.stopforbackup" ] && [ -n "$(running_in "$dir")" ]; then
    log "stopping $app"
    if (cd "$dir" && compose stop); then
      STOPPED_DIR="$dir"
    else
      log "WARNING: could not stop $app, backing it up live"
    fi
  fi

  ARCHIVES=("$name.pxar:$dir")
  while IFS='|' read -r vol src; do
    [ -n "$vol" ] && [ -d "$src" ] || continue
    ARCHIVES+=("vol-$(printf '%s' "$vol" | tr -c 'A-Za-z0-9_-' '_').pxar:$src")
  done < <(volumes_in "$dir")
  if [ "${#ARCHIVES[@]}" -gt 1 ]; then
    log "backing up $app (+$(( ${#ARCHIVES[@]} - 1 )) volume(s))"
  else
    log "backing up $app"
  fi
  if proxmox-backup-client backup "${ARCHIVES[@]}" \
      --ns "$NS" \
      --backup-id "$name" \
      ${EXCLUDE_ARGS[@]+"${EXCLUDE_ARGS[@]}"} \
      ${EXTRA[@]+"${EXTRA[@]}"}; then
    OK+=("$app")
  else
    log "ERROR: backup of $app failed"
    FAILED+=("$app")
  fi

  if [ -n "$STOPPED_DIR" ]; then
    start_app "$STOPPED_DIR"
    STOPPED_DIR=""
  fi
done

log "summary: ${#OK[@]} ok, ${#FAILED[@]} failed, ${#SKIPPED[@]} skipped"

NOW="$(date -Is)"
ATTRS="{\"host\":\"$HOST\",\"last_run\":\"$NOW\",\"duration_s\":$(( $(date +%s) - START )),\"ok\":${#OK[@]},\"failed\":$(json_list ${FAILED[@]+"${FAILED[@]}"}),\"skipped\":$(json_list ${SKIPPED[@]+"${SKIPPED[@]}"})}"
mqtt_pub "$MQ_BASE/attributes" "$ATTRS"
if [ "${#FAILED[@]}" -eq 0 ]; then
  mqtt_pub "$MQ_BASE/state" "ok"
  mqtt_pub "$MQ_BASE/last_success" "$NOW"
else
  mqtt_pub "$MQ_BASE/state" "failed"
  mqtt_failed_event "$ATTRS"
fi
REPORTED=1

[ "${#SKIPPED[@]}" -eq 0 ] || log "skipped: ${SKIPPED[*]}"
[ "${#FAILED[@]}" -eq 0 ] || { log "failed: ${FAILED[*]}"; exit 1; }
