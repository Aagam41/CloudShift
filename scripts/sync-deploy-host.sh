#!/usr/bin/env bash
# Run on the controller you deploy from. Copies everything needed to run Kolla-Ansible to the other controllers,
# so any of them can take over the deployer role. Safe to cron:  0 * * * *  <path>/sync-deploy-host.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ME="$(hostname)"
for h in cloud03-contorller01 cloud03-contorller02 cloud03-contorlcompute; do
  [ "$h" = "$ME" ] && continue
  echo "== $h"
  sudo rsync -a --rsync-path="sudo rsync" /etc/kolla/ "$USER@$h:/etc/kolla/"       # incl. passwords.yml, globals.yml, config/
  rsync -a "$HOME/multinode" "$USER@$h:$HOME/multinode"
  rsync -a --delete "$REPO/" "$USER@$h:$REPO/"
done
echo "Synced. On another controller: scripts/00-controller01-bootstrap.sh once, then kolla/install.sh"
