# OpenStack Lab: Node Preparation & Cluster Bootstrap Guide
**Platform:** 4-Node OpenStack Lab (1 Controller + 3 Compute Nodes)  
**Switch Hardware:** D-Link DGS-1210-28 L2 Managed Switch  
**Automation:** Ansible / Kolla-Ansible (CloudShift)

---

## 1. Overview & Node Identity Mapping

Each physical machine connects directly to the D-Link switch on its dedicated trunk port with a static IP in the native management subnet (`192.168.0.0/24`).

| Node Role | Target Hostname | Switch Port | Static IP | Local Username (`whoami`) |
| :--- | :--- | :---: | :--- | :--- |
| **Controller** | `cloud03-controller01` | **Port 1** | `192.168.0.11` | `cloud03-compute01` |
| **Compute 01** | `cloud03-compute01` | **Port 2** | `192.168.0.21` | `cloud03-compute01` |
| **Compute 02** | `cloud03-compute02` | **Port 3** | `192.168.0.22` | `cloud03-control01` |
| **Compute 03** | `cloud03-compute03` | **Port 4** | `192.168.0.23` | `cloud03` |

* **Internet Uplink:** Controller PC only, via USB phone tethering / Wi-Fi (`enx629176816cc5`).
* **Switch Management:** `192.168.0.1` (Untagged native VLAN 1, PVID 1).

---

## 2. Step 1: Base Node Configuration (On Each Physical PC)

### A. Set Hostname
Run on each respective PC:
```bash
# On Controller:
sudo hostnamectl set-hostname cloud03-controller01

# On Compute 01:
sudo hostnamectl set-hostname cloud03-compute01

# On Compute 02:
sudo hostnamectl set-hostname cloud03-compute02

# On Compute 03:
sudo hostnamectl set-hostname cloud03-compute03
```

---

### B. Clean Old Netplan Files & Set Static IP
To prevent IP collisions and unwanted default gateways, back up old Netplan files and write a single clean configuration.

```bash
# 1. Back up existing configs:
sudo mkdir -p /etc/netplan/backup
sudo mv /etc/netplan/*.yaml /etc/netplan/*.yml /etc/netplan/backup/ 2>/dev/null || true

# 2. Write the clean IP (Example for Controller; replace IP with .21, .22, or .23 for computes):
sudo tee /etc/netplan/01-netcfg.yaml << 'EOF'
network:
  version: 2
  ethernets:
    eno1:
      dhcp4: false
      addresses:
        - 192.168.0.11/24
EOF

# 3. Secure permissions and apply:
sudo chmod 600 /etc/netplan/01-netcfg.yaml
sudo netplan apply
```
*(Note: Never add a `gateway4` or default route on the Compute nodes; the cluster floating gateway will be configured automatically).*

---

### C. Ensure SSH Server is Running (Compute Nodes)
Ubuntu Desktop does not enable SSH by default. On Compute 01, 02, and 03:
```bash
sudo apt update && sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

---

## 3. Step 2: Layer-2 Connectivity Verification

From the **Controller PC (`192.168.0.11`)**, verify you can reach the switch, all nodes, and the internet:

```bash
# 1. Verify Internet (Tethering):
ping -c 2 google.com

# 2. Verify Switch:
ping -c 2 192.168.0.1

# 3. Verify All 3 Compute Nodes:
ping -c 2 192.168.0.21
ping -c 2 192.168.0.22
ping -c 2 192.168.0.23
```

---

## 4. Step 3: Multi-User Inventory Configuration

Because each PC was originally installed with a different local administrative username, `ansible/inventory.yml` maps a custom `bootstrap_user` per host:

```yaml
all:
  vars:
    ansible_user: ansible
    ansible_become: true
  children:
    control:
      hosts:
        cloud03-controller01:
          ansible_host: 192.168.0.11
          host_id: 11
          nic: eno1
          bootstrap_user: cloud03-compute01
    compute:
      hosts:
        cloud03-compute01:
          ansible_host: 192.168.0.21
          host_id: 21
          nic: eno1
          bootstrap_user: cloud03-compute01
        cloud03-compute02:
          ansible_host: 192.168.0.22
          host_id: 22
          nic: eno1
          bootstrap_user: cloud03-control01
        cloud03-compute03:
          ansible_host: 192.168.0.23
          host_id: 23
          nic: eno1
          bootstrap_user: cloud03
    gateway:
      hosts:
        cloud03-controller01: {wifi_if: enx629176816cc5, gw_priority: 150}
```

---

## 5. Step 4: The Bootstrap Process (`00-controller01-bootstrap.sh`)

Run directly on **`cloud03-controller01`**:
```bash
cd ~/Cloud-Project
scripts/00-controller01-bootstrap.sh
```

### What this script executes:

1. **Generates an Ed25519 SSH Keypair:**
   Creates `~/.ssh/id_ed25519` on the Controller without passphrases.
2. **Distributes Public Key to All Nodes (`ssh-copy-id`):**
   Iterates through each node using its exact `bootstrap_user`:
   * `cloud03-compute01@192.168.0.11`
   * `cloud03-compute01@192.168.0.21`
   * `cloud03-control01@192.168.0.22`
   * `cloud03@192.168.0.23`
3. **Provisions the Unified `ansible` Service User:**
   Executes `ansible/00-create-ansible-user.yml` to:
   * Create user `ansible` on all 4 machines with sudo privileges.
   * Add the Controller's Ed25519 public key to `/home/ansible/.ssh/authorized_keys`.
   * Configure passwordless sudo in `/etc/sudoers.d/ansible`:
     ```text
     ansible ALL=(ALL) NOPASSWD: ALL
     ```
4. **Verifies Cluster-Wide Automated Access:**
   * Runs `ansible all -m ping` (Tests passwordless SSH as user `ansible`).
   * Runs `ansible all -m command -a "whoami" -b` (Tests passwordless root execution).

Output confirmed:
```text
SUCCESS: All nodes configured
```

---

## 6. Why This Step Was Essential

* **Unified Identity:** Standardizes cluster management under a single `ansible` account, ignoring whatever random usernames were chosen during initial OS installation.
* **Passwordless Automation:** OpenStack deployment (Kolla-Ansible) executes hundreds of tasks in parallel across all servers. Passwordless SSH and sudo allow these deployments to complete autonomously without manual prompts.
* **Single Point of Control:** Transforms 4 individual physical computers into a centralized, production-grade cloud compute cluster orchestrated entirely from `cloud03-controller01`.
