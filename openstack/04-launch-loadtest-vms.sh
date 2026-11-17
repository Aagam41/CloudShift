#!/usr/bin/env bash
set -euo pipefail

source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh

IMAGE_NAME="${IMAGE_NAME:-loadtest}"
KEY_NAME="${KEY_NAME:-loadtest}"
FLAVOR="${FLAVOR:-m1.small}"
NETWORK="${NETWORK:-private-net}"
SECURITY_GROUP="${SECURITY_GROUP:-loadtest}"
COMPUTE_HOSTS="${COMPUTE_HOSTS:-cloud03-compute01 cloud03-compute02 cloud03-compute03}"
VM_PREFIX="${VM_PREFIX:-loadtest}"
ASSIGN_FLOATING_IPS="${ASSIGN_FLOATING_IPS:-yes}"
INSTANCES_PER_NODE="${INSTANCES_PER_NODE:-}"

if ! openstack image show "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "Image '$IMAGE_NAME' not found. Run openstack/03-build-loadtest-image.sh first." >&2
  exit 1
fi

if ! openstack flavor show "$FLAVOR" >/dev/null 2>&1; then
  echo "Flavor '$FLAVOR' not found." >&2
  exit 1
fi

if ! openstack network show "$NETWORK" >/dev/null 2>&1; then
  echo "Network '$NETWORK' not found." >&2
  exit 1
fi

if ! openstack security group show "$SECURITY_GROUP" >/dev/null 2>&1; then
  openstack security group create "$SECURITY_GROUP"
fi

for proto in icmp tcp; do
  if ! openstack security group rule list "$SECURITY_GROUP" -f value -c "IP Protocol" | grep -qx "$proto"; then
    if [ "$proto" = tcp ]; then
      openstack security group rule create --proto tcp --dst-port 22 "$SECURITY_GROUP" || true
      openstack security group rule create --proto tcp --dst-port 80 "$SECURITY_GROUP" || true
    else
      openstack security group rule create --proto icmp "$SECURITY_GROUP" || true
    fi
  fi
done

flavor_vcpus="$(openstack flavor show "$FLAVOR" -f value -c vcpus)"
flavor_ram_mb="$(openstack flavor show "$FLAVOR" -f value -c ram)"

TOKEN=$(openstack token issue -f value -c id)
NOVA_URL=$(openstack endpoint list --service compute -f value -c URL | grep 10.0.10.100 | head -n 1)
NOVA_URL="${NOVA_URL%/}"
HYPERVISOR_JSON="$(mktemp)"
trap 'rm -f "$HYPERVISOR_JSON"' EXIT

curl -fsS -H "X-Auth-Token: $TOKEN" "$NOVA_URL/v2.1/os-hypervisors/detail" -o "$HYPERVISOR_JSON"

capacity_for_host() {
  python3 - "$1" "$HYPERVISOR_JSON" <<'PY'
import json
import sys

host = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as f:
    data = json.load(f)

for hypervisor in data.get("hypervisors", []):
    if (hypervisor.get("hypervisor_hostname") == host
            and hypervisor.get("state") == "up"
            and hypervisor.get("status") == "enabled"):
        print(
            hypervisor["vcpus"] - hypervisor["vcpus_used"],
            hypervisor["memory_mb"] - hypervisor["memory_mb_used"],
        )
        raise SystemExit(0)

raise SystemExit(1)
PY
}

echo "Compute capacity and suggested instances per node:"
echo

suggested_global=999999
declare -A suggested_by_host
launch_hosts=()

for host in $COMPUTE_HOSTS; do
  if capacity="$(capacity_for_host "$host" 2>/dev/null)"; then
    read -r free_vcpus free_ram_mb <<<"$capacity"
  else
    echo "  $host: not registered or not up; skipping"
    suggested_by_host["$host"]=0
    continue
  fi

  usable_ram_mb=$(( free_ram_mb * 9 / 10 ))
  cpu_suggested="$free_vcpus"
  ram_suggested=$(( usable_ram_mb / flavor_ram_mb ))
  suggested=$(( cpu_suggested < ram_suggested ? cpu_suggested : ram_suggested ))
  if [ "$suggested" -lt 0 ]; then
    suggested=0
  fi

  if [ "$suggested" -eq 0 ]; then
    echo "  $host: $free_vcpus free vCPUs, $((free_ram_mb / 1024)) MiB free RAM -> no free capacity; skipping"
    suggested_by_host["$host"]=0
    continue
  fi

  suggested_by_host["$host"]="$suggested"
  launch_hosts+=("$host")
  if [ "$suggested" -lt "$suggested_global" ]; then
    suggested_global="$suggested"
  fi

  echo "  $host: $free_vcpus free vCPUs, $((free_ram_mb / 1024)) MiB free RAM -> suggested $suggested instances"
done

echo
if [ "${#launch_hosts[@]}" -eq 0 ]; then
  echo "No compute hosts have free capacity."
  exit 0
fi

declare -A instances_by_host
total_requested=0

for host in "${launch_hosts[@]}"; do
  suggested="${suggested_by_host[$host]:-0}"
  if [ "$suggested" -lt 0 ]; then
    suggested=0
  fi

  if [ -n "${INSTANCES_PER_NODE:-}" ]; then
    count="$INSTANCES_PER_NODE"
  else
    read -r -p "How many instances on $host? [$suggested]: " count
    count="${count:-$suggested}"
  fi

  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    echo "Instance count for $host must be a non-negative integer." >&2
    exit 1
  fi

  instances_by_host["$host"]="$count"
  total_requested=$((total_requested + count))

  if [ "$count" -gt "$suggested" ]; then
    echo "Warning: $host only has capacity for about $suggested instances; launching $count anyway."
  fi
done

if [ "$total_requested" -eq 0 ]; then
  echo "No instances requested."
  exit 0
fi

if ! openstack keypair show "$KEY_NAME" >/dev/null 2>&1; then
  echo "Keypair '$KEY_NAME' not found. Run openstack/00-create-loadtest-keypair.sh first." >&2
  exit 1
fi

wait_for_http() {
  local url="$1"
  local attempts="${2:-30}"
  local delay="${3:-5}"

  for ((i=1; i<=attempts; i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

for host in "${launch_hosts[@]}"; do
  instances_per_node="${instances_by_host[$host]:-0}"
  host_suggested="${suggested_by_host[$host]:-0}"

  if [ "$instances_per_node" -eq 0 ]; then
    echo "Skipping $host: 0 instances requested."
    continue
  fi

  if [ "$host_suggested" -gt 0 ] && [ "$instances_per_node" -gt "$host_suggested" ]; then
    echo "Warning: $host only has capacity for about $host_suggested instances; launching $instances_per_node anyway."
  fi

  for ((i=1; i<=instances_per_node; i++)); do
    name="${VM_PREFIX}-${host#cloud03-}-${i}"

    if openstack server show "$name" >/dev/null 2>&1; then
      echo "Server '$name' already exists; skipping."
      continue
    fi

    echo "Launching $name on $host"
    openstack server create "$name" \
      --image "$IMAGE_NAME" \
      --flavor "$FLAVOR" \
      --network "$NETWORK" \
      --security-group "$SECURITY_GROUP" \
      --key-name "$KEY_NAME" \
      --availability-zone "nova:$host" \
      --wait

    if [ "$ASSIGN_FLOATING_IPS" = "yes" ]; then
      fip="$(openstack floating ip create provider-net -f value -c floating_ip_address)"
      openstack server add floating ip "$name" "$fip"
      echo "  $name: http://$fip/"
      if wait_for_http "http://$fip/" 30 5; then
        echo "  web service ready"
      else
        echo "  warning: web service did not respond within timeout"
      fi
    else
      echo "  $name launched without a floating IP"
    fi
  done
done

echo
echo "Launched VMs:"
for host in "${launch_hosts[@]}"; do
  instances_per_node="${instances_by_host[$host]:-0}"
  [ "$instances_per_node" -eq 0 ] && continue
  for ((i=1; i<=instances_per_node; i++)); do
    name="${VM_PREFIX}-${host#cloud03-}-${i}"
    if openstack server show "$name" >/dev/null 2>&1; then
      fip="$(openstack server show "$name" -f value -c addresses | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -n1 || true)"
      echo "  $name on $host: http://${fip:-<no floating IP>}/"
    fi
  done
done
EOF