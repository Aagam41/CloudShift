# Reaching the cloud from your laptop

Your laptop is on your home network (192.168.1.0/24), not on the lab VLANs. Any controller with Wi-Fi forwards traffic for you
(`/usr/local/sbin/lab-gateway.sh`): add routes on the laptop that point at that controller's address on YOUR network
(its Wi-Fi IP, 192.168.1.x, shown by `ssh <controller> 'ip -br a show wlp2s0'`). If that controller is down, use another controller's Wi-Fi IP.

| OS      | Command |
|---------|---------|
| Linux   | `sudo ip route add 10.14.40.0/24 via <controller01-wifi-ip>` and `sudo ip route add 172.24.4.0/24 via <controller01-wifi-ip>` |
| macOS   | `sudo route add -net 10.14.40.0/24 <ip>` and `sudo route add -net 172.24.4.0/24 <ip>` |
| Windows | `route add 192.168.1.0 mask 255.255.255.0 <ip>` and `route add 172.24.4.0 mask 255.255.255.0 <ip>` (admin shell) |

The lab uses 10.0.10/20/70.0, 10.11.10.0, 10.12.0.0, 10.14.40.0 (all /24), 172.24.4.0/24 and 192.168.0.0/24, so a home network of
192.168.1.0/24 does not clash. The preflight checks this against the real Wi-Fi network.

| What | URL | Login |
|------|-----|-------|
| Horizon (dashboard) | http://10.14.40.100 | domain `Default`, user `admin`, password = `keystone_admin_password` |
| Grafana | http://10.14.40.100:3000 | `admin` / `grafana_admin_password` |
| Prometheus | http://10.14.40.100:9091 | `admin` / `prometheus_password` |
| VM floating IPs | 172.24.4.100-199 | `ssh cirros@172.24.4.x` (key `mykey.pem`) |

Passwords: `grep -E '^(keystone_admin|grafana_admin|prometheus)_password' /etc/kolla/passwords.yml` on controller01.

## Without routes: SSH tunnels (nothing to configure on the laptop)
```
ssh -L 8080:10.0.10.100:80 -L 3000:10.0.10.100:3000 -L 9091:10.0.10.100:9091 user@<any-controller-wifi-ip>
```
then http://localhost:8080 (Horizon), http://localhost:3000 (Grafana). The VM console (noVNC) opens a
10.14.40.100 address, so the console needs the route method.
