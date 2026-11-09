# Cloud03: 8-node OpenStack (Kolla-Ansible) lab, no single controller

Built on your `openstack-kolla-lab-kit` (same hostnames, VLAN numbers, VIPs and host IDs), completed so you can deploy.
What changed and why: `docs/CHANGES-FROM-KIT.md`. What survives which failure: **`docs/HA.md`**.

```
                       Wi-Fi (your home network 192.168.1.0/24)
                 ,---------------+---------------.
        contorller01      contorller02      contorlcompute       <- the 3 controllers: ALL services on ALL of them
        (gateway cand.)   (gateway cand.)   (gateway cand. + also a compute node)
                 `---------------+---------------'
      TP-Link switch: every port a trunk with VLANs 10 20 30 40 50 60 70
                 .---------------+---------------.
        compute01  compute02  compute03  compute04  compute05
```

| VLAN | Subnet | Purpose |
|---|---|---|
| 10 MGMT | 10.0.10.0/24 (VIP .100) | API, RabbitMQ, MariaDB, live-migration traffic |
| 20 STORAGE | 10.0.20.0/24 | GlusterFS: 3 copies of VM disks, images, telemetry |
| 30 TUNNEL | 10.11.10.0/24 | VXLAN tenant networks |
| 40 API | **10.14.40.0/24** (VIP .100) | External VIP, Horizon, Grafana (controllers). Moved off 192.168.1.0/24 (your Wi-Fi) |
| 50 EGRESS | 10.12.0.0/24 (.1 floating) | Internet: every node's default route -> floating gateway |
| 60 PROVIDER | 172.24.4.0/24 (.1 floating) | Floating IPs; gateway follows the Internet gateway |
| 70 DNS | 10.0.70.0/24 | lab DNS on all three controllers (.11 .12 .13) |

Host address = `<subnet>.<id>`: controller01 .11, controller02 .12, contorlcompute .13, compute01-05 .21-.25.
(Physical/Ansible network 192.168.0.0/24 stays as in your kit.)

## Before you start: confirm these
1. `ansible/inventory.yml`: `ansible_user`, `nic` per host (`ip -br link`), and `wifi_if` for each controller **that has a Wi-Fi adapter**
   (group `gateway`; delete the line of a controller without Wi-Fi, see `docs/HA.md`).
2. Each node's `hostname` equals the inventory name exactly (including "contorller"). Preflight checks this.
3. Your home Wi-Fi is 192.168.1.0/24: that no longer clashes with anything. Preflight verifies it against every lab subnet.
4. Each node's existing netplan keeps its 192.168.0.x address and has NO default route on it (the lab default route is via VLAN 50).
5. **Disk space on the three controllers.** Every VM disk, image and metric is stored 3 times, once per controller, under
   `/srv/gluster`. If a controller has a spare data disk, mount it there first and set `gluster_require_dedicated_disk: true`.
6. RAM: each controller runs the full control plane + telemetry + monitoring, so 16 GB+ each (more for `contorlcompute` if it hosts VMs).

## Steps (about 1-2 hours plus image downloads)

| # | Where | Command |
|---|---|---|
| 1 | Switch | `switch/switch-vlans.md` (7 VLANs, tagged on ports 1-8) |
| 2 | controller01 | `scripts/00-controller01-bootstrap.sh`  (Ansible + SSH keys to all nodes) |
| 3 | controller01 | `cd ansible && ansible-playbook 00-preflight.yml -K`  (read-only; fix what it reports) |
| 4 | controller01 | `scripts/cpu-check.sh`  (CPU model for live migration; edit `kolla/config/nova/nova-compute.conf` if told) |
| 5 | controller01 | `cd ansible && ansible-playbook site.yml -K`  (VLANs, floating gateway, DNS, GlusterFS, then verifies all of it) |
| 6 | controller01 | `kolla/install.sh`  (the inventory check must show the 3 controllers on every line) |
| 7 | controller01 | `kolla/deploy.sh`  (bootstrap, prechecks, **pause**, deploy, post-deploy) |
| 8 | controller01 | `openstack/01-cloud-setup.sh`  (networks, router, image, flavors) |
| 9 | controller01 | `cd ansible && ansible-playbook 05-exporter.yml -K`  then  `openstack/02-billing-rates.sh` |
| 10 | controller01 | `live-migration/test.sh`  (boots a VM on compute01, migrates to compute02 and back) |
| 11 | controller01 | `scripts/sync-deploy-host.sh`  (so another controller can take over deploying; see `docs/HA.md`) |

Steps 3 and 5 stop with a clear message at the first problem; re-running any playbook is safe.
Then open Grafana (`docs/ACCESS.md`): seven dashboards are already there. Run the failure drills in `docs/HA.md` once.

## Live migration
```
~/kolla-venv/bin/python live-migration/migrate.py --list                    # hosts and VM counts
~/kolla-venv/bin/python live-migration/migrate.py web1                      # to the least-loaded host
~/kolla-venv/bin/python live-migration/migrate.py web1 --to cloud03-compute03
~/kolla-venv/bin/python live-migration/migrate.py --drain cloud03-compute01 # empty a host for maintenance
```
`live-migration/scheduler.py` is an example loop (busiest -> idlest node by CPU): put your algorithm in `pick_vm()` / `check()`;
`migrate.py` already handles the Nova call, waiting, errors and rollback detection. Starts in `dry_run: true`.
It can run on any controller (it talks to the API VIP).

## Clients, usage and billing
- New client: `openstack/03-onboard-client.sh acme 'Password123'`
- Prices: edit then run `openstack/02-billing-rates.sh` (credits per hour, per flavor / GiB / floating IP / MB)
- Grafana dashboards: **Cluster overview**, **Compute and VMs**, **Projects and usage**, **Billing**, **Live migration and balance**,
  **Platform health**, **OpenStack resources**. Edit `monitoring/make_dashboards.py`, run it, then `kolla-ansible reconfigure -t grafana -i ~/multinode`.
- Monthly invoice per client: `~/kolla-venv/bin/python scripts/invoice.py --month 2026-10`
- Billing data starts after CloudKitty's first full hourly period. CloudKitty rates usage; it is not a payment system.

## Where things run
| Service | Nodes |
|---|---|
| Keystone, Nova, Neutron, Glance, Horizon, Gnocchi, Ceilometer, CloudKitty, MariaDB, RabbitMQ, Valkey, HAProxy+Keepalived | all 3 controllers |
| Prometheus (active + 2 standby), Grafana, Alertmanager (cluster), cloud-exporter | all 3 controllers |
| dnsmasq (DNS), GlusterFS server (3 copies) | all 3 controllers |
| Internet gateway (floating 10.12.0.1 / 172.24.4.1) | whichever healthy controller with Wi-Fi wins the VRRP election |
| nova-compute, libvirt, Ceilometer compute agent | contorlcompute + compute01-05 |

## What is verified, and what is not
Tested here before delivery: all 7 playbooks pass `ansible-playbook --syntax-check`; every template renders with real Ansible for
all 8 hosts; the generated **keepalived** configs pass the real keepalived 2.2.8 `--config-test` (3-gateway and 1-gateway layouts)
and the **dnsmasq** configs pass dnsmasq 2.91 `--test` (the exact Ubuntu 24.04 versions); the Kolla inventory merge puts every
service on the 3 controllers (tested against kolla-ansible's own sample); every Kolla variable and the multi-node behaviour of
Glance/Gnocchi/Ceilometer/CloudKitty/Prometheus/Grafana was read from kolla-ansible 23.0.0's source; `migrate.py`, `scheduler.py`
and the exporter pass fake-cluster tests; all 87 dashboard queries parse and 65 return data on a real Prometheus 3.5 against fake
metrics (0 errors).

**Not tested (needs your hardware):** the real deployment, netplan on your NICs, the switch commands, **GlusterFS** (the commands
follow public documentation and Gluster's own docs but were not run), actual VRRP failover, live migration on real VMs, and
Grafana rendering. Specifically watch: GlusterFS write speed (3x write amplification, `docs/HA.md`); the Ceilometer coordination
line (`kolla/config/ceilometer/ceilometer-central.conf` uses Kolla's Valkey URL; if deploy complains, delete that file: the only
effect is 3x duplicate polling); dashboard panels in **OpenStack resources** showing "No data" (exporter metric names differ by
release); the CloudKitty CLI column names in `02-billing-rates.sh`; the `stable/2026.1` branch name (`RELEASE=2026.2 kolla/install.sh`
if it fails).

## Troubleshooting
| Symptom | Look at |
|---|---|
| Node has no Internet | which controller holds 10.12.0.1: `ip -br a show egress` on each; `journalctl -u lab-keepalived`; `systemctl status lab-gateway` |
| Nobody holds 10.12.0.1 | `/usr/local/sbin/gw-check.sh; echo $?` on a gateway controller (0 = its Wi-Fi reaches the Internet) |
| Names don't resolve | `systemctl status dnsmasq`, `dig @10.0.70.11 cloud03-compute01` (try .12 and .13) |
| VMs have no Internet | `ip -br a show br-ex` on the gateway master must show 172.24.4.1 (`systemctl status provider-gateway`) |
| Live migration "CPU incompatible" | `cpu_models` in nova-compute.conf, then `kolla-ansible reconfigure -t nova -i ~/multinode` |
| Nova/Glance/Gnocchi won't start | `findmnt /var/lib/nova-shared` etc. (GlusterFS must be mounted; the unmounted directory is immutable on purpose), `gluster peer status` |
| Storage slow or degraded | `sudo gluster volume heal nova info`, `sudo gluster volume status` |
| Prometheus 401 | user `admin`, `prometheus_password` from `/etc/kolla/passwords.yml` |
| Billing dashboard empty | `openstack rating summary get`, rates configured?, `journalctl -u cloud-exporter -n 30` |
