# OpenStack Lab: L2 Managed Switch Configuration & Architecture Guide
**Switch Hardware:** D-Link DGS-1210-28 (28-Port Gigabit Smart Managed Switch)  
**Cluster Architecture:** 4 Physical Nodes (1 Controller Node + 3 Compute Nodes)  
**Deployment Platform:** OpenStack (CloudShift / Kolla-Ansible)

---

## 1. Why an L2 Managed Switch is Essential in OpenStack

In a traditional home or small office network, devices plug into an unmanaged ("dumb") switch or router where all network traffic shares a single, flat broadcast domain. 

In an enterprise private cloud running OpenStack, an unmanaged switch will fail for two fundamental reasons:

### A. Traffic Congestion & Storage Starvation
* When virtual machines read or write to their virtual hard disks, massive volumes of disk I/O are transmitted across the network to distributed storage (GlusterFS).
* During VM live migration, gigabytes of active RAM state are transferred between compute nodes in seconds.
* On an unmanaged switch, this massive data flood shares the same bandwidth with database queries, API requests, and web traffic. MariaDB and RabbitMQ time out, causing the OpenStack control plane to crash.

### B. Security & Tenant Isolation
* Cloud tenants (users creating virtual machines) must never have access to the underlying management network.
* On a flat network, a compromised virtual machine could sniff unencrypted database credentials, intercept Keystone authentication tokens, or execute ARP spoofing attacks against the cloud infrastructure.

### The Solution: 802.1Q VLAN Trunking
Instead of purchasing **7 separate physical switches** and installing **7 physical Ethernet cards in every server**, an **L2 Managed Switch** allows us to slice a single physical switch into **7 isolated virtual switches**. 

Using **802.1Q VLAN Trunking**, all 7 isolated networks travel across **a single physical Ethernet cable per PC**.

```
+-----------------------------------------------------------------------------------+
|                           D-Link DGS-1210-28 Switch                               |
|   [Port 1: Trunk]      [Port 2: Trunk]      [Port 3: Trunk]      [Port 4: Trunk]  |
+---------|-------------------|--------------------|--------------------|-----------+
          |                   |                    |                    |
   Controller 01         Compute 01           Compute 02           Compute 03
  (192.168.0.11)        (192.168.0.21)       (192.168.0.22)       (192.168.0.23)
  + Internet Uplink
```

---

## 2. Physical Port Assignments

| Switch Port | Node Role | Hostname | Native (Untagged) | 802.1Q Tagged VLANs |
| :--- | :--- | :--- | :--- | :--- |
| **Port 1** | **Controller** (Control plane, DB, GlusterFS, Gateway) | `cloud03-controller01` | **VLAN 1** | `10, 20, 30, 40, 50, 60, 70` |
| **Port 2** | **Compute 01** (Nova hypervisor, VMs) | `cloud03-compute01` | **VLAN 1** | `10, 20, 30, 40, 50, 60, 70` |
| **Port 3** | **Compute 02** (Nova hypervisor, VMs) | `cloud03-compute02` | **VLAN 1** | `10, 20, 30, 40, 50, 60, 70` |
| **Port 4** | **Compute 03** (Nova hypervisor, VMs) | `cloud03-compute03` | **VLAN 1** | `10, 20, 30, 40, 50, 60, 70` |
| **Ports 5–28** | Unused / Management Spares | — | **VLAN 1** | None (Excluded) |

*Note: The Controller node requires an independent internet uplink (Wi-Fi or secondary Ethernet card) to act as the cluster NAT gateway. Never plug the upstream home/campus router into the 16/28-port switch.*

---

## 3. The 7 Cluster VLANs Explained

| VLAN ID | Name | Subnet / CIDR | Purpose & Role in OpenStack |
| :---: | :--- | :--- | :--- |
| **1** | **NATIVE** | `192.168.0.0/24` | **Physical Management:** Base untagged network used for server installation, initial SSH, Ansible automation bootstrap, and switch web administration (`192.168.0.1`). |
| **10** | **MGMT** | `10.0.10.0/24` | **Control Plane & APIs:** High-priority internal traffic: MariaDB Galera database replication, RabbitMQ message queues, Keystone tokens, and live-migration memory transport. (VIP: `10.0.10.100`). |
| **20** | **STORAGE**| `10.0.20.0/24` | **GlusterFS Storage Network:** High-bandwidth disk I/O network where VM disks (`/var/lib/nova-shared`) and Glance cloud images are stored and replicated. Completely isolated from API traffic. |
| **30** | **TUNNEL** | `10.11.10.0/24` | **VXLAN Tenant Overlays:** Encapsulated virtual overlay networks created by tenants. VM-to-VM traffic across hosts travels here without leaking into host networks. |
| **40** | **API** | `10.14.40.0/24` | **External API & Web UI:** Public Virtual IP where users access the Horizon web dashboard (`http://10.14.40.100`) and administrators access Grafana metrics (`http://10.14.40.100:3000`). |
| **50** | **EGRESS** | `10.12.0.0/24` | **Cluster Outbound Routing:** The default route (`10.12.0.1`) that compute nodes use to reach the internet via the Controller's VRRP/NAT gateway. |
| **60** | **PROVIDER**| `172.24.4.0/24` | **Floating IPs (Public Access):** External Neutron provider network (`physnet1` / `br-ex`). Allows external users to SSH into tenant VMs assigned floating IPs. |
| **70** | **DNS** | `10.0.70.0/24` | **Internal Lab DNS:** Redundant cluster domain name resolution (`dnsmasq`) hosted on the Controller node (`10.0.70.11`). |

---

## 4. What is PVID and Why Keep PVID = 1?

* **PVID (Port VLAN ID)**: Dictates which VLAN untagged incoming packets are placed into.
* **Why PVID = 1 for all ports:** When clean Linux servers boot, their physical network cards do not have VLAN sub-interfaces yet. Leaving PVID 1 as untagged allows every node to immediately obtain its `192.168.0.x` IP address and communicate over SSH without requiring prior VLAN configuration on the OS.

---

## 5. D-Link DGS-1210-28 Step-by-Step Configuration Walkthrough

### Step 1: Initial Switch Access (Factory Defaults)
* **Default Switch IP:** `10.90.90.90`
* **Default Subnet Mask:** `255.0.0.0`
* **Default Credentials:** Username: `admin`, Password: *(blank or `admin`)*

On your PC, assign a temporary IP in the factory range:
```bash
sudo ip addr add 10.90.90.91/24 dev eno1
sudo ip link set eno1 up
```
*(Caution: Never assign `10.90.90.90` to your PC; that creates an IP conflict where your computer loops traffic back to itself).*

Access `http://10.90.90.90` in your web browser.

---

### Step 2: Set Switch Permanent Management IP
In the D-Link Web Interface:
1. Navigate to **System** $\rightarrow$ **IPv4 Interface** (or **System Settings**).
2. Set the following:
   * **Mode:** `Static`
   * **IP Address:** `192.168.0.1`
   * **Subnet Mask:** `255.255.255.0` (CIDR `/24`)
   * **Gateway:** `192.168.0.1` *(Gateway subnet must match the IP subnet)*
3. Click **Apply**.
4. Log back in at `http://192.168.0.1` using admin credentials.

---

### Step 3: Create the 7 802.1Q VLANs
1. Go to **L2 Functions** (or **VLAN**) $\rightarrow$ **802.1Q VLAN**.
2. Ensure **802.1Q VLAN State** is **Enabled**.
3. Click **Add / Edit VLAN** and add each of the 7 VLANs:

| VID | Name | Ports 1, 2, 3, 4 | Ports 5–28 |
| :---: | :--- | :---: | :---: |
| **10** | `MGMT` | **Tagged (T)** | Excluded / Not Member |
| **20** | `STORAGE` | **Tagged (T)** | Excluded / Not Member |
| **30** | `TUNNEL` | **Tagged (T)** | Excluded / Not Member |
| **40** | `API` | **Tagged (T)** | Excluded / Not Member |
| **50** | `EGRESS` | **Tagged (T)** | Excluded / Not Member |
| **60** | `PROVIDER` | **Tagged (T)** | Excluded / Not Member |
| **70** | `DNS` | **Tagged (T)** | Excluded / Not Member |

---

### Step 4: Verify Port PVID Settings
1. Navigate to **VLAN** $\rightarrow$ **VLAN Port Settings** (or **802.1Q PVID Settings**).
2. Confirm that **Ports 1 through 28** remain set to **PVID = 1**.
3. Click **Apply**.

---

### Step 5: Save Configuration to NVRAM (Permanent Memory)
> [!IMPORTANT]
> D-Link switches only apply changes to volatile RAM by default. If the switch loses power, uncommitted changes are wiped.
1. Click **Save** in the top navigation bar or left sidebar.
2. Select **Save Configuration** (or Save to NVRAM).
3. Click **Apply / Save**.

---

## 6. Key Troubleshooting Commands

* **Check if physical link is detected (Carrier):**
  ```bash
  cat /sys/class/net/eno1/carrier
  # 1 = Connected, 0 = Cable unplugged or port down
  ```

* **Listen for switch broadcast packets (ignoring host noise):**
  ```bash
  sudo tcpdump -i eno1 -n "not host 192.168.1.11 and not arp" -c 5
  ```

* **Reset Switch to Factory Defaults:**
  With the switch powered on, insert a pin into the front-panel **Reset** pinhole and hold for **10 to 12 seconds** until all port LEDs flash simultaneously.
