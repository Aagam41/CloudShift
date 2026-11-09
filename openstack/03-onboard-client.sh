#!/usr/bin/env bash
# Create a client: project + user + quotas.   ./03-onboard-client.sh acme 'Password123' [instances cores ramMB volumes GB fips]
set -euo pipefail
source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh
NAME="$1"; PASS="$2"
INST="${3:-10}"; CORES="${4:-20}"; RAM="${5:-40960}"; VOLS="${6:-10}"; GB="${7:-200}"; FIPS="${8:-5}"

openstack project create --domain default "$NAME"
openstack user create --domain default --password "$PASS" "${NAME}-admin"
openstack role add --project "$NAME" --project-domain default --user "${NAME}-admin" --user-domain default member
openstack quota set --instances "$INST" --cores "$CORES" --ram "$RAM" --volumes "$VOLS" --gigabytes "$GB" --floating-ips "$FIPS" "$NAME"
echo "Client '$NAME' ready: user ${NAME}-admin, project $NAME. Usage and cost appear in the Grafana 'Projects' and 'Billing' dashboards."
