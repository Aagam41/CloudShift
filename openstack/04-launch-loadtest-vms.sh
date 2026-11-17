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

echo "Compute capacity and suggested instances per node:"
echo

suggested_global=999999
declare -A suggested_by_host

for host in $COMPUTE_HOSTS; do
  stats="$(openstack hypervisor show "$host" -f json)"
  free_vcpus="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(max(0, d["vcpus"] - d["vcpus_used"]))' <<<"$stats")"
  free_ram_mb="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(max(0, d["memory_mb"] - d["memory_mb_used"]))' <<<"$stats")"

  usable_ram_mb=$(( free_ram_mb * 9 / 10 ))
  cpu_suggested="$free_vcpus"
  ram_suggested=$(( usable_ram_mb / flavor_ram_mb ))
  suggested=$(( cpu_suggested < ram_suggested ? cpu_suggested : ram_suggested ))
  if [ "$suggested" -lt 0 ]; then
    suggested=0
  fi

  suggested_by_host["$host"]="$suggested"
  if [ "$suggested" -lt "$suggested_global" ]; then
    suggested_global="$suggested"
  fi

  echo "  $host: $free_vcpus free vCPUs, $((free_ram_mb / 1024)) MiB free RAM -> suggested $suggested instances"
done

echo
if [ "$suggested_global" -eq 999999 ] || [ "$suggested_global" -lt 1 ]; then
  suggested_global=1
fi

if [ -n "$INSTANCES_PER_NODE" ]; then
  instances_per_node="$INSTANCES_PER_NODE"
else
  read -r -p "How many instances per compute node? [$suggested_global]: " instances_per_node
  instances_per_node="${instances_per_node:-$suggested_global}"
fi

if ! [[ "$instances_per_node" =~ ^[0-9]+$ ]]; then
  echo "Instance count must be a non-negative integer." >&2
  exit 1
fi

if [ "$instances_per_node" -eq 0 ]; then
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

for host in $COMPUTE_HOSTS; do
  host_suggested="${suggested_by_host[$host]:-0}"
  if [ "$host_suggested" -lt "$instances_per_node" ]; then
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
for host in $COMPUTE_HOSTS; do
  for ((i=1; i<=instances_per_node; i++)); do
    name="${VM_PREFIX}-${host#cloud03-}-${i}"
    if openstack server show "$name" >/dev/null 2>&1; then
      fip="$(openstack server show "$name" -f value -c addresses | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -n1 || true)"
      echo "  $name on $host: http://${fip:-<no floating IP>}/"
    fi
  done
done
EOF