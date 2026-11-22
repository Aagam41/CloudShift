#!/usr/bin/env bash
# Remove resources recorded by openstack/05-create-dummy-data.sh.
set -uo pipefail

source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh

MANIFEST="${MANIFEST:-$HOME/.config/cloudshift-dummy-data.manifest}"

if [ ! -f "$MANIFEST" ]; then
  echo "No manifest found at $MANIFEST"
  exit 0
fi

if [ "${CONFIRM:-}" != "yes" ]; then
  read -r -p "Delete all resources in $MANIFEST? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

delete_type() {
  local type=$1
  while IFS=$'\t' read -r rtype id name project; do
    [ "$rtype" = "$type" ] || continue
    [ -n "$id" ] || continue
    case "$type" in
      server)
        openstack server delete "$id" --wait >/dev/null 2>&1 || true
        ;;
      floatingip)
        openstack floating ip delete "$id" >/dev/null 2>&1 || true
        ;;
      router_subnet)
        router_id="${id%%:*}"
        subnet_id="${id#*:}"
        openstack router remove subnet "$router_id" "$subnet_id" >/dev/null 2>&1 || true
        ;;
      router)
        openstack router delete "$id" >/dev/null 2>&1 || true
        ;;
      network)
        openstack network delete "$id" >/dev/null 2>&1 || true
        ;;
      security_group)
        openstack security group delete "$id" >/dev/null 2>&1 || true
        ;;
      role_assignment)
        project_id="${id%%:*}"
        user_id="${id#*:}"
        openstack role remove --project "$project_id" --user "$user_id" member >/dev/null 2>&1 || true
        ;;
      user)
        openstack user delete "$id" >/dev/null 2>&1 || true
        ;;
      keypair)
        project_id="${id%%:*}"
        keypair_name="${id#*:}"
        project_name="${name%%:*}"
        OS_PROJECT_NAME="$project_name" OS_PROJECT_ID="$project_id" openstack keypair delete "$keypair_name" >/dev/null 2>&1 || true
        ;;
      project)
        openstack project delete "$id" >/dev/null 2>&1 || true
        ;;
    esac
  done < "$MANIFEST"
}

echo "Deleting servers..."
delete_type server
echo "Deleting floating IPs..."
delete_type floatingip
echo "Removing router interfaces..."
delete_type router_subnet
echo "Deleting routers..."
delete_type router
echo "Deleting networks..."
delete_type network
echo "Deleting security groups..."
delete_type security_group
echo "Removing role assignments..."
delete_type role_assignment
echo "Deleting users..."
delete_type user
echo "Deleting projects..."
delete_type project

echo "Cleanup complete. Manifest retained at $MANIFEST for retry."
EOF