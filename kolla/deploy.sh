#!/usr/bin/env bash
# Staged Kolla-Ansible deployment. Stops after prechecks so you can read them.
set -euo pipefail
source ~/kolla-venv/bin/activate
INV="$HOME/multinode"

kolla-ansible bootstrap-servers -i "$INV"
kolla-ansible prechecks         -i "$INV"

echo; echo "Prechecks passed. Deploy pulls several GB per node through the Wi-Fi gateway: it takes a while."
read -r -p "Type DEPLOY to continue: " answer
[[ "$answer" == "DEPLOY" ]] || { echo "Stopped before deploy."; exit 0; }

kolla-ansible deploy      -i "$INV"
kolla-ansible post-deploy -i "$INV"        # (the kit's script forgot -i here)
mkdir -p ~/.config/openstack && cp /etc/kolla/clouds.yaml ~/.config/openstack/
echo "Done. Next: ../openstack/01-cloud-setup.sh"
