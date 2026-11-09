#!/usr/bin/env bash
# End-to-end live migration test: boot a VM pinned to one compute host, move it, move it back.
# Run on cloud03-contorller01 after openstack/01-cloud-setup.sh.
set -euo pipefail
source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
A="${1:-cloud03-compute01}"; B="${2:-cloud03-compute02}"

python3 "$HERE/migrate.py" --list
openstack server create --image cirros --flavor m1.small --network private-net \
  --availability-zone "nova:$A" --wait lm-test >/dev/null
echo "booted lm-test on: $(openstack server show lm-test -f value -c OS-EXT-SRV-ATTR:host)"
python3 "$HERE/migrate.py" lm-test --to "$B"
python3 "$HERE/migrate.py" lm-test --to "$A"
echo "live migration works: $A -> $B -> $A. Clean up with: openstack server delete lm-test"
