# OpenStack Lab: Storage Architecture & GlusterFS Preparation Guide
**Platform:** 4-Node OpenStack Cluster (1 Controller + 3 Compute Nodes)  
**Dedicated Storage Drive:** `/dev/sdb` (932 GB / 1 TB XFS) on `cloud03-controller01`  
**Shared Mount Point:** `/srv/gluster`

---

## 1. Architectural Question: Shared Storage vs. Local Storage

> **Question:** On the Controller node there is 1 TB of dedicated storage, but the 3 compute nodes also have 512 GB or 1 TB drives. Are we wasting that storage by centralizing GlusterFS on the Controller?

### The Short Answer:
**No, that storage is not wasted.** The compute nodes actively use their local drives for the OS, container engines, and local caching. Meanwhile, centralizing shared storage on the Controller enables **near-instant zero-downtime VM live migration**.

---

## 2. Shared Storage vs. Local Disk Trade-Offs

The primary feature of an enterprise OpenStack cloud is **Zero-Downtime Live Migration**.

### Scenario A: Local Storage on Compute Nodes (Block Migration)
If a virtual machine's 30 GB virtual hard drive was stored locally on Compute 01's internal disk:
* When an administrator needs to move that running VM to Compute 02 (for host maintenance or hardware upgrades), the hypervisor must copy **all 30,000 MB** of disk blocks across the network while the VM is active.
* This takes several minutes, saturates the network, places massive read/write load on both CPUs, and frequently causes the guest operating system to freeze, drop TCP connections, or time out.

### Scenario B: Centralized Shared GlusterFS Storage (Shared Storage Migration)
* The VM’s virtual disk (`disk.qcow2`) lives on the Controller's 1 TB drive under `/srv/gluster/nova`.
* Both Compute 01 and Compute 02 mount this exact same directory at `/var/lib/nova-shared` over the dedicated Storage network (VLAN 20).
* When migrating a running VM from Compute 01 $\longrightarrow$ Compute 02:
  * **Zero hard drive data needs to be transferred.**
  * Only the active RAM state (a few hundred megabytes) is synchronized across the Management network (VLAN 10).
  * The migration completes in **2 to 3 seconds** with zero dropped packets and no downtime.

---

## 3. What the Compute Nodes' Storage is Used For

The 512 GB to 1 TB local hard drives on Compute 01, 02, and 03 are actively utilized:

1. **Base Operating System & Kernels:**
   Ubuntu Server, system binaries, updates, and swap space (~25 GB).
2. **Kolla-Ansible Container Images:**
   Nova Compute, Neutron Open vSwitch agents, Prometheus Node Exporter, and logging containers (~30 GB).
3. **Local Glance Image Cache:**
   When a VM is launched, Nova caches the base CirrOS / Ubuntu cloud image locally so future instances spawn in seconds without re-downloading from Glance.
4. **Local Ephemeral Disks:**
   If a tenant launches an instance with the `flavor` configured for local ephemeral storage, Nova dynamically carves out scratch space directly on that compute node's local filesystem (`/var/lib/nova/instances`).

---

## 4. Why Not Merge All Drives Together? (Hyper-Converged Storage)

In massive multi-rack cloud environments, engineers sometimes implement **Hyper-Converged Infrastructure (HCI)** using **Ceph** or **Distributed GlusterFS** across all nodes (e.g. $1\text{ TB} + 1\text{ TB} + 1\text{ TB} = 3\text{ TB}$).

However, in small-to-medium clusters:
* Running distributed storage daemons on compute nodes steals CPU cycles, RAM, and disk I/O from tenant virtual machines.
* Centralizing the storage cluster on the **Controller node** keeps compute nodes 100% focused on running guest workloads at maximum performance.
* 1,000 GB on the Controller easily accommodates **50 to 100+ virtual machines** using thin-provisioned `qcow2` disks (which only consume actual written space, ~5–15 GB per VM).

---

## 5. GlusterFS Preparation Runbook Executed on Controller

On `cloud03-controller01`, the dedicated secondary disk (`/dev/sdb`) was prepared and mounted as follows:

```bash
# 1. Format /dev/sdb as XFS with 512-byte inodes (GlusterFS standard for extended attributes):
sudo mkfs.xfs -f -i size=512 /dev/sdb

# 2. Create the brick root mount directory:
sudo mkdir -p /srv/gluster

# 3. Add to /etc/fstab for persistent mount across reboots:
UUID=$(sudo blkid -s UUID -o value /dev/sdb)
echo "UUID=$UUID /srv/gluster xfs defaults 0 0" | sudo tee -a /etc/fstab

# 4. Mount all filesystems:
sudo mount -a

# 5. Verify mount and available capacity:
df -h /srv/gluster
```

Output confirmed:
```text
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdb        932G   18G  914G   2% /srv/gluster
```

---

## 6. The 3 GlusterFS OpenStack Volumes

In `ansible/03-storage.yml`, three dedicated GlusterFS volumes are initialized from `/srv/gluster`:

| Volume Name | Brick Path | Mount Location | Client Nodes | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **`nova`** | `/srv/gluster/nova/brick` | `/var/lib/nova-shared` | **Compute Nodes** | Shared virtual machine disks (`disk.qcow2`) for zero-downtime live migration. |
| **`glance`** | `/srv/gluster/glance/brick` | `/var/lib/glance-shared` | **Controller** | Shared cloud image repository (CirrOS, Ubuntu, Debian images). |
| **`gnocchi`** | `/srv/gluster/gnocchi/brick` | `/var/lib/gnocchi-shared` | **Controller** | Time-series telemetry and cloud resource billing metrics. |
