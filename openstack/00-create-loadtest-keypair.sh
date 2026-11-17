#!/usr/bin/env bash
# Generate or reuse an SSH key, then upload its public key to OpenStack.
set -euo pipefail

source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh

KEY_NAME="${KEY_NAME:-loadtest}"
KEY_FILE="${KEY_FILE:-$HOME/.ssh/${KEY_NAME}}"
PUB_FILE="${KEY_FILE}.pub"

mkdir -p "$(dirname "$KEY_FILE")"

if [ ! -f "$KEY_FILE" ] || [ ! -f "$PUB_FILE" ]; then
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "$KEY_NAME"
fi

chmod 600 "$KEY_FILE"
chmod 644 "$PUB_FILE"

# Recreate the OpenStack keypair so it always matches the local public key.
if openstack keypair show "$KEY_NAME" >/dev/null 2>&1; then
  openstack keypair delete "$KEY_NAME"
fi

openstack keypair create --public-key "$PUB_FILE" "$KEY_NAME"

echo "Local private key: $KEY_FILE"
echo "Local public key:  $PUB_FILE"
echo "OpenStack keypair: $KEY_NAME"
