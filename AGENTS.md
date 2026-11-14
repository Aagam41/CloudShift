# CloudShift (cloud03 lab)

Ansible + Kolla-Ansible deployment of an 8-node, no-single-controller OpenStack lab. This repo contains infrastructure code and runbooks, not an application; there is no build, lint, or test suite.

## Commands (run on cloud03-contorller01 unless noted)

- Bootstrap deploy host: `scripts/00-controller01-bootstrap.sh` (as normal user)
- Preflight (read-only): `cd ansible && ansible-playbook 00-preflight.yml -K`
- Provision network/storage/DNS/gateway: `cd ansible && ansible-playbook site.yml -K`
- Install Kolla-Ansible + config: `kolla/install.sh` (`RELEASE=2026.2 kolla/install.sh` if the branch is missing)
- Deploy OpenStack: `kolla/deploy.sh` (pauses after prechecks; type `DEPLOY`)
- Cloud resources: `openstack/01-cloud-setup.sh`
- Exporter: `cd ansible && ansible-playbook 05-exporter.yml -K`
- Billing rates: `openstack/02-billing-rates.sh`
- Live-migration test: `live-migration/test.sh`
- Regenerate dashboards: `cd monitoring && python3 make_dashboards.py`, then `kolla-ansible reconfigure -t grafana -i ~/multinode`
- Migrate a VM: `~/kolla-venv/bin/python live-migration/migrate.py ...`
- Scheduler (starts `dry_run: true`): `~/kolla-venv/bin/python live-migration/scheduler.py`
- Invoice: `~/kolla-venv/bin/python scripts/invoice.py --month YYYY-MM`
- CPU compatibility: `scripts/cpu-check.sh`
- Sync deploy role to other controllers: `scripts/sync-deploy-host.sh`

OpenStack CLI needs `source ~/kolla-venv/bin/activate && source /etc/kolla/admin-openrc.sh`. Kolla inventory is `~/multinode`.

## Layout

- `ansible/` network, gateway/DNS, GlusterFS, verification playbooks
- `kolla/` installer, deployer, `globals.yml`, `multinode-head.ini`, config templates
- `openstack/` networks, image, flavors, billing rules, client onboarding
- `monitoring/` `cloud_exporter.py` and `make_dashboards.py`
- `live-migration/` `migrate.py`, example `scheduler.py`, end-to-end test
- `scripts/` bootstrap, CPU check, invoice, deploy-host sync
- `docs/` `HA.md`, `ACCESS.md`, `CHANGES-FROM-KIT.md`

## High-signal quirks

- Hostnames are intentionally misspelled (`cloud03-contorller01`, `...contorller02`, `...contorlcompute`) and must equal the inventory names; preflight checks this. Do not "fix" them.
- `ansible/inventory.yml` is the single source of truth for the node list; `host_id` drives every IP address.
- `ansible.cfg` sets `inventory = inventory.yml`; run playbooks from `ansible/`.
- Gateway group contains only controllers with Wi-Fi. `gateway_vrrp_password` must be exactly 8 characters.
- Existing node netplan must keep its `192.168.0.x` address and have no default route; `01-network.yml` aborts otherwise unless `-e allow_other_default=true`.
- `01-network.yml` removes stray netplan files that do not define the node's NIC, and removes `50-cloud-init.yaml` only when the NIC is defined elsewhere; it keeps `01-network-manager-all.yaml`.
- VLAN interfaces are named uniformly (`mgmt`, `storage`, ...), never by physical NIC name.
- `kolla/install.sh` merges `multinode-head.ini` with Kolla's stock inventory from the venv; the head's service groups must list all 3 controllers. Check its printed inventory graph.
- `RELEASE` selects `stable/<release>` (default `2026.1`).
- `kolla-genpwd` always runs in `install.sh` and only fills blank password values.
- `deploy.sh` stops after prechecks and waits for `DEPLOY`; `post-deploy` needs `-i` (already fixed here).
- GlusterFS bricks are plain directories under `/srv/gluster`; mount a dedicated disk there before `03-storage.yml` if desired (`gluster_require_dedicated_disk: true`). `gluster_arbiter` must be set before storage.
- Unmounted Gluster mount points are made immutable; services must fail loudly rather than write locally.
- `/etc/kolla/passwords.yml` exists only on the deploy host; back it up off-lab. `sync-deploy-host.sh` propagates it.
- `make_dashboards.py` `main()` deletes every `*.json` in its output dir before regenerating.
- `cloud_exporter.py` binds `BIND` (default `10.0.10.11`) on port `9199` and runs on every controller.
- Scheduler starts in `dry_run: true`; Prometheus uses basic auth `admin` / `prometheus_password`.
- Billing flavor names must match `openstack/01-cloud-setup.sh`; CloudKitty CLI column names may differ (use `-f json`).
- CPU baseline is Nehalem; after editing `kolla/config/nova/nova-compute.conf`, run `kolla-ansible reconfigure -t nova -i ~/multinode`.
- `live-migration/test.sh` creates `lm-test`; delete it manually afterward.

## Validation

No automated tests. Playbooks are checked with `ansible-playbook --syntax-check`; templates render with real Ansible; keepalived/dnsmasq configs pass their `--config-test`/`--test`. Everything else requires the actual hardware.

## References

`README.md`, `docs/HA.md`, `docs/ACCESS.md`, `docs/CHANGES-FROM-KIT.md`. Prefer executable config/scripts over prose when they conflict.