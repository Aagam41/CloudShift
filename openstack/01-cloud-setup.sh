#!/usr/bin/env bash
# Run on cloud03-contorller01 after kolla/deploy.sh: networks, router, image, flavors, security rules.
set -euo pipefail
source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh

# --- Provider (external) network: VLAN 60, 172.24.4.0/24. Controller01 (172.24.4.1 on br-ex) is the gateway,
#     it NATs this network out through the Wi-Fi. Floating IPs come from .100-.199.
openstack network create --external --share --provider-network-type flat --provider-physical-network physnet1 provider-net
openstack subnet create --network provider-net --subnet-range 172.24.4.0/24 --gateway 172.24.4.1 \
  --no-dhcp --allocation-pool start=172.24.4.100,end=172.24.4.199 --dns-nameserver 172.24.4.1 provider-subnet

# --- Default tenant network + router (VMs use the lab DNS through the router: 172.24.4.1 floats with the gateway)
openstack network create private-net
openstack subnet create --network private-net --subnet-range 192.168.50.0/24 --dns-nameserver 172.24.4.1 private-subnet
openstack router create r1
openstack router set r1 --external-gateway provider-net
openstack router add subnet r1 private-subnet

# --- Image, flavors. The flavor NAMES are used by the billing rates (02-billing-rates.sh)
IMG=cirros-0.6.2-x86_64-disk.img
[ -f "$IMG" ] || wget -q "https://download.cirros-cloud.net/0.6.2/$IMG"
openstack image create cirros --file "$IMG" --disk-format qcow2 --container-format bare --public
openstack flavor create m1.tiny   --vcpus 1 --ram 512  --disk 5
openstack flavor create m1.small  --vcpus 1 --ram 1024 --disk 10
openstack flavor create m1.medium --vcpus 2 --ram 2048 --disk 20
openstack flavor create m1.large  --vcpus 4 --ram 4096 --disk 40

# --- Access (the default security group of the admin project)
openstack security group rule create --proto icmp default
openstack security group rule create --proto tcp --dst-port 22 default
[ -f mykey.pem ] || { openstack keypair create mykey > mykey.pem; chmod 600 mykey.pem; }

echo "Done. Next: ansible/05-exporter.yml, openstack/02-billing-rates.sh, live-migration/test.sh"
