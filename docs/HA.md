# High availability: what survives what

Every OpenStack service, the shared storage, DNS and the Internet gateway run on **all three controllers**
(`cloud03-contorller01`, `-contorller02`, `-contorlcompute`). No controller is special.

## Where each piece runs and how it fails over

| Piece | Runs on | If one controller dies |
|---|---|---|
| API VIPs 10.0.10.100 / 10.14.40.100 | HAProxy + Keepalived (Kolla), 3 controllers | VIP moves to another controller within seconds |
| Keystone, Nova, Neutron, Glance, Horizon, Gnocchi, CloudKitty, Heat | 3 controllers behind HAProxy | the other two keep serving |
| MariaDB (Galera), RabbitMQ, Valkey | 3 controllers, quorum clusters | 2 of 3 are enough |
| **VM disks, images, telemetry data** | **GlusterFS, one full copy per controller** | reads/writes continue from the other two; the returning node self-heals |
| Prometheus | 3 (HAProxy sends queries to one, others are hot standbys, all scrape everything) | next one takes over, history intact |
| Grafana | 3 (state in MariaDB, dashboards provisioned from files) | the other two keep serving |
| Alertmanager, cloud-exporter | 3 (clustered / one per controller) | nothing to do |
| **DNS** | dnsmasq on all 3 (10.0.70.11-13); every node lists all three | clients try the next server |
| **Internet gateway** 10.12.0.1 and 172.24.4.1 | VRRP between the controllers that have Wi-Fi; the highest *healthy* one holds them | next one takes over (<= ~5 s); a node whose Wi-Fi loses Internet hands over too |
| Live migration, compute nodes | 6 compute nodes | unaffected |

## What is still a single point of failure (physics, not configuration)
1. **The switch.** One switch, one NIC per node.
2. **The Internet uplink, unless 2+ controllers have Wi-Fi.** The gateway is redundant in software, but each
   gateway needs its own Wi-Fi adapter. `ansible/inventory.yml` -> group `gateway` lists the controllers that have one.
   If only controller01 has Wi-Fi, delete the other two lines: everything keeps working, but Internet access depends on
   that one Wi-Fi link. A USB Wi-Fi adapter on a second controller fixes that.
3. **Losing two controllers at once.** MariaDB, RabbitMQ and Gluster all need 2 of 3 (quorum). With 1 left the cloud
   stops accepting changes (running VMs on compute nodes keep running while their disks stay reachable).
4. **Your laptop's route** into the lab goes through one controller's Wi-Fi IP at a time; switch to another one's IP
   (see `docs/ACCESS.md`).

## The cost of 3 copies
GlusterFS replica 3 writes every block to all three controllers, so a compute node sends **3x** what its VMs write over
its single 1 Gb NIC (which also carries all other traffic). Expect roughly 30-40 MB/s of VM write throughput per compute
node. To halve that, set `gluster_arbiter: true` in `ansible/group_vars/all.yml` before running `03-storage.yml`
(two data copies + a metadata-only arbiter on the third controller; still survives any single failure).
Each controller needs disk space for the full VM data. For real workloads use Ceph with dedicated disks.

## Failure drills (do these once, before trusting it)
1. **Gateway:** on the node holding the floating gateway (`ip -br a show egress | grep 10.12.0.1`) run
   `sudo systemctl stop lab-keepalived`. From a compute node `ping 1.1.1.1` should recover within seconds; the address
   appears on another controller; VMs keep Internet. Restart the service afterwards.
2. **Controller:** power off `cloud03-contorller01`. Horizon (http://10.14.40.100), `openstack server list`, Grafana
   and `live-migration/migrate.py --list` keep working. Power it back on: `gluster volume heal nova info` should show 0
   entries after a few minutes.
3. **Storage:** `sudo systemctl stop glusterd` plus `sudo pkill glusterfsd` on one controller: VMs keep running; compute
   nodes keep reading/writing.

## Recovery after a total power loss
Boot the three controllers together, then: `sudo gluster peer status` (2 peers connected) -> `sudo mount -a`
-> `sudo systemctl restart docker` on any node whose containers did not start (Docker deliberately waits for the
shared mounts). Then `gluster volume heal nova info`.

## Running Kolla-Ansible when controller01 is gone
Kolla runs from one node only when you deploy or reconfigure; the running cloud does not need it. To be able to run it
from another controller, keep a copy current with `scripts/sync-deploy-host.sh` (cron it), then on the other
controller run `scripts/00-controller01-bootstrap.sh` once and `kolla/install.sh` (keeps the existing passwords).
**`/etc/kolla/passwords.yml` exists nowhere else: back it up somewhere off the lab.**
