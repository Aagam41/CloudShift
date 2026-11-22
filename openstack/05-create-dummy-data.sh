#!/usr/bin/env bash
# Create a realistic multi-tenant OpenStack layout for scheduler/load/migration testing.
#
# Environment variables:
#   CLIENTS=3
#   PROJECTS_MIN=1 PROJECTS_MAX=3
#   NETWORKS_MIN=1 NETWORKS_MAX=3
#   VMS_MIN=1 VMS_MAX=5
#   COMPUTE_HOSTS="cloud03-compute01 cloud03-compute02 cloud03-compute03"
#   IMAGE_NAME=loadtest
#   FLAVOR_POOL="m1.small m1.medium m1.large"
#   CONFIRM=yes
set -euo pipefail

source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh

CLIENTS="${CLIENTS:-3}"
PROJECTS_MIN="${PROJECTS_MIN:-1}"
PROJECTS_MAX="${PROJECTS_MAX:-3}"
NETWORKS_MIN="${NETWORKS_MIN:-1}"
NETWORKS_MAX="${NETWORKS_MAX:-3}"
VMS_MIN="${VMS_MIN:-1}"
VMS_MAX="${VMS_MAX:-5}"
COMPUTE_HOSTS="${COMPUTE_HOSTS:-cloud03-compute01 cloud03-compute02 cloud03-compute03}"
IMAGE_NAME="${IMAGE_NAME:-loadtest}"
FLAVOR_POOL="${FLAVOR_POOL:-m1.small m1.medium m1.large}"
KEY_NAME="${KEY_NAME:-loadtest}"
MANIFEST="${MANIFEST:-$HOME/.config/cloudshift-dummy-data.manifest}"
CREDENTIALS="${CREDENTIALS:-$HOME/.config/cloudshift-dummy-clients.txt}"
RUN_ID="dummy-$(date +%Y%m%d%H%M%S)"

umask 077
mkdir -p "$(dirname "$MANIFEST")" "$(dirname "$CREDENTIALS")"
touch "$MANIFEST" "$CREDENTIALS"
chmod 600 "$MANIFEST" "$CREDENTIALS"

if ! openstack image show "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "Image '$IMAGE_NAME' not found. Build and upload it first." >&2
  exit 1
fi

for flavor in $FLAVOR_POOL; do
  if ! openstack flavor show "$flavor" >/dev/null 2>&1; then
    echo "Flavor '$flavor' not found." >&2
    exit 1
  fi
done

hypervisors=$(openstack hypervisor list -f value -c "Hypervisor Hostname")
available_compute_hosts=()
for configured_host in $COMPUTE_HOSTS; do
  if printf '%s\n' "$hypervisors" | grep -qx "$configured_host"; then
    available_compute_hosts+=("$configured_host")
  fi
done

if [ "${#available_compute_hosts[@]}" -eq 0 ]; then
  echo "No configured compute hosts are registered in Nova." >&2
  exit 1
fi

declare -A FLAVOR_VCPUS=(
  [m1.small]=1
  [m1.medium]=2
  [m1.large]=4
)
declare -A FLAVOR_RAM=(
  [m1.small]=1024
  [m1.medium]=2048
  [m1.large]=4096
)

read -r -a FLAVOR_ARRAY <<<"$FLAVOR_POOL"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

random_between() {
  local min=$1 max=$2
  echo $(( RANDOM % (max - min + 1) + min ))
}

: > "$tmpdir/clients.tsv"
: > "$tmpdir/projects.tsv"
: > "$tmpdir/networks.tsv"
: > "$tmpdir/vms_raw.tsv"

subnet_index=100
for ((client_number=1; client_number<=CLIENTS; client_number++)); do
  client="client${client_number}"
  echo "$client" >> "$tmpdir/clients.tsv"

  project_count=$(random_between "$PROJECTS_MIN" "$PROJECTS_MAX")
  for ((project_number=1; project_number<=project_count; project_number++)); do
    project="${client}-project${project_number}"
    echo "$client $project" >> "$tmpdir/projects.tsv"

    network_count=$(random_between "$NETWORKS_MIN" "$NETWORKS_MAX")
    vm_count=$(random_between "$VMS_MIN" "$VMS_MAX")

    if (( network_count == 1 )); then
      roles=(app)
    elif (( network_count == 2 )); then
      roles=(frontend backend)
    else
      roles=(frontend backend database)
    fi

    for ((network_number=1; network_number<=network_count; network_number++)); do
      role="${roles[$((network_number - 1))]:-app${network_number}}"
      network="${project}-net${network_number}"
      subnet="${project}-subnet${network_number}"
      subnet_index=$((subnet_index + 1))
      if (( subnet_index > 254 )); then
        echo "Too many networks for the 10.100.0.0/16 plan." >&2
        exit 1
      fi
      cidr="10.100.${subnet_index}.0/24"
      printf '%s\t%s\t%s\t%s\t%d\t%s\t%s\n' \
        "$client" "$project" "$network" "$subnet" "$subnet_index" "$role" "$cidr" \
        >> "$tmpdir/networks.tsv"
    done

    vm_networks=()
    if (( vm_count >= network_count )); then
      for ((network_number=1; network_number<=network_count; network_number++)); do
        vm_networks+=("$network_number")
      done
      for ((vm_number=network_count + 1; vm_number<=vm_count; vm_number++)); do
        vm_networks+=("$((RANDOM % network_count + 1))")
      done
    else
      for ((vm_number=1; vm_number<=vm_count; vm_number++)); do
        vm_networks+=("$((RANDOM % network_count + 1))")
      done
    fi

    for ((vm_number=1; vm_number<=vm_count; vm_number++)); do
      network_number="${vm_networks[$((vm_number - 1))]}"
      network="${project}-net${network_number}"
      role="${roles[$((network_number - 1))]:-app${network_number}}"
      flavor="${FLAVOR_ARRAY[$((RANDOM % ${#FLAVOR_ARRAY[@]}))]}"
      public=0
      rand=$((RANDOM % 100))
      case "$role" in
        frontend)
          if (( rand < 70 )); then public=1; fi
          ;;
        backend)
          if (( rand < 20 )); then public=1; fi
          ;;
        database)
          public=0
          ;;
        *)
          if (( rand < 40 )); then public=1; fi
          ;;
      esac
      host="${available_compute_hosts[$((RANDOM % ${#available_compute_hosts[@]}))]}"
      vcpus="${FLAVOR_VCPUS[$flavor]}"
      ram="${FLAVOR_RAM[$flavor]}"
      printf '%s\t%s\t%d\t%d\t%s\t%d\t%d\t%d\t%s\t%s\n' \
        "$client" "$project" "$network_number" "$vm_number" "$flavor" "$public" \
        "$vcpus" "$ram" "$host" "$role" >> "$tmpdir/vms_raw.tsv"
    done
  done
done

used_fips=$(openstack floating ip list -f value -c "Floating IP Address" | wc -l)
available_fips=$((100 - used_fips))
if (( available_fips < 0 )); then
  available_fips=0
fi

awk -v avail="$available_fips" '
  BEGIN { public=0 }
  {
    if ($6 == 1 && public >= avail) {
      $6 = 0
    }
    if ($6 == 1) {
      public++
    }
    print
  }
' "$tmpdir/vms_raw.tsv" > "$tmpdir/vms.tsv"

awk '
  NR == FNR {
    nets[$1 SUBSEP $2]++
    next
  }
  {
    key = $1 SUBSEP $2
    vms[key]++
    cores[key] += $7
    ram[key] += $8
    fips[key] += $6
  }
  END {
    for (key in vms) {
      split(key, parts, SUBSEP)
      print parts[1], parts[2], vms[key], cores[key], ram[key], fips[key], nets[key]
    }
  }
' "$tmpdir/networks.tsv" "$tmpdir/vms.tsv" > "$tmpdir/project_totals.tsv"

total_clients=$(wc -l < "$tmpdir/clients.tsv")
total_projects=$(wc -l < "$tmpdir/projects.tsv")
total_networks=$(wc -l < "$tmpdir/networks.tsv")
total_vms=$(wc -l < "$tmpdir/vms.tsv")
total_fips=$(awk '$6 == 1 { count++ } END { print count + 0 }' "$tmpdir/vms.tsv")

echo "Planned resources:"
echo "  clients:        $total_clients"
echo "  projects:       $total_projects"
echo "  networks:       $total_networks"
echo "  virtual machines: $total_vms"
echo "  floating IPs:   $total_fips"
echo
echo "Planned quota targets:"
while read -r client project vms cores ram fips networks; do
  target_instances=$((vms + 2))
  target_cores=$((cores + 2))
  target_ram=$((ram + 1024))
  target_fips=$((fips + 2))
  target_networks=$((networks + 2))
  target_subnets=$((networks + 2))
  target_routers=2
  target_ports=$((vms + networks + target_routers + 5))
  target_secgroups=6
  target_secgroup_rules=40
  echo "  $project:"
  echo "    instances=$target_instances cores=$target_cores ram=${target_ram}MB floating_ips=$target_fips"
  echo "    networks=$target_networks subnets=$target_subnets routers=$target_routers ports=$target_ports"
  echo "    security_groups=$target_secgroups security_group_rules=$target_secgroup_rules"
done < "$tmpdir/project_totals.tsv"
echo

if [ "${CONFIRM:-}" != "yes" ]; then
  read -r -p "Proceed with creation? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

add_manifest() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$MANIFEST"
}

: > /dev/null
touch "$MANIFEST"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/loadtest.pub}"
if [ ! -f "$SSH_KEY" ]; then
  echo "SSH public key not found: $SSH_KEY" >&2
  exit 1
fi

echo "Creating projects, users, and keypairs..."
current_client=""
while read -r client project; do
  if [ "$client" != "$current_client" ]; then
    current_client="$client"
    user="$client"
    password=$(python3 -c 'import secrets; print(secrets.token_urlsafe(16))')
    if ! openstack user show "$user" >/dev/null 2>&1; then
      user_id=$(openstack user create --domain default --password "$password" --email "${user}@example.com" "$user" -f value -c id)
      add_manifest user "$user_id" "$user" "$project"
      {
        echo "Client: $client"
        echo "  Username: $user"
        echo "  Password: $password"
        echo "  Project: $project"
        echo
      } >> "$CREDENTIALS"
    else
      user_id=$(openstack user show "$user" -f value -c id)
      {
        echo "Client: $client"
        echo "  Username: $user"
        echo "  Password: (existing user; password not changed)"
        echo "  Project: $project"
        echo
      } >> "$CREDENTIALS"
    fi
  fi

  if ! openstack project show "$project" >/dev/null 2>&1; then
    project_id=$(openstack project create --domain default "$project" -f value -c id)
    add_manifest project "$project_id" "$project" "$project_id"
  else
    project_id=$(openstack project show "$project" -f value -c id)
  fi

  keypair_name="loadtest"
  admin_user="${OS_USERNAME:-admin}"

  if ! openstack role assignment list --names --project "$project_id" --user "$admin_user" -f value -c Role 2>/dev/null | grep -qx member; then
    openstack role add --project "$project_id" --user "$admin_user" member
  fi

  env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack keypair delete "$keypair_name" >/dev/null 2>&1 || true
  env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack keypair create --public-key "$SSH_KEY" "$keypair_name" >/dev/null
  add_manifest keypair "${project_id}:${keypair_name}" "${project}:${keypair_name}" "$project_id"

  if ! openstack role assignment list --names --project "$project_id" --user "$user_id" -f value -c Role 2>/dev/null | grep -qx member; then
    openstack role add --project "$project_id" --user "$user_id" member
    add_manifest role_assignment "${project_id}:${user_id}" "${project}:${user}" "$project_id"
  fi
done < "$tmpdir/projects.tsv"

echo "Setting project quotas..."
while read -r client project vms cores ram fips networks; do
  project_id=$(openstack project show "$project" -f value -c id)
  target_instances=$((vms + 2))
  target_cores=$((cores + 2))
  target_ram=$((ram + 1024))
  target_fips=$((fips + 2))
  target_networks=$((networks + 2))
  target_subnets=$((networks + 2))
  target_routers=2
  target_ports=$((vms + networks + target_routers + 5))
  target_secgroups=6
  target_secgroup_rules=40
  openstack quota set \
    --instances "$target_instances" \
    --cores "$target_cores" \
    --ram "$target_ram" \
    --floating-ips "$target_fips" \
    --networks "$target_networks" \
    --subnets "$target_subnets" \
    --routers "$target_routers" \
    --ports "$target_ports" \
    --secgroups "$target_secgroups" \
    --secgroup-rules "$target_secgroup_rules" \
    "$project_id"
done < "$tmpdir/project_totals.tsv"

echo "Creating networks and subnets..."
while IFS=$'\t' read -r client project network subnet subnet_index role cidr; do
  project_id=$(openstack project show "$project" -f value -c id)
  if ! env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack network show "$network" >/dev/null 2>&1; then
    network_id=$(env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack network create "$network" -f value -c id)
    add_manifest network "$network_id" "$network" "$project_id"
  else
    network_id=$(env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack network show "$network" -f value -c id)
  fi

  if ! env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack subnet show "$subnet" >/dev/null 2>&1; then
    subnet_id=$(env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack subnet create \
      --network "$network" \
      --subnet-range "$cidr" \
      --dns-nameserver 172.24.4.1 \
      "$subnet" -f value -c id)
    add_manifest subnet "$subnet_id" "$subnet" "$project_id"
  fi
done < "$tmpdir/networks.tsv"

echo "Creating routers..."
while read -r client project; do
  project_id=$(openstack project show "$project" -f value -c id)
  router="${project}-router"
  if ! env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack router show "$router" >/dev/null 2>&1; then
    router_id=$(env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack router create "$router" -f value -c id)
    add_manifest router "$router_id" "$router" "$project_id"
  else
    router_id=$(env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack router show "$router" -f value -c id)
  fi
  env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack router set "$router" --external-gateway provider-net || true
  while IFS=$'\t' read -r c p network subnet subnet_index role cidr; do
    if [ "$p" = "$project" ]; then
      subnet_id=$(env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack subnet show "$subnet" -f value -c id)
      if env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack router add subnet "$router" "$subnet" >/dev/null 2>&1; then
        add_manifest router_subnet "${router_id}:${subnet_id}" "${router}:${subnet}" "$project_id"
      fi
    fi
  done < "$tmpdir/networks.tsv"
done < "$tmpdir/projects.tsv"

echo "Creating security groups..."
while read -r client project; do
  project_id=$(openstack project show "$project" -f value -c id)
  baseline_sg="${project}-sg-baseline"
  frontend_sg="${project}-sg-frontend"
  backend_sg="${project}-sg-backend"
  database_sg="${project}-sg-database"

  for sg in "$baseline_sg" "$frontend_sg" "$backend_sg" "$database_sg"; do
    if ! env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack security group show "$sg" >/dev/null 2>&1; then
      sg_id=$(env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack security group create "$sg" -f value -c id)
      add_manifest security_group "$sg_id" "$sg" "$project_id"
    fi
  done

  for sg in "$baseline_sg" "$frontend_sg" "$backend_sg" "$database_sg"; do
    case "$sg" in
      "$baseline_sg")
        env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack security group rule create --proto icmp "$sg" >/dev/null 2>&1 || true
        env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack security group rule create --proto tcp --dst-port 22 "$sg" >/dev/null 2>&1 || true
        env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack security group rule create --proto tcp --dst-port 80 "$sg" >/dev/null 2>&1 || true
        env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack security group rule create --proto tcp --dst-port 443 "$sg" >/dev/null 2>&1 || true
        ;;
      "$frontend_sg")
        env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack security group rule create --proto tcp --dst-port 80 "$sg" >/dev/null 2>&1 || true
        env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack security group rule create --proto tcp --dst-port 443 "$sg" >/dev/null 2>&1 || true
        ;;
      "$backend_sg")
        env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack security group rule create --proto tcp --dst-port 8080 --remote-group "$frontend_sg" "$sg" >/dev/null 2>&1 || true
        ;;
      "$database_sg")
        env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack security group rule create --proto tcp --dst-port 3306 --remote-group "$backend_sg" "$sg" >/dev/null 2>&1 || true
        env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack security group rule create --proto tcp --dst-port 5432 --remote-group "$backend_sg" "$sg" >/dev/null 2>&1 || true
        ;;
    esac
  done
done < "$tmpdir/projects.tsv"

ensure_floating_ip() {
  local project="$1" vm_name="$2"
  local addresses fip_addr fip_id

  addresses=$(env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack server show "$vm_name" -f value -c addresses 2>/dev/null || true)
  if printf '%s\n' "$addresses" | grep -qE '172\.24\.4\.[0-9]+'; then
    printf '%s\n' "$addresses" | grep -oE '172\.24\.4\.[0-9]+' | head -n 1
    return 0
  fi

  fip_addr=$(env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project"     openstack floating ip list -f value -c "Floating IP Address" -c "Fixed IP Address" |     awk '$2 == "None" { print $1; exit }')

  if [ -z "$fip_addr" ]; then
    fip_id=$(env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project"       openstack floating ip create provider-net -f value -c id)
    fip_addr=$(env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project"       openstack floating ip show "$fip_id" -f value -c floating_ip_address)
    add_manifest floatingip "$fip_id" "$fip_addr" "$project"
  else
    fip_id=$(env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project"       openstack floating ip show "$fip_addr" -f value -c id)
  fi

  env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project"     openstack server add floating ip "$vm_name" "$fip_addr"
  printf '%s\n' "$fip_addr"
}

echo "Launching virtual machines..."
while IFS=$'\t' read -r client project network_index vm_index flavor public vcpus ram host role; do
  network="${project}-net${network_index}"
  vm_name="${project}-vm${vm_index}"
  baseline_sg="${project}-sg-baseline"
  case "$role" in
    frontend) role_sg="${project}-sg-frontend" ;;
    backend) role_sg="${project}-sg-backend" ;;
    database) role_sg="${project}-sg-database" ;;
    *) role_sg="${project}-sg-frontend" ;;
  esac

  if env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack server show "$vm_name" >/dev/null 2>&1; then
    echo "Reusing existing server $vm_name"
    existing_fip=$(env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack server show "$vm_name" -f value -c addresses | grep -oE '172\.24\.4\.[0-9]+' | head -n 1 || true)
    if [ "$public" -eq 1 ] && [ -z "$existing_fip" ]; then
      fip_addr=$(ensure_floating_ip "$project" "$vm_name")
      echo "  attached floating IP $fip_addr"
    elif [ "$public" -eq 1 ]; then
      echo "  floating IP $existing_fip"
    fi
    continue
  fi

  env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack server create "$vm_name" \
    --image "$IMAGE_NAME" \
    --flavor "$flavor" \
    --network "$network" \
    --security-group "$baseline_sg" \
    --security-group "$role_sg" \
    --key-name "$KEY_NAME" \
    --availability-zone "nova:$host" \
    --wait

  vm_id=$(env -u OS_PROJECT_ID -u OS_TENANT_NAME OS_PROJECT_NAME="$project" openstack server show "$vm_name" -f value -c id)
  add_manifest server "$vm_id" "$vm_name" "$project"

  if [ "$public" -eq 1 ]; then
    fip_addr=$(ensure_floating_ip "$project" "$vm_name")
    echo "Created $vm_name on $host with floating IP $fip_addr"
  else
    echo "Created $vm_name on $host"
  fi
done < "$tmpdir/vms.tsv"

echo
echo "Dummy data creation complete."
echo "Manifest: $MANIFEST"
echo "Credentials: $CREDENTIALS"
echo "Run openstack/06-cleanup-dummy-data.sh to remove these resources."
EOF