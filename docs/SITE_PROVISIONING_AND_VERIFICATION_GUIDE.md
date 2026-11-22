# OpenStack Lab: Site Provisioning & Verification Guide (`site.yml`)
**Platform:** 4-Node OpenStack Cluster (1 Controller + 3 Compute Nodes)  
**Main Orchestrator:** `ansible/site.yml`  
**Execution Context:** Run from Controller (`cloud03-controller01`) as user `ansible`

---

## 1. Overview of `site.yml`

While `00-preflight.yml` was a read-only audit, **`site.yml` is the foundational provisioning engine of the CloudShift private cloud**. It transforms bare Linux servers and an L2 managed switch into a production-grade, enterprise cloud infrastructure.

`site.yml` sequentially executes **4 major sub-playbooks**:

```
                  site.yml Execution Pipeline
                             |
         +-------------------+-------------------+
         |                                       |
  [01-network.yml]                      [02-gateway-dns.yml]
  7 Tagged 802.1Q VLANs                 VRRP Floating Gateway (10.12.0.1)
  Hostnames & /etc/hosts                dnsmasq Cluster DNS (10.0.70.11)
  Clean Stray Routes                    NAT Internet Sharing (iptables)
         |                                       |
         +-------------------+-------------------+
                             |
         +-------------------+-------------------+
         |                                       |
  [03-storage.yml]                      [04-verify.yml]
  GlusterFS Distributed Volumes         Full VLAN & IP Ping Matrix
  Mount /var/lib/nova-shared            DNS Resolution & Uplink Check
  Docker Storage Dependencies           /dev/kvm Hardware Acceleration
```

---

## 2. Stage-by-Stage Breakdown & Component Importance

---

### STAGE 1: Network & VLAN Provisioning (`01-network.yml`)

#### What it does:
1. **Removes Stray Routes & Default Gateways:** Cleans legacy Netplan files and removes rogue default gateways on physical NICs to avoid multi-homed routing conflicts.
2. **Generates Standardized Host Resolution (`/etc/hosts`):** Writes cluster DNS mappings across all 4 nodes (`cloud03-controller01`, `cloud03-compute01`, etc.) so services never depend on external DNS to locate peers.
3. **Carves 7 802.1Q Tagged VLAN Sub-Interfaces (`60-cloud03-vlans.yaml`):**
   * **`mgmt` (VLAN 10):** `10.0.10.x/24` (Internal APIs, MariaDB, RabbitMQ, SSH, VM migration)
   * **`storage` (VLAN 20):** `10.0.20.x/24` (GlusterFS storage data replication)
   * **`tunnel` (VLAN 30):** `10.11.10.x/24` (Tenant VXLAN overlay networks)
   * **`api` (VLAN 40):** `10.14.40.x/24` (Public VIP, Horizon Dashboard, Grafana)
   * **`egress` (VLAN 50):** `10.12.0.x/24` (Cluster internet egress through gateway)
   * **`provider` (VLAN 60):** `172.24.4.x/24` (Neutron external floating IP network on `br-ex`)
   * **`dns` (VLAN 70):** `10.0.70.x/24` (Internal cluster DNS server)
4. **Applies Netplan & Verifies Carrier:** Verifies every VLAN interface is in the `UP` state with link carrier.

#### Why it is critical:
Without strict Layer-2 VLAN segregation, storage disk writes would flood the management API, and tenant virtual machines could intercept internal database queries or RabbitMQ messages.

---

### STAGE 2: Gateway & Cluster DNS (`02-gateway-dns.yml`)

#### What it does:
1. **Persistent IP Forwarding:** Enables `net.ipv4.ip_forward = 1` in `/etc/sysctl.d/99-lab-gateway.conf`.
2. **Automated NAT Masquerading:** Configures `iptables` NAT rules via `lab-gateway.service` so traffic arriving from compute nodes on VLAN 50 (`10.12.0.0/24`) is masqueraded out through the Controller's tethering interface (`enx522f1af8028a`).
3. **Keepalived VRRP Floating Gateway (`10.12.0.1`):** 
   * Deploys Keepalived with VRRP instance `LAB_GATEWAY`.
   * Binds the floating default route `10.12.0.1` to the Controller's `egress` interface.
   * Tracks tethering uplink health with `/usr/local/sbin/gw-check.sh`.
4. **Provider Network Reconciler (`provider-gateway.service`):** Configures `172.24.4.1` on `br-ex` so tenant VMs with floating IPs can route to the internet.
5. **Cluster DNS Server (`dnsmasq`):**
   * Deploys `dnsmasq` on the Controller listening on VLAN 70 (`10.0.70.11`).
   * Configures local zone `cloud03.lab` and forwards external queries to upstream resolvers (`1.1.1.1`, `8.8.8.8`).

#### Why it is critical:
Compute nodes have no direct internet connections. Without this floating VRRP gateway and internal DNS server, compute nodes could never pull Docker containers or resolve OpenStack internal endpoints (`api.cloud03.lab`).

---

### STAGE 3: GlusterFS Shared Storage (`03-storage.yml`)

#### What it does:
1. **Verifies Dedicated Storage Disk:** Ensures `/srv/gluster` is mounted on a dedicated partition/disk (`/dev/sdb`), refusing to place disk images on the OS root filesystem.
2. **Creates 3 Clustered Volumes:**
   * **`nova`**: Mounted at `/var/lib/nova-shared` across **all compute nodes** (stores VM disks).
   * **`glance`**: Mounted at `/var/lib/glance-shared` on the **Controller** (stores OS images).
   * **`gnocchi`**: Mounted at `/var/lib/gnocchi-shared` on the **Controller** (stores billing/telemetry metrics).
3. **High-Performance KVM/QEMU Disk Tuning:**
   * `performance.strict-o-direct on`: Forces direct I/O, bypassing double-caching between Linux and KVM.
   * `network.remote-dio disable`: Optimizes network direct I/O for virtual disks.
   * `performance.read-ahead off` & `io-cache off`: Prevents latency spikes on random disk reads.
4. **Failsafe Immutable Mount Points (`+i`):**
   * Marks unmounted mount points immutable using `chattr +i`.
   * **Why:** If network storage ever drops, services fail loudly with an error rather than silently writing gigabytes of data to the local boot disk.
5. **Docker Service Boot Ordering:**
   * Configures `docker.service.d/10-shared-storage.conf` (`RequiresMountsFor=/var/lib/nova-shared`).
   * Guarantees Docker and Nova containers never start until GlusterFS storage is successfully mounted.

#### Why it is critical:
This shared storage volume is the foundational requirement for **zero-downtime live migration**. When an instance moves from Compute 01 to Compute 02, zero disk blocks are copied across the network—only CPU registers and RAM states migrate.

---

### STAGE 4: Automated Verification Suite (`04-verify.yml`)

#### What it checks:
1. **Full-Mesh VLAN Ping Matrix:**
   Pings the Controller across every isolated network interface:
   * Ping over `mgmt` (`10.0.10.11`)
   * Ping over `storage` (`10.0.20.11`)
   * Ping over `tunnel` (`10.11.10.11`)
   * Ping over `dns` (`10.0.70.11`)
   * Ping over `egress` (`10.12.0.11`)
2. **Name Resolution (`getent hosts`):** Verifies all node names resolve locally.
3. **DNS Server Responsiveness:** Executes `dig` against `10.0.70.11` to ensure cluster records resolve under 2 seconds.
4. **Outbound Internet Egress (Compute Nodes):** Confirms all 3 compute nodes can reach `1.1.1.1` and resolve `ubuntu.com` through the Controller gateway.
5. **KVM Virtualization Acceleration (`/dev/kvm`):** Confirms the Linux KVM kernel module is loaded on all compute nodes.
6. **GlusterFS Mount Integrity:** Verifies `/var/lib/nova-shared` is actively mounted as type `glusterfs` on all compute hosts.

---

## 3. Summary of Accomplishment

By running `ansible-playbook site.yml`, your cluster achieved:
* **7 Isolated Virtual Networks** running cleanly across a single physical switch.
* **Autonomous Internet Routing** for isolated compute nodes.
* **Centralized Cluster DNS** resolving local cloud domains.
* **High-Performance Shared Storage** ready for instant VM live migration.
* **100% Automated Verification** proving all subsystems are operational.
