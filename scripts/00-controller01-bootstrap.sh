#!/usr/bin/env bash

# Run FIRST, on cloud03-controller01, as your normal user (not root).
# Installs Ansible, configures SSH and creates ansible user on all nodes.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

sudo apt-get update
sudo apt-get install -y ansible-core openssh-client

# Generate SSH key if missing
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519

# Move to Ansible directory
cd "$HERE/../ansible"

INVENTORY="inventory.yml"
PLAYBOOK="00-create-ansible-user.yml"

echo "======================================"
echo " Copying SSH keys to all nodes"
echo "======================================"

# Addresses and users come from inventory.yml
ansible-inventory -i "$INVENTORY" --list | python3 -c '
import json, sys
inv = json.load(sys.stdin)["_meta"]["hostvars"]
for h, v in inv.items():
    print("ubuntu@" + v["ansible_host"])
' | sort -u | while read -r target; do

    echo "== $target"
    ssh-copy-id -o StrictHostKeyChecking=accept-new "$target"
done

echo ""
echo "======================================"
echo " Creating ansible user on all nodes"
echo "======================================"

# Run user creation playbook with sudo password prompt
ansible-playbook -i "$INVENTORY" -e "ansible_user=ubuntu" --private-key ~/.ssh/id_ed25519 "$PLAYBOOK" -K

echo ""
echo "======================================"
echo " Testing ansible user connectivity"
echo "======================================"

ansible all -i "$INVENTORY" --private-key ~/.ssh/id_ed25519 -m ping

echo ""
echo "======================================"
echo " Testing passwordless sudo"
echo "======================================"

ansible all -i "$INVENTORY" --private-key ~/.ssh/id_ed25519 -m command -a "whoami" -b

echo ""
echo "======================================"
echo " SUCCESS: All nodes configured"
echo "======================================"
