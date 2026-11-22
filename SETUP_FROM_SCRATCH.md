# CloudShift: Complete 8-Node OpenStack Lab Setup Guide (From Scratch)

This document provides a comprehensive end-to-end guide to recreate the CloudShift High-Availability (HA) OpenStack cluster from scratch, covering physical hardware, network switch configuration, operating system prerequisites, and the step-by-step deployment workflow.

---

## 1. Physical Hardware Requirements

The lab consists of **8 physical bare-metal nodes** connected to a managed Gigabit switch:

### A. 3 Controller Nodes
- **Hostnames**:
  - `cloud03-controller01` (Deployer host / gateway candidate)
  - `cloud03-controller02` (Gateway candidate)
  - `cloud03-controller03` / `cloud03-contorlcompute` (Gateway candidate + compute host)
- **RAM**: Minimum 16 GB per controller (runs full control plane, MariaDB Galera, RabbitMQ, Valkey, GlusterFS, Prometheus, and Grafana).
- **Disk Storage**:
  - OS root disk (SSD recommended).
  - A dedicated disk or partition on each controller for `/srv/gluster` (GlusterFS replica-3 storage for VM disks, Glance images, and telemetry).
- **Network Interfaces**:
  - 1x 1Gbps Ethernet NIC connected to the switch trunk.
  - 1x Wi-Fi adapter (`wlo1` or compatible USB dongle) on each controller acting as a floating redundant internet gateway.

### B. 5 Dedicated Compute Nodes
- **Hostnames**:
  - `cloud03-compute01`
  - `cloud03-compute02`
  - `cloud03-compute03`
  - `cloud03-compute04`
  - `cloud03-compute05`
- **CPU**: Intel or AMD 64-bit processors with hardware virtualization enabled in BIOS/UEFI (**Intel VT-x** or **AMD-V**). Compute nodes should share a compatible CPU baseline for live migration.
- **RAM**: 8–16 GB+ per node for hosting tenant virtual machines.
- **Disk Storage**: Standard OS root disk.
- **Network Interface**: 1x 1Gbps Ethernet NIC connected to the switch trunk.

---

## 2. Network Topology & Switch VLANs

### Managed Switch Configuration (e.g., TP-Link TL-SG2210P)
All 8 physical ports (ports 1–8) are configured as **802.1Q trunk ports** carrying the following tagged VLANs, with **PVID 1** as the untagged native management network (`192.168.0.0/24`):

| VLAN ID | Name | Subnet | Purpose |
|---|---|---|---|
| **10** | MGMT | `10.0.10.0/24` (VIP `.100`) | Internal API, RabbitMQ, MariaDB, SSH, VM migration |
| **20** | STORAGE | `10.0.20.0/24` | GlusterFS distributed storage (3x data replication) |
| **30** | TUNNEL | `10.11.10.0/24` | VXLAN tenant virtual overlay networks |
| **40** | API | `10.14.40.0/24` (VIP `.100`) | External public VIP, Horizon dashboard, Grafana |
| **50** | EGRESS | `10.12.0.0/24` (VIP `.1`) | Internet egress default route via floating VRRP gateway |
| **60** | PROVIDER | `172.24.4.0/24` (VIP `.1`) | OpenStack Neutron floating IP provider network |
| **70** | DNS | `10.0.70.0/24` | Redundant cluster DNS on all 3 controllers (`.11`, `.12`, `.13`) |

### Uplink Network
- The home/upstream Wi-Fi network operates on `192.168.1.0/24`, completely isolated from internal lab subnets.

---

## 3. Software Prerequisites

- **Operating System**: Ubuntu Server 22.04 LTS or 24.04 LTS installed across all 8 nodes.
- **Initial Addressing**:
  - `controller01`: `192.168.0.11`
  - `controller02`: `192.168.0.12`
  - `controller03`: `192.168.0.13`
  - `compute01` to `compute05`: `192.168.0.21` to `192.168.0.25`
- **Initial User**: Standard administrative user (`ubuntu`) with sudo privileges.
- **Base Tools**: `ansible-core`, `python3-venv`, `git`, OpenSSH, and Docker (installed via Kolla).

---

## 4. Step-by-Step Deployment Runbook

All commands are run from **`cloud03-controller01`** unless otherwise noted.

### Step 1: Switch Configuration
1. Log into your switch admin UI (e.g., `http://192.168.0.1`).
2. Navigate to **VLAN > 802.1Q VLAN > Add**.
3. Create VLANs `10, 20, 30, 40, 50, 60, 70` and set **Ports 1–8 as Tagged**.
4. Set PVID to `1` on ports 1–8 and save config (refer to `switch/switch-vlans.md`).

### Step 2: Node Hostnames & Bootstrap
1. On each node, ensure the hostname matches the inventory name:
   ```bash
   sudo hostnamectl set-hostname <inventory_hostname>
   ```
2. Verify and edit `ansible/inventory.yml`:
   - Set the correct physical Ethernet NIC for each host (`ip -br link`).
   - Set the Wi-Fi interface name (`wifi_if: wlo1`) for controllers with Wi-Fi.
3. Run the bootstrap script:
   ```bash
   scripts/00-controller01-bootstrap.sh
   ```
   *(Installs Ansible, generates an ed25519 SSH key, distributes it to all nodes, and provisions the `ansible` user).*

### Step 3: Preflight & Hardware Checks
1. Run preflight checks:
   ```bash
   cd ansible
   ansible-playbook 00-preflight.yml -K
   ```
   *(Verifies CPU virtualization flags, netplan configurations, and hostname resolution).*
2. Check CPU compatibility for live migration:
   ```bash
   scripts/cpu-check.sh
   ```
   *(Identifies lowest common CPU model baseline across compute nodes).*

### Step 4: GlusterFS Storage Preparation
1. Run the interactive storage manager on each controller:
   ```bash
   ./scripts/storage-manager.sh controller01
   ./scripts/storage-manager.sh controller02
   ./scripts/storage-manager.sh controller03
   ```
   *(Select a dedicated disk or partition to format and mount at `/srv/gluster`).*
2. Apply the GlusterFS mount configuration:
   ```bash
   cd ansible
   ansible-playbook 03a-prepare-glusterfs.yml -K
   ```

### Step 5: Network, DNS, Gateway, and GlusterFS Cluster Setup
Provision the foundational network and cluster storage:
```bash
cd ansible
ansible-playbook site.yml -K
```
*(Creates the tagged VLAN sub-interfaces, configures Keepalived VRRP floating default gateway, configures dnsmasq on all 3 controllers, and initializes the GlusterFS replica-3 volume).*

### Step 6: Install Kolla-Ansible
Set up the Kolla environment and configuration templates:
```bash
kolla/install.sh
```
*(Creates the Python virtual environment at `~/kolla-venv`, generates `/etc/kolla/passwords.yml`, and builds the multi-node inventory `~/multinode`).*

### Step 7: Deploy OpenStack
Deploy the high-availability containerized OpenStack services:
```bash
kolla/deploy.sh
```
*(Runs prechecks, prompts for `DEPLOY` confirmation, pulls containers, and deploys Keystone, Nova, Neutron, Glance, Horizon, Gnocchi, Ceilometer, CloudKitty, MariaDB, RabbitMQ, and Valkey across the cluster).*

### Step 8: Initialize Cloud Resources
Provision flavors, base networks, router, and cloud images:
```bash
openstack/01-cloud-setup.sh
```

### Step 9: Observability, Metrics & Billing
1. Deploy Prometheus exporters across nodes:
   ```bash
   cd ansible
   ansible-playbook 05-exporter.yml -K
   ```
2. Configure CloudKitty billing rates:
   ```bash
   openstack/02-billing-rates.sh
   ```
3. Generate and deploy Grafana dashboards:
   ```bash
   cd monitoring
   python3 make_dashboards.py
   kolla-ansible reconfigure -t grafana -i ~/multinode
   ```

### Step 10: Live Migration Verification & Sync
1. Test end-to-end VM live migration between compute nodes:
   ```bash
   live-migration/test.sh
   ```
2. Replicate Kolla credentials to the other two controllers for complete failover redundancy:
   ```bash
   scripts/sync-deploy-host.sh
   ```

---

## 5. Daily Operations & Useful Commands

- **OpenStack CLI Environment**:
  ```bash
  source ~/kolla-venv/bin/activate
  source /etc/kolla/admin-openrc.sh
  ```
- **VM Live Migration**:
  ```bash
  ~/kolla-venv/bin/python live-migration/migrate.py --list
  ~/kolla-venv/bin/python live-migration/migrate.py <vm_name>
  ~/kolla-venv/bin/python live-migration/migrate.py --drain <compute_host>
  ```
- **Autonomous Balancing Service**:
  ```bash
  ~/kolla-venv/bin/python live-migration/scheduler.py
  ```
- **Client Onboarding**:
  ```bash
  openstack/03-onboard-client.sh <client_name> '<password>'
  ```
- **Monthly Invoicing**:
  ```bash
  ~/kolla-venv/bin/python scripts/invoice.py --month YYYY-MM --out invoice.csv
  ```
- **Accessing Web Dashboards**:
  - **Horizon Dashboard**: `http://10.14.40.100` (User: `admin`, password in `/etc/kolla/passwords.yml` -> `keystone_admin_password`)
  - **Grafana Dashboard**: `http://10.14.40.100:3000` (User: `admin`, password in `/etc/kolla/passwords.yml` -> `grafana_admin_password`)
