#!/usr/bin/env bash
# Staged Kolla-Ansible deployment. Stops after prechecks so you can read them.
set -euo pipefail

source ~/kolla-venv/bin/activate
INV="$HOME/multinode"

if [ ! -f "$INV" ]; then
  echo "ERROR: $INV is missing. Run kolla/install.sh first." >&2
  exit 1
fi
if [ ! -f /etc/kolla/globals.yml ]; then
  echo 'ERROR: /etc/kolla/globals.yml is missing. Run kolla/install.sh first.' >&2
  exit 1
fi

kolla-ansible bootstrap-servers -i "$INV"
kolla-ansible prechecks -i "$INV" --use-test-images

echo
echo 'Verifying shared storage mounts on compute nodes...'
if ! ansible -i "$INV" compute -b -m shell -a 'findmnt -n /var/lib/nova-shared | grep -q glusterfs' >/tmp/cloudshift-mount-check.$$ 2>&1; then
  echo 'ERROR: /var/lib/nova-shared is not a GlusterFS mount on at least one compute node.' >&2
  echo 'Run: cd ../ansible && ansible-playbook 03-storage.yml -K && ansible-playbook 04-verify.yml -K' >&2
  cat /tmp/cloudshift-mount-check.$$ >&2
  rm -f /tmp/cloudshift-mount-check.$$
  exit 1
fi
rm -f /tmp/cloudshift-mount-check.$$
echo 'Shared storage mounts OK.'

echo
echo 'Prechecks passed. Deploy pulls several GB per node through the Wi-Fi gateway: it takes a while.'
read -r -p 'Type DEPLOY to continue: ' answer
if [ "$answer" != 'DEPLOY' ]; then
  echo 'Stopped before deploy.'
  exit 0
fi

kolla-ansible deploy -i "$INV"
kolla-ansible post-deploy -i "$INV"

mkdir -p ~/.config/openstack
cp /etc/kolla/clouds.yaml ~/.config/openstack/
echo 'Done. Next: ../openstack/01-cloud-setup.sh'
