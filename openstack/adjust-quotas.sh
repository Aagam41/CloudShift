#!/usr/bin/env bash
# Adjust OpenStack quotas so the cloud can use 2x its physical CPU/RAM capacity.
#
# Usage: ./adjust-quotas.sh [multiplier]
#   MULTIPLIER env var or first arg overrides the default multiplier of 2.
set -uo pipefail

source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh

MULTIPLIER="${1:-${MULTIPLIER:-2}}"

stats_json="$(openstack hypervisor stats show -f json 2>/dev/null || true)"
read -r total_vcpus total_ram_mb <<< "$(python3 - "$stats_json" <<'PY'
import json, sys
raw = sys.argv[1].strip() if len(sys.argv) > 1 else ""
try:
    data = json.loads(raw)
except Exception:
    data = {}
if isinstance(data, list):
    data = data[0] if data else {}
vcpus = data.get("vcpus") or data.get("vcpus_used") or 0
ram = data.get("memory_mb") or data.get("memory_mb_used") or 0
# Fall back to querying each hypervisor if stats were empty.
if not vcpus or not ram:
    import subprocess
    try:
        out = subprocess.check_output(
            ["openstack", "hypervisor", "list", "-f", "value", "-c", "Hypervisor Hostname"],
            text=True,
        )
        hosts = [line.strip() for line in out.splitlines() if line.strip()]
        for host in hosts:
            try:
                show = subprocess.check_output(
                    ["openstack", "hypervisor", "show", host, "-f", "json"], text=True
                )
                info = json.loads(show)
                vcpus += info.get("vcpus", 0) or 0
                ram += info.get("memory_mb", 0) or 0
            except Exception:
                pass
    except Exception:
        pass
print(int(vcpus or 0), int(ram or 0))
PY
)"

if [ -z "${total_vcpus:-}" ] || [ "$total_vcpus" -eq 0 ]; then
  echo "Could not determine cluster capacity; using conservative defaults." >&2
  total_vcpus=64
  total_ram_mb=131072
fi

target_vcpus=$((total_vcpus * MULTIPLIER))
target_ram=$((total_ram_mb * MULTIPLIER))
target_instances=$((target_vcpus))
target_fips=200
target_networks=200
target_subnets=200
target_routers=50
target_ports=2000
target_secgroups=100
target_secgroup_rules=2000

echo "Cluster capacity: ${total_vcpus} vCPUs, $((total_ram_mb / 1024)) GiB RAM"
echo "Setting quotas to ${MULTIPLIER}x: ${target_vcpus} vCPUs, $((target_ram / 1024)) GiB RAM"
echo

# Default quota class (best effort).
openstack quota set --class default \
  --instances "$target_instances" \
  --cores "$target_vcpus" \
  --ram "$target_ram" \
  --floating-ips "$target_fips" \
  --networks "$target_networks" \
  --subnets "$target_subnets" \
  --routers "$target_routers" \
  --ports "$target_ports" \
  --secgroups "$target_secgroups" \
  --secgroup-rules "$target_secgroup_rules" \
  2>/dev/null || true

# All existing projects.
while IFS= read -r project_id; do
  [ -n "$project_id" ] || continue
  if openstack quota set \
    --instances "$target_instances" \
    --cores "$target_vcpus" \
    --ram "$target_ram" \
    --floating-ips "$target_fips" \
    --networks "$target_networks" \
    --subnets "$target_subnets" \
    --routers "$target_routers" \
    --ports "$target_ports" \
    --secgroups "$target_secgroups" \
    --secgroup-rules "$target_secgroup_rules" \
    "$project_id" 2>/dev/null; then
    echo "Updated quotas for project $project_id"
  else
    echo "Warning: could not update quotas for project $project_id" >&2
  fi
done < <(openstack project list -f value -c ID)

echo
echo "Quota adjustment complete."