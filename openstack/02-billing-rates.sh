#!/usr/bin/env bash
# CloudKitty pricing. Costs apply PER HOUR (the collection period), in arbitrary "credits". Edit the numbers.
# If your cloudkitty client prints other column names, add "-f json" to the `list`/`create` commands to see them.
set -euo pipefail
source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh

openstack rating module enable hashmap
openstack rating module set priority hashmap 100

svc() {   # print the id of a hashmap service, creating it if needed
  local id
  id=$(openstack rating hashmap service list -f value -c "Service ID" -c Name | awk -v n="$1" '$2==n{print $1}')
  [ -n "$id" ] || id=$(openstack rating hashmap service create "$1" -f value -c "Service ID")
  echo "$id"
}

# Instances: price per flavor per hour
S=$(svc instance)
F=$(openstack rating hashmap field create "$S" flavor_name -f value -c "Field ID")
openstack rating hashmap mapping create --field-id "$F" --value m1.tiny   --type flat 0.01
openstack rating hashmap mapping create --field-id "$F" --value m1.small  --type flat 0.02
openstack rating hashmap mapping create --field-id "$F" --value m1.medium --type flat 0.04
openstack rating hashmap mapping create --field-id "$F" --value m1.large  --type flat 0.08

openstack rating hashmap mapping create --service-id "$(svc volume.size)" --type flat 0.0002   # per GiB-hour
openstack rating hashmap mapping create --service-id "$(svc ip.floating)" --type flat 0.005    # per floating IP-hour
openstack rating hashmap mapping create --service-id "$(svc network.outgoing.bytes)" --type flat 0.00001   # per MB sent
openstack rating hashmap mapping create --service-id "$(svc image.size)" --type flat 0.000002  # per MiB-hour

openstack rating hashmap service list
