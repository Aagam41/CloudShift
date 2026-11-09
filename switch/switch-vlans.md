# Switch: TP-Link TL-SG2210P, 7 VLANs on 8 trunk ports

All 8 copper ports carry the same 7 tagged VLANs (a "trunk"). VLAN 1 stays the untagged/native VLAN so the
192.168.0.x addresses you SSH to today keep working while you configure the rest.

| Port | Node                    | Port | Node              |
|------|-------------------------|------|-------------------|
| 1    | cloud03-contorller01    | 5    | cloud03-compute02 |
| 2    | cloud03-contorller02    | 6    | cloud03-compute03 |
| 3    | cloud03-contorlcompute  | 7    | cloud03-compute04 |
| 4    | cloud03-compute01       | 8    | cloud03-compute05 |

(Any port order works. Ports 9-10 are SFP and unused.)

| VLAN | Name     | Subnet          | Used for                                   | Tagged ports |
|------|----------|-----------------|--------------------------------------------|--------------|
| 10   | MGMT     | 10.0.10.0/24    | API, RabbitMQ, MariaDB, SSH, migration     | 1-8 |
| 20   | STORAGE  | 10.0.20.0/24    | GlusterFS (VM disks, images, telemetry)    | 1-8 |
| 30   | TUNNEL   | 10.11.10.0/24   | VXLAN tenant networks                      | 1-8 |
| 40   | API      | 10.14.40.0/24   | External API VIP, Horizon (controllers)    | 1-8 |
| 50   | EGRESS   | 10.12.0.0/24    | Internet via the floating gateway (.1)     | 1-8 |
| 60   | PROVIDER | 172.24.4.0/24   | Floating IPs / provider network            | 1-8 |
| 70   | DNS      | 10.0.70.0/24    | Lab DNS (all 3 controllers)                | 1-8 |

VLAN 40 is only used by the three controllers but tagging it everywhere is harmless and keeps all ports identical.

## Web UI (default http://192.168.0.1, admin / admin)
1. VLAN > 802.1Q VLAN > Add. For each VLAN above: ID, name, **Tagged Ports 1-8**, Untagged Ports empty.
2. VLAN > 802.1Q VLAN PVID Setting: ports 1-8 keep PVID 1.
3. System > Save Config.

## CLI (use the web UI if your firmware rejects a command)
```
enable
configure
vlan 10
 name MGMT
vlan 20
 name STORAGE
vlan 30
 name TUNNEL
vlan 40
 name API
vlan 50
 name EGRESS
vlan 60
 name PROVIDER
vlan 70
 name DNS
exit
interface range gigabitEthernet 1/0/1-8
 switchport general allowed vlan 10,20,30,40,50,60,70 tagged
exit
end
copy running-config startup-config
```
Check afterwards: `show vlan` lists all 7 VLANs with ports 1-8 tagged.
No jumbo frames or special QoS needed. Do this BEFORE `ansible/01-network.yml`.
