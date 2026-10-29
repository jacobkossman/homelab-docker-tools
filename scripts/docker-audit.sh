#!/usr/bin/env bash
# docker-audit.sh — report which app folders are in use, stopped, or unused.
# Read-only: never stops, removes or moves anything.
#
# Usage: sudo ./docker-audit.sh BASE_DIR
#   BASE_DIR is the folder holding one subfolder per app (compose file + data).
#   sudo lets it read sizes of folders owned by container users.
#
# A folder counts as "used" by a container if ANY of these match:
#   - the container's compose working_dir is the folder
#   - one of the container's compose config files lives in the folder
#   - one of the container's mounts (bind source or volume path) is inside the folder
# This catches renamed projects (`name:`), non-default compose file names,
# and containers started with plain `docker run` that bind-mount the folder.
#
# Limitation: it only knows about Docker. A folder used by a native service
# (systemd, cron) shows as UNUSED, so check before archiving anything.

set -euo pipefail
trap 'echo "error: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

[ "$#" -ge 1 ] || { echo "usage: $0 BASE_DIR" >&2; exit 2; }
BASE="$1"

die() { echo "error: $*" >&2; exit 1; }
command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "cannot talk to docker (try sudo, or add user to docker group)"
[ -d "$BASE" ] || die "base folder not found: $BASE"
BASE="$(readlink -f "$BASE")"
echo "Base: $BASE   Host: $(hostname)"
[ "$(id -u)" -eq 0 ] || echo "(not root: sizes/dates may be incomplete for folders owned by container users)"

# --- collect container facts (one inspect call) --------------------------------
# fields: name | status | working_dir | config_files | started | finished | mounts
# field separator: ASCII unit separator, not tab, because `read` collapses
# consecutive whitespace delimiters and would shift fields when a label is empty
TAB=$'\x1f'
FMT='{{.Name}}'"$TAB"'{{.State.Status}}'"$TAB"
FMT+='{{index .Config.Labels "com.docker.compose.project.working_dir"}}'"$TAB"
FMT+='{{index .Config.Labels "com.docker.compose.project.config_files"}}'"$TAB"
FMT+='{{.State.StartedAt}}'"$TAB"'{{.State.FinishedAt}}'"$TAB"
FMT+='{{range .Mounts}}{{.Source}},{{end}}'

mapfile -t IDS < <(docker ps -aq --no-trunc)
CONTAINERS=()
if [ "${#IDS[@]}" -gt 0 ]; then
  mapfile -t CONTAINERS < <(docker inspect --format "$FMT" "${IDS[@]}")
fi

# resolve a path if it exists, otherwise return it unchanged
rp() { readlink -f -- "$1" 2>/dev/null || printf '%s' "$1"; }

# is $1 equal to or inside folder $2?
inside() { [ "$1" = "$2" ] || [[ "$1" == "$2/"* ]]; }

# --- per-folder evaluation -----------------------------------------------------
declare -A CLAIMED   # container name -> 1 if matched to some folder
ROWS=()

shopt -s nullglob dotglob
for dir in "$BASE"/*/; do
  dir="${dir%/}"
  app="$(basename -- "$dir")"
  [[ "$app" == .* ]] && continue
  real="$(rp "$dir")"

  running=(); stopped=(); last=""
  for line in "${CONTAINERS[@]}"; do
    IFS="$TAB" read -r name status wd cfgs started finished mounts <<< "$line"
    name="${name#/}"
    match=0
    [ -n "$wd" ] && inside "$(rp "$wd")" "$real" && match=1
    if [ $match -eq 0 ] && [ -n "$cfgs" ]; then
      IFS=',' read -ra files <<< "$cfgs"
      for f in "${files[@]}"; do inside "$(rp "$f")" "$real" && { match=1; break; }; done
    fi
    if [ $match -eq 0 ] && [ -n "$mounts" ]; then
      IFS=',' read -ra srcs <<< "$mounts"
      for s in "${srcs[@]}"; do [ -n "$s" ] && inside "$(rp "$s")" "$real" && { match=1; break; }; done
    fi
    [ $match -eq 1 ] || continue

    CLAIMED["$name"]=1
    if [ "$status" = "running" ]; then running+=("$name"); else stopped+=("$name"); fi
    for t in "$started" "$finished"; do
      [[ "$t" == 0001-* || -z "$t" ]] && continue
      [[ -z "$last" || "$t" > "$last" ]] && last="$t"
    done
  done

  # compose file present / conventionally named?
  notes=()
  compose=( "$dir"/*.yml "$dir"/*.yaml )
  if [ "${#compose[@]}" -eq 0 ]; then
    notes+=("no compose file")
  fi

  if [ "${#running[@]}" -gt 0 ]; then
    state="RUNNING"; who="${running[*]}"
    [ "${#stopped[@]}" -gt 0 ] && notes+=("also stopped: ${stopped[*]}")
  elif [ "${#stopped[@]}" -gt 0 ]; then
    state="STOPPED"; who="${stopped[*]}"
  else
    state="UNUSED"; who="-"
  fi

  if [ -n "$last" ]; then
    when="${last%%T*}"
  else
    # no container ever: fall back to newest file modification in the folder
    # find exits non-zero on unreadable subfolders (container-owned data); keep what it found
    newest="$( { find "$dir" -type f -printf '%T@\n' 2>/dev/null || true; } | sort -n | tail -1)"
    when="${newest:+$(date -d "@${newest%.*}" +%F) (files)}"
    when="${when:--}"
  fi
  size="$( { du -sh -- "$dir" 2>/dev/null || true; } | cut -f1)"

  case "$state" in UNUSED) ord=0;; STOPPED) ord=1;; *) ord=2;; esac
  note="${notes[*]:-}"
  ROWS+=("$ord$TAB$state$TAB$app$TAB$size$TAB$when$TAB$who$TAB${note:-}")
done

# --- report ------------------------------------------------------------------
echo
printf '%-8s  %-24s  %6s  %-18s  %-28s  %s\n' STATE FOLDER SIZE "LAST ACTIVE" CONTAINERS NOTES
printf '%-8s  %-24s  %6s  %-18s  %-28s  %s\n' -------- ------------------------ ------ ------------------ ---------------------------- -----
if [ "${#ROWS[@]}" -gt 0 ]; then
  printf '%s\n' "${ROWS[@]}" | sort -t "$TAB" -k1,1 -k3,3 |
  while IFS="$TAB" read -r _ state app size when who note; do
    printf '%-8s  %-24s  %6s  %-18s  %-28s  %s\n' "$state" "$app" "$size" "$when" "$who" "$note"
  done
fi

# containers not tied to any folder under BASE
echo
echo "Containers not linked to any folder in $BASE:"
found=0
for line in "${CONTAINERS[@]}"; do
  IFS="$TAB" read -r name status wd _ <<< "$line"
  name="${name#/}"
  [ -n "${CLAIMED[$name]:-}" ] && continue
  found=1
  if [ -n "$wd" ] && inside "$(rp "$wd")" "$BASE" && [ ! -d "$wd" ]; then
    why="compose folder deleted: $wd"
  elif [ -n "$wd" ]; then
    why="compose project at $wd"
  else
    why="not started by compose"
  fi
  printf '  %-28s  %-10s  %s\n' "$name" "$status" "$why"
done
[ $found -eq 0 ] && echo "  (none)"
exit 0
