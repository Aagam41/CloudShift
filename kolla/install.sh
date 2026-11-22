#!/usr/bin/env bash
# Run on cloud03-controller01 AFTER ansible/site.yml succeeded.
# Installs Kolla-Ansible, writes /etc/kolla, and builds ~/multinode.
set -euo pipefail

RELEASE="${RELEASE:-2026.1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VENV="$HOME/kolla-venv"
SHARE="$VENV/share/kolla-ansible"
INVENTORY_YAML="$HERE/../ansible/inventory.yml"
MULTINODE_HEAD="$HERE/multinode-head.ini"

echo '==> Installing build dependencies'
sudo apt-get update
sudo apt-get install -y \
  git python3-venv python3-dev python3-yaml \
  gcc libffi-dev libssl-dev libdbus-glib-1-dev

echo '==> Checking kolla/multinode-head.ini against ansible/inventory.yml'
python3 - "$INVENTORY_YAML" "$MULTINODE_HEAD" <<'PY'
from pathlib import Path
import re
import sys
import yaml

inventory_path = Path(sys.argv[1])
head_path = Path(sys.argv[2])

inventory = yaml.safe_load(inventory_path.read_text())
children = inventory['all']['children']
control = set(children['control']['hosts'])
compute = set(children['compute']['hosts'])

head = head_path.read_text()

def ini_group(name: str) -> set[str]:
    match = re.search(
        rf'^\[{re.escape(name)}\]\s*$(.*?)(?=^\[|\Z)',
        head,
        flags=re.MULTILINE | re.DOTALL,
    )
    if match is None:
        return set()
    return {
        line.split()[0]
        for line in match.group(1).splitlines()
        if line.strip() and not line.lstrip().startswith('#')
    }

expected_groups = {
    'control': control,
    'network': control,
    'monitoring': control,
    'storage': control,
    'compute': compute,
}

for group, expected in expected_groups.items():
    actual = ini_group(group)
    if actual != expected:
        raise SystemExit(
            f'{head_path}: [{group}] does not match {inventory_path}\n'
            f'  expected: {", ".join(sorted(expected))}\n'
            f'  found:    {", ".join(sorted(actual))}'
        )
PY

echo '==> Creating the Kolla-Ansible virtual environment'
python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
pip install --upgrade pip
pip install \
  "git+https://opendev.org/openstack/kolla-ansible@stable/${RELEASE}" \
  docker \
  python-openstackclient \
  gnocchiclient \
  python-cloudkittyclient \
  openstacksdk

echo '==> Installing Kolla-Ansible dependencies and example configuration'
sudo mkdir -p /etc/kolla
sudo chown "$USER": /etc/kolla
cp -a --update=none "$SHARE"/etc_examples/kolla/. /etc/kolla/
kolla-ansible install-deps

# passwords.yml is copied from the examples with EMPTY values, so always (re)generate:
# kolla-genpwd only fills blanks and never overwrites existing passwords.
kolla-genpwd

echo '==> Writing our Kolla configuration'
sed "s/^openstack_release:.*/openstack_release: \"$RELEASE\"/" \
  "$HERE/globals.yml" > /etc/kolla/globals.yml

# Replace the whole config directory so removed files (for example old
# per-host Prometheus overrides) do not survive a rerun.
rm -rf /etc/kolla/config
mkdir -p /etc/kolla/config
cp -a "$HERE"/config/. /etc/kolla/config/

echo '==> Building ~/multinode from our hosts and Kolla’s stock groups'
INV="$HOME/multinode"
awk '/^\[baremetal:children\]/{p=1} p' \
  "$SHARE/ansible/inventory/multinode" \
  | cat "$MULTINODE_HEAD" - > "$INV"
sed -i "s/^ansible_user=.*/ansible_user=ansible/" "$INV"

echo '==> Adding every Kolla host to known_hosts'
HOSTS=$(
  awk '/^\[(control|compute)\]/{f=1;next} /^\[/{f=0} f&&NF&&!/^#/{print $1}' \
    "$MULTINODE_HEAD" | sort -u
)
for host in $HOSTS; do
  ssh-keyscan -H "$host" >> ~/.ssh/known_hosts 2>/dev/null || true
done
sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts

echo '==> Checking the service inventory'
EXPECTED_CONTROLLERS=$(awk '/^\[control\]/{f=1;next} /^\[/{f=0} f&&NF&&!/^#/{print $1}' "$MULTINODE_HEAD" | wc -w)
for group in glance-api gnocchi ceilometer cloudkitty valkey prometheus grafana prometheus-alertmanager; do
  hosts=$(
    ansible-inventory -i "$INV" --graph "$group" \
      | grep -E -- '--cloud03' \
      | tr -d ' |-' \
      | tr '\n' ' '
  )
  printf '%-24s %s\n' "$group" "$hosts"
  count=$(printf '%s\n' "$hosts" | wc -w)
  if [ "$count" -ne "$EXPECTED_CONTROLLERS" ]; then
    echo "ERROR: $group contains $count controllers; expected $EXPECTED_CONTROLLERS." >&2
    exit 1
  fi
done

echo
ansible -i "$INV" all -m ping
echo 'OK. Review /etc/kolla/globals.yml, then run ./deploy.sh'
