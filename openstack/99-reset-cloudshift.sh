#!/usr/bin/env bash
# reset-cloudshift.sh — wipe OpenStack/Kolla and redeploy from scratch
# Run on cloud03-controller01 as the normal user. DESTRUCTIVE.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLOUDSHIFT="$(dirname "$HERE")"
INVENTORY="$CLOUDSHIFT/ansible/inventory.yml"

#echo "=== 1. Back up critical files ==="
#mkdir -p "$HOME/cloudshift-backup-$(date +%F)"
#cp -a /etc/kolla/passwords.yml "$HOME/cloudshift-backup-$(date +%F)/passwords.yml" 2>/dev/null || true
#cp -a "$HOME/multinode" "$HOME/cloudshift-backup-$(date +%F)/multinode" 2>/dev/null || true

echo "=== 2. Stop & remove all containers/volumes ==="
sudo docker ps -aq | xargs -r sudo docker rm -f
sudo docker volume prune -f

echo "=== 3. Kolla destroy ==="
if [ -f "$HOME/multinode" ]; then
  source "$HOME/kolla-venv/bin/activate" 2>/dev/null || true
  kolla-ansible destroy -i "$HOME/multinode" --yes-i-really-really-mean-it || true
fi

echo "=== 4. Remove Kolla config & state ==="
sudo rm -rf /etc/kolla
rm -f "$HOME/multinode"

echo "=== 5. Clean compute node identity & stale state ==="
for ip in 192.168.0.21 192.168.0.22 192.168.0.23; do
  ssh -o StrictHostKeyChecking=no ansible@$ip \
    'sudo rm -f /var/lib/nova/compute_id /etc/kolla/nova-compute/compute_id; echo cleaned' || true
done

echo "=== 6. (Optional) Wipe GlusterFS shared data ==="
read -r -p "Wipe GlusterFS VM disks/images/telemetry? [y/N] " wipe
if [ "$wipe" = "y" ] || [ "$wipe" = "Y" ]; then
  for ip in 192.168.0.11 192.168.0.12 192.168.0.13; do
    ssh -o StrictHostKeyChecking=no ansible@$ip \
      'sudo rm -rf /var/lib/nova-shared/instances/* /var/lib/glance-shared/* /var/lib/gnocchi-shared/* 2>/dev/null; echo wiped' || true
  done
fi

echo "=== 7. Reinstall Kolla ==="
cd "$CLOUDSHIFT/kolla"
RELEASE="${RELEASE:-2026.1}" ./install.sh

echo "=== 8. Deploy OpenStack ==="
# deploy.sh pauses and waits for 'DEPLOY'; auto-confirm:
printf 'DEPLOY\n' | ./deploy.sh

echo "=== 9. Cloud resources ==="
cd "$CLOUDSHIFT/openstack"
./01-cloud-setup.sh

echo "=== Done. ==="
echo "Backup saved in: $HOME/cloudshift-backup-$(date +%F)/"