# OpenStack Lab: Preflight Verification Guide (`00-preflight.yml`)
**Platform:** 4-Node OpenStack Cluster (1 Controller + 3 Compute Nodes)  
**Playbook:** `ansible/00-preflight.yml`  
**Execution Context:** Run from Controller (`cloud03-controller01`) as user `ansible`

---

## 1. What is Preflight Verification and Why is it Necessary?

Deploying a multi-node OpenStack private cloud involves pulling gigabytes of container images, creating virtual networking bridges, formatting distributed storage volumes, and starting clustered databases.

If an operator launches an OpenStack deployment without verifying hardware prerequisites, a misconfigured network card or disabled CPU virtualization setting in BIOS will cause the installation to crash 30–60 minutes in, leaving behind corrupted or partially-configured systems.

**Preflight (`00-preflight.yml`) is a 100% read-only verification playbook.** It makes zero changes to your servers. It acts as an automated "pre-flight checklist" to guarantee that every physical node, network interface, and kernel flag satisfies the cluster requirements before touching production systems.

---

## 2. Task-by-Task Technical Breakdown

Here is what `ansible-playbook 00-preflight.yml` verifies across the cluster:

### A. Hostname Contract (`ansible_hostname == inventory_hostname`)
* **Task:** Validates that the active operating system hostname matches the inventory name defined in `ansible/inventory.yml`:
  * `cloud03-controller01`
  * `cloud03-compute01`
  * `cloud03-compute02`
  * `cloud03-compute03`
* **Why it matters:** Clustered OpenStack services—specifically **MariaDB Galera** (state database) and **RabbitMQ** (inter-service message bus)—rely on node hostnames for peer discovery and quorum. If inventory names do not match actual hostnames, clustering will fail immediately.

---

### B. Hardware Virtualization Flags (`VT-x` / `AMD-V`)
* **Task:** Executes `grep -Ec 'vmx|svm' /proc/cpuinfo` on all 3 compute nodes:
  * `vmx` indicates Intel VT-x hardware virtualization.
  * `svm` indicates AMD-V hardware virtualization.
* **Why it matters:** OpenStack Nova uses **KVM (Kernel-based Virtual Machine)** as its hypervisor. If virtualization is disabled in BIOS/UEFI, Nova is forced to emulate CPU instructions via QEMU, reducing guest VM performance by 10x to 50x or outright failing VM creation.

---

### C. Physical NIC Verification (`eno1`)
* **Task:** Checks that physical Ethernet card `eno1` exists, is UP, and has a physical link carrier (`cat /sys/class/net/eno1/carrier == 1`).
* **Why it matters:** In subsequent steps (`01-network.yml`), 7 802.1Q tagged VLAN sub-interfaces (`mgmt`, `storage`, `tunnel`, `api`, `egress`, `provider`, `dns`) are attached directly to `eno1`. A missing or misspelled interface name would break all network provisioning.

---

### D. Default Route Conflict Check
* **Task:** Scans active routing tables (`ip -4 route show default`) on compute nodes.
* **Why it matters:** Compute nodes must not have existing default gateways on their physical Ethernet interfaces. Later, OpenStack provisions a unified floating default gateway (`10.12.0.1` via Controller VRRP). Existing default gateways create dual-route conflicts that disrupt traffic egress.

---

### E. Gateway Uplink Verification (`enx522f1af8028a`)
* **Task:** Verifies that the Controller's internet uplink interface is detected, active, and has an outbound IPv4 route.
* **Why it matters:** In our topology, the Controller acts as the NAT gateway for the 3 compute nodes. Compute nodes download packages and Docker containers through this uplink.

---

### F. Hardware Capacity Summary
* **Task:** Queries hardware specifications and displays a per-node summary:
  * Total vCPU cores and processor architecture.
  * Total installed system RAM (in MB).
  * Available free disk space on root `/` (in GB).
  * Firewall status (`ufw`).

---

## 3. How to Run the Preflight Playbook

Run directly from the **Controller PC (`cloud03-controller01`)**:

```bash
cd ~/Cloud-Project/ansible
ansible-playbook 00-preflight.yml
```

*(Note: Because the `ansible` user was created with passwordless sudo (`NOPASSWD: ALL`), no `-K` or sudo password is required).*

---

## 4. Understanding the Play Recap Output

When preflight succeeds, Ansible outputs:

```text
PLAY RECAP *****************************************************************************************************************************************************************************
cloud03-compute01          : ok=9    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
cloud03-compute02          : ok=9    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
cloud03-compute03          : ok=9    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
cloud03-controller01       : ok=11   changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

* **`changed=0`**: Proves the playbook made zero destructive changes.
* **`failed=0`**: Confirms all 4 machines satisfy all hardware, CPU, and networking requirements for OpenStack.

---

## 5. Common Preflight Failure Modes Encountered & Solutions

| Failure | Root Cause | Solution |
| :--- | :--- | :--- |
| **`Hostname must equal inventory name`** | Machine hostname was left default or swapped. | Force update hostname: `echo "<name>" \| sudo tee /etc/hostname && sudo hostname <name>` |
| **`Cannot find device enx...`** | USB tethering interface name changed after phone reconnection. | Run `ip -br link`, find current interface name, and update `wifi_if` in `ansible/inventory.yml`. |
| **`REMOTE HOST IDENTIFICATION CHANGED`** | Old host key cached after IP reassignment. | Purge old cached key: `ssh-keygen -R 192.168.0.x`. |
| **`Virtualisation flags failed`** | Intel VT-x or AMD-V disabled in BIOS. | Reboot PC, enter BIOS/UEFI, enable Intel Virtualization Technology (VT-x) or AMD-V. |
