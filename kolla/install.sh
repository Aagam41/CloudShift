#!/usr/bin/env bash
# Run on cloud03-contorller01 AFTER ansible/site.yml succeeded. Installs Kolla-Ansible and our config.
set -euo pipefail
RELEASE="${RELEASE:-2026.1}"                    # stable/<release> branch
HERE="$(cd "$(dirname "$0")" && pwd)"
VENV="$HOME/kolla-venv"
SHARE="$VENV/share/kolla-ansible"

sudo apt-get update
sudo apt-get install -y git python3-venv python3-dev gcc libffi-dev libssl-dev libdbus-glib-1-dev

python3 -m venv "$VENV"
source "$VENV/bin/activate"
pip install -U pip
pip install "git+https://opendev.org/openstack/kolla-ansible@stable/${RELEASE}" \
            docker python-openstackclient python-gnocchiclient python-cloudkittyclient openstacksdk

sudo mkdir -p /etc/kolla && sudo chown "$USER": /etc/kolla
cp -rn "$SHARE"/etc_examples/kolla/* /etc/kolla/
kolla-ansible install-deps

# passwords.yml is copied from the examples with EMPTY values, so always (re)generate: it only fills blanks.
kolla-genpwd

# our configuration
sed "s/^openstack_release:.*/openstack_release: \"$RELEASE\"/" "$HERE/globals.yml" > /etc/kolla/globals.yml
mkdir -p /etc/kolla/config
cp -r "$HERE"/config/* /etc/kolla/config/

# inventory = our hosts + Kolla's stock groups (Glance, Gnocchi, Ceilometer, CloudKitty, Valkey run on all 3 controllers)
INV="$HOME/multinode"
awk '/^\[baremetal:children\]/{p=1} p' "$SHARE/ansible/inventory/multinode" | cat "$HERE/multinode-head.ini" - > "$INV"
sed -i "s/^ansible_user=.*/ansible_user=$(id -un)/" "$INV"

# SSH by name (Kolla uses host names)
HOSTS=$(awk '/^\[(control|compute)\]/{f=1;next} /^\[/{f=0} f&&NF&&!/^#/{print $1}' "$HERE/multinode-head.ini" | sort -u)
for h in $HOSTS; do ssh-keyscan -H "$h" >> ~/.ssh/known_hosts 2>/dev/null; done
sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts

echo; echo "Inventory check (each line must show the 3 controllers):"
for g in glance-api gnocchi ceilometer cloudkitty valkey prometheus grafana prometheus-alertmanager; do
  printf '%-12s ' "$g"; ansible-inventory -i "$INV" --graph "$g" | grep -E '\-\-cloud03' | tr -d ' |-' | tr '\n' ' '; echo
done
echo; ansible -i "$INV" all -m ping
echo "OK. Review /etc/kolla/globals.yml, then run ./deploy.sh"
