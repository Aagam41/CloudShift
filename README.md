# CloudShift: 4-Node High-Performance OpenStack Lab

Enterprise containerized OpenStack private cloud lab running across 4 physical bare-metal nodes (1 Controller + 3 Compute Hypervisors) connected via an L2 smart managed switch. 

Orchestrated using **Ansible** and **Kolla-Ansible** (2026.1 / Epoxy release on Ubuntu), featuring 7 tagged 802.1Q isolated VLANs, GlusterFS distributed shared storage, autonomous software-defined networking (Neutron), full telemetry, Grafana observability dashboards, CloudKitty billing rating rules, and automated zero-downtime live migration.

---

## 📚 Complete Project Documentation Reference

All in-depth architectural guides, troubleshooting logs, and step-by-step runbooks for this deployment have been compiled and published to the documentation repository:
👉 **[https://github.com/Yashshah025/files](https://github.com/Yashshah025/files)**

### Core Documentation Index:
1. [**SWITCH_CONFIGURATION_GUIDE.md**](https://github.com/Yashshah025/files/blob/main/SWITCH_CONFIGURATION_GUIDE.md): Physical L2 switch setup (D-Link DGS-1210-28), 802.1Q trunking, PVID 1 untagged management, Spanning Tree (RSTP), and port mapping.
2. [**CLUSTER_BOOTSTRAP_GUIDE.md**](https://github.com/Yashshah025/files/blob/main/CLUSTER_BOOTSTRAP_GUIDE.md): Multi-user SSH key distribution, passwordless sudo configuration, and hostnames contract.
3. [**STORAGE_ARCHITECTURE_GUIDE.md**](https://github.com/Yashshah025/files/blob/main/STORAGE_ARCHITECTURE_GUIDE.md): Dedicated secondary drive partitioning (`/dev/sdb`), XFS formatting, GlusterFS volumes (`nova`, `glance`, `gnocchi`), and immutable mount security (`+i`).
4. [**SITE_PROVISIONING_AND_VERIFICATION_GUIDE.md**](https://github.com/Yashshah025/files/blob/main/SITE_PROVISIONING_AND_VERIFICATION_GUIDE.md): Stage-by-stage analysis of `site.yml` (VLAN carving, Keepalived VRRP gateway, NAT masquerading, `dnsmasq`, and full mesh verification).
5. [**KOLLA_ANSIBLE_INSTALL_GUIDE.md**](https://github.com/Yashshah025/files/blob/main/KOLLA_ANSIBLE_INSTALL_GUIDE.md): Deployment virtual environment (`kolla-venv`), cryptographic credential generation (`kolla-genpwd`), and multinode inventory synthesis.
6. [**OPENSTACK_DEPLOYED_ARCHITECTURE_GUIDE.md**](https://github.com/Yashshah025/files/blob/main/OPENSTACK_DEPLOYED_ARCHITECTURE_GUIDE.md): In-depth breakdown of every deployed container (MariaDB, RabbitMQ, Keystone, Nova, Neutron, Glance, Horizon, Ceilometer, Gnocchi, CloudKitty, Prometheus).
7. [**POST_DEPLOYMENT_RESOURCES_AND_LIVE_MIGRATION_GUIDE.md**](https://github.com/Yashshah025/files/blob/main/POST_DEPLOYMENT_RESOURCES_AND_LIVE_MIGRATION_GUIDE.md): Cloud setup (`01-cloud-setup.sh`), metric exporters (`05-exporter.yml`), billing rates (`02-billing-rates.sh`), and live migration verification.
8. [**VM_LIFECYCLE_AND_MANAGEMENT_GUIDE.md**](https://github.com/Yashshah025/files/blob/main/VM_LIFECYCLE_AND_MANAGEMENT_GUIDE.md): Automated multi-node bulk instance provisioning scripts (4 VMs per node), selective/per-host/full teardown scripts, floating IP attachment, and quota management.

---

## 🏛️ Physical & Network Topology

```
                         Uplink / Internet (USB Tethering 10.72.247.x)
                                              |
                                   +----------------------+
                                   | cloud03-controller01 |
                                   | • Control Plane APIs |
                                   | • GlusterFS Storage  |
                                   | • Keepalived Gateway |
                                   +----------------------+
                                              |
                          D-Link DGS-1210-28 Managed Switch
                    Trunk Ports 1-4: 802.1Q Tagged VLANs (10 - 70)
                                              |
            +---------------------------------+---------------------------------+
            |                                 |                                 |
  +-------------------+             +-------------------+             +-------------------+
  | cloud03-compute01 |             | cloud03-compute02 |             | cloud03-compute03 |
  | (Port 2: .21)     |             | (Port 3: .22)     |             | (Port 4: .23)     |
  | • nova-compute    |             | • nova-compute    |             | • nova-compute    |
  | • nova-libvirt    |             | • nova-libvirt    |             | • nova-libvirt    |
  | • neutron-ovs     |             | • neutron-ovs     |             | • neutron-ovs     |
  +-------------------+             +-------------------+             +-------------------+
            \                                 |                                 /
             +--------------------------------+--------------------------------+
                                              |
                       Shared Storage Volume: /var/lib/nova-shared (GlusterFS)
```

### Network & VLAN Segmentation

| VLAN Tag | Interface | Subnet Range | Gateway / VIP | Primary Purpose |
|:---|:---|:---|:---|:---|
| **VLAN 10** | `mgmt` | `10.0.10.0/24` | `10.0.10.100` (VIP) | Internal APIs, MariaDB Galera, RabbitMQ, Nova RPC & Live Migration |
| **VLAN 20** | `storage` | `10.0.20.0/24` | — | Dedicated GlusterFS storage transport |
| **VLAN 30** | `tunnel` | `10.11.10.0/24` | — | Neutron VXLAN overlay networks for tenant instances |
| **VLAN 40** | `api` | `10.14.40.0/24` | `10.14.40.100` (VIP) | Public API endpoints, Horizon Web UI & Grafana |
| **VLAN 50** | `egress` | `10.12.0.0/24` | `10.12.0.1` (VRRP) | Compute nodes default route & NAT masquerade to Internet |
| **VLAN 60** | `provider` | `172.24.4.0/24` | `172.24.4.1` (br-ex) | External floating IP pool (`172.24.4.100` – `.199`) |
| **VLAN 70** | `dns` | `10.0.70.0/24` | `10.0.70.11` | Centralized cluster DNS (`dnsmasq` for `cloud03.lab`) |
| **Native 1** | `eno1` | `192.168.0.0/24` | — | Bare-metal bootstrap & out-of-band management |

---

## 🚀 Step-by-Step Deployment Runbook

### Phase 1: Bare-Metal Bootstrap & Preflight
Run from `cloud03-controller01`:
```bash
# 1. Distribute SSH keys and provision user 'ansible'
./scripts/00-controller01-bootstrap.sh

# 2. Run read-only preflight verification
cd ansible
ansible-playbook 00-preflight.yml
```

### Phase 2: Foundation Provisioning (`site.yml`)
Configures all 7 VLAN interfaces, Keepalived floating gateway, NAT masquerading, `dnsmasq`, GlusterFS shared storage, and executes automated verification checks:
```bash
cd ~/Cloud-Project/ansible
ansible-playbook site.yml
```

### Phase 3: Kolla-Ansible Installation & Deployment
```bash
# 1. Create venv, generate passwords, and build multinode inventory
cd ~/Cloud-Project
kolla/install.sh

# 2. Deploy containerized OpenStack
kolla/deploy.sh
```

### Phase 4: Cloud Resources Initialization
Provisions external `provider-net`, tenant `private-net`, router `r1`, uploads `cirros` to Glance, creates flavors (`m1.tiny`, `m1.small`, `m1.medium`, `m1.large`), and opens security rules:
```bash
cd ~/Cloud-Project
openstack/01-cloud-setup.sh
```

### Phase 5: Observability, Telemetry & Billing Setup
```bash
# 1. Deploy Prometheus metrics exporter
cd ~/Cloud-Project/ansible
ansible-playbook 05-exporter.yml

# 2. Configure CloudKitty rating engine pricing rules
cd ~/Cloud-Project
openstack/02-billing-rates.sh

# 3. Generate and deploy Grafana dashboards
cd ~/Cloud-Project/monitoring
python3 make_dashboards.py
sudo cp -a ~/Cloud-Project/kolla/config/grafana/dashboards/. /etc/kolla/config/grafana/dashboards/
source ~/kolla-venv/bin/activate
kolla-ansible reconfigure -t grafana -i ~/multinode
```

---

## ⚡ Zero-Downtime Live Migration & Load Balancing

### 1. Manual / Targeted Live Migration
Because VM disks reside on `/var/lib/nova-shared` (GlusterFS direct I/O), migrations execute with `block_migration=False`. Only CPU registers and RAM pages transfer across VLAN 10 (`mgmt`):
```bash
source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh

# Live-migrate instance to a specific target host:
python3 live-migration/migrate.py <VM_NAME> --to cloud03-compute02

# Drain a compute node before hardware maintenance:
python3 live-migration/migrate.py --drain cloud03-compute01
```

### 2. Autonomous Dynamic Load-Balancing Scheduler (`scheduler.py`)
Runs as an autonomous optimization daemon:
* **Metric Ingestion:** Continuously samples hypervisor CPU utilization from Prometheus.
* **Imbalance Detection:** Triggers when $\Delta_{CPU} = \text{CPU}_{busiest} - \text{CPU}_{idlest} \ge \text{threshold}$ (e.g. 15%).
* **Selection Algorithm:** Analyzes `libvirt_domain_info_cpu_time_seconds_total` across all instances on the busy host and selects the VM whose CPU load is closest to $\frac{\Delta_{CPU}}{2}$, leveling both hosts without flipping the imbalance.
* **Execution:** Initiates a live migration with zero packet loss and imposes a stabilization cooldown.

```bash
# Edit configuration parameters:
nano live-migration/config.yaml

# Run the scheduler:
~/kolla-venv/bin/python live-migration/scheduler.py
```

---

## 📊 Access & Dashboards

* **Horizon Dashboard (OpenStack Web Console):**
  * **URL:** `http://10.14.40.100` (or `http://10.0.10.11`)
  * **Domain:** `Default` | **User:** `admin`
  * **Password:** `grep 'keystone_admin_password:' /etc/kolla/passwords.yml`
* **Grafana Dashboards:**
  * **URL:** `http://10.14.40.100:3000`
  * **User:** `admin`
  * **Password:** `grep 'grafana_admin_password:' /etc/kolla/passwords.yml`
  * **Included Dashboards:** Cluster Overview, Compute and VMs, Platform Health, Live Migration & Balance, OpenStack Resources, CloudKitty Billing, Projects & Usage.
* **Monthly Client Invoicing:**
  ```bash
  ~/kolla-venv/bin/python scripts/invoice.py --month 2026-11 --out invoice.csv
  cat invoice.csv
  ```
