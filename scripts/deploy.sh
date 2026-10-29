#!/usr/bin/env bash
# deploy.sh — install the backup script on each Docker host as a root-owned file
# in /usr/local/bin, over SSH. Hosts don't need git, credentials or a shared mount.
#
# Usage: ./deploy.sh              deploy to every host in deploy.hosts
#        ./deploy.sh vm1 vm2      only these hosts (names from deploy.hosts)
#
# deploy.hosts (next to this script, not committed; see deploy.hosts.example):
#   <name> <ssh target>
#   media  alice@media.lan
#
# Each host asks for its sudo password once.

set -euo pipefail
cd "$(dirname "$0")"

HOSTS_FILE="${HOSTS_FILE:-deploy.hosts}"

# files to install into /usr/local/bin on every host
FILES=(
  pbs-docker-backup.sh
)

[ -f "$HOSTS_FILE" ] || { echo "error: $HOSTS_FILE not found (copy deploy.hosts.example)" >&2; exit 1; }

for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "error: missing $f" >&2; exit 1; }
  bash -n "$f" || { echo "error: syntax error in $f, not deploying" >&2; exit 1; }
done

# warn about uncommitted changes when this is a git checkout
if git rev-parse --git-dir >/dev/null 2>&1 && [ -n "$(git status --porcelain -- "${FILES[@]}")" ]; then
  echo "warning: uncommitted changes in: $(git status --porcelain -- "${FILES[@]}" | awk '{print $2}' | xargs)"
  read -rp "deploy anyway? [y/N] " ans
  [[ "$ans" == [yY] ]] || exit 1
fi
rev="$(git rev-parse --short HEAD 2>/dev/null || echo unversioned)"

found=0
while read -r name target _; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [ "$#" -gt 0 ] && [[ " $* " != *" $name "* ]]; then continue; fi
  found=1

  echo "==> $name ($target) @ $rev"
  tmp="/tmp/deploy-$$"
  # ssh/scp must not read the hosts file being looped over
  ssh "$target" "mkdir -p $tmp" </dev/null
  scp -q "${FILES[@]}" "$target:$tmp/" </dev/null
  ssh -t "$target" "sudo install -o root -g root -m 755 $tmp/* /usr/local/bin/ && rm -rf $tmp && ls -l /usr/local/bin/ | grep -E '$(IFS='|'; echo "${FILES[*]}")'" </dev/tty
done < "$HOSTS_FILE"

[ "$found" -eq 1 ] || { echo "error: no matching hosts in $HOSTS_FILE" >&2; exit 1; }
