# What changed compared with openstack-kolla-lab-kit.zip

Your kit is a good plan and documents the design well, but it stops at documentation: it did not contain the
configuration that makes the plan real. Everything in the address plan, VLAN list, VIPs, host names and
switch layout is kept exactly as you defined it.

## Problems found in the kit's scripts and inventory (fixed here)
| Problem | Effect | Fix |
|---|---|---|
| `kolla-genpwd` only ran when `passwords.yml` was missing, but copying Kolla's examples creates it with EMPTY values | deploy fails or services get blank passwords | `install.sh` always runs `kolla-genpwd` (it only fills blanks) |
| `kolla-ansible post-deploy` was called without `-i <inventory>` | wrong/no inventory, no `clouds.yaml` | `deploy.sh` passes `-i` |
| `cloud03-contorlcompute` was only in `[control]`/`[network]` although the name says it also computes | one compute node missing from the cloud | added to `[compute]` (delete that line to make it control-only) |
| `[storage]` pointed at two controllers with local LVM partitions | not shared storage: no live migration, no boot-from-volume across nodes | Cinder off for now; VM disks, images and telemetry on GlusterFS with one copy per controller (see `docs/HA.md`) |
| `globals.yml` hard-coded interface names like `enp3s0.10` | breaks as soon as one node's NIC has another name | VLAN interfaces get the same names on every node (`mgmt`, `tunnel`, ...) |
| `storage_interface` in globals | not used by Kolla at all (checked in kolla-ansible 23.0.0) | removed |
| Gnocchi/Glance use node-local storage by default, which breaks when they run on 3 controllers | images or metrics missing depending on which node answers | their data directories point at shared GlusterFS volumes, so they run on all 3 (verified in Kolla's `glance_api_hosts` logic) |
| VLAN 40 used 192.168.1.0/24, which is your home Wi-Fi range | routing conflict on every controller | VLAN 40 is now **10.14.40.0/24** (external VIP 10.14.40.100); `00-preflight.yml` checks the real Wi-Fi network against every lab subnet |
| Gateway address 10.12.0.1 was controller01's own address | Internet for the whole lab dies with controller01 | 10.12.0.1 is now a floating (VRRP) address; controller01 is 10.12.0.11 like the others |

## Added (the kit described these but did not implement them)
- Ansible: VLAN interfaces and addresses for all 8 nodes from one inventory, `/etc/hosts`, sudo, chrony
- Redundant Internet gateway: every controller with Wi-Fi can be the gateway (VRRP, health-checked); NAT for VLAN 50 and the VLAN 60 provider network; default route on the other nodes points at the floating address
- DNS service (dnsmasq) on all three controllers: cluster names, API VIP names, upstream forwarding, for nodes AND for VMs
- Provider gateway address 172.24.4.1 that follows the gateway master onto its `br-ex`
- GlusterFS (3 copies, one per controller) mounted on the compute nodes (live migration) and controllers (images, telemetry), with a guard against writing locally if a mount is missing
- Kolla `globals.yml`, inventory, installer, staged deploy
- Telemetry and billing: Ceilometer, Gnocchi, CloudKitty with pricing rules and a monthly invoice script
- Monitoring: Prometheus, 7 Grafana dashboards, a small exporter for per-VM / per-project / billing / migration metrics
- Live migration: `migrate.py` (simple), `scheduler.py` (example loop), `test.sh` (end-to-end test)
