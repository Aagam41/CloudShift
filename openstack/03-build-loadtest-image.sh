#!/usr/bin/env bash
# Build a CPU-heavy Ubuntu cloud image and upload it to Glance.
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-loadtest}"
BASE_URL="${BASE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
BASE_IMAGE="${BASE_IMAGE:-/tmp/noble-server-cloudimg-amd64.img}"
WORKDIR="${WORKDIR:-/tmp/loadtest-image}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa.pub}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need virt-customize
need virt-sysprep
need qemu-img
need wget

mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ ! -f "$BASE_IMAGE" ]; then
  wget -O "$BASE_IMAGE" "$BASE_URL"
fi

IMAGE="$WORKDIR/loadtest.qcow2"
cp "$BASE_IMAGE" "$IMAGE"
qemu-img resize "$IMAGE" 10G

cat > "$WORKDIR/vm-load.sh" <<'EOF'
#!/bin/sh
exec stress-ng --cpu "$(nproc)" --cpu-load 80 --timeout 0
EOF

cat > "$WORKDIR/vm-details.py" <<'PY'
#!/usr/bin/env python3
import http.server
import json
import platform
import socket
import time
from urllib.parse import urlparse

import psutil

COUNTER = 0
MEMORY_BLOCKS = []
MAX_BLOCKS = 256

def cpu_model():
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or "unknown"

def ip_addresses():
    addresses = []
    for addrs in psutil.net_if_addrs().values():
        for addr in addrs:
            if addr.family == socket.AF_INET and not addr.address.startswith("127."):
                addresses.append(addr.address)
    return sorted(set(addresses))

def system_info():
    mem = psutil.virtual_memory()
    return {
        "hostname": socket.gethostname(),
        "ips": ip_addresses(),
        "cpu_model": cpu_model(),
        "vcpus": psutil.cpu_count(logical=True) or 1,
        "cpu_percent": psutil.cpu_percent(interval=0.2),
        "memory_total_mb": mem.total // (1024 * 1024),
        "memory_used_mb": mem.used // (1024 * 1024),
        "memory_percent": mem.percent,
        "uptime_seconds": int(time.time() - psutil.boot_time()),
        "counter": COUNTER,
        "allocated_mib": len(MEMORY_BLOCKS),
    }

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/increment":
            global COUNTER, MEMORY_BLOCKS
            COUNTER += 1
            if len(MEMORY_BLOCKS) < MAX_BLOCKS:
                MEMORY_BLOCKS.append(bytearray(1024 * 1024))
            self.send_json(system_info())
            return

        if parsed.path == "/status":
            self.send_json(system_info())
            return

        info = system_info()
        body = f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="2">
  <title>VM details</title>
</head>
<body>
  <h1>VM details</h1>
  <p><strong>Hostname:</strong> {info['hostname']}</p>
  <p><strong>IP addresses:</strong> {", ".join(info['ips']) or "none"}</p>
  <p><strong>CPU model:</strong> {info['cpu_model']}</p>
  <p><strong>vCPUs:</strong> {info['vcpus']}</p>
  <p><strong>CPU usage:</strong> {info['cpu_percent']}%</p>
  <p><strong>Memory:</strong> {info['memory_used_mb']} / {info['memory_total_mb']} MiB ({info['memory_percent']}%)</p>
  <p><strong>Uptime:</strong> {info['uptime_seconds']} seconds</p>
  <p><strong>Counter:</strong> {info['counter']}</p>
  <p><strong>Allocated memory:</strong> {info['allocated_mib']} MiB</p>
  <p><a href="/increment">Increment memory</a></p>
</body>
</html>
"""
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body.encode())))
        self.end_headers()
        self.wfile.write(body.encode())

    def send_json(self, data):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        return

if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("0.0.0.0", 80), Handler).serve_forever()
PY

cat > "$WORKDIR/vm-load.service" <<'EOF'
[Unit]
Description=CPU load generator
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/vm-load.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat > "$WORKDIR/vm-web.service" <<'EOF'
[Unit]
Description=VM details web service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/vm-details.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# libguestfs needs to read the host kernel, which is root-only on Ubuntu.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
else
  SUDO=(sudo)
fi

"${SUDO[@]}" virt-customize -a "$IMAGE" \
  --install python3,python3-psutil,stress-ng \
  --upload "$WORKDIR/vm-load.sh:/usr/local/bin/vm-load.sh" \
  --upload "$WORKDIR/vm-details.py:/usr/local/bin/vm-details.py" \
  --upload "$WORKDIR/vm-load.service:/etc/systemd/system/vm-load.service" \
  --upload "$WORKDIR/vm-web.service:/etc/systemd/system/vm-web.service" \
  --run-command 'chmod 0755 /usr/local/bin/vm-load.sh /usr/local/bin/vm-details.py' \
  --run-command 'systemctl enable vm-load.service vm-web.service' \
  --ssh-inject root:file:"$SSH_KEY" \
  --root-password disabled

"${SUDO[@]}" virt-sysprep -a "$IMAGE"

# Keep the resulting image owned by the invoking user so the later OpenStack
# upload does not require root privileges.
if [ "$(id -u)" -ne 0 ]; then
  sudo chown "$(id -u):$(id -g)" "$IMAGE"
fi

source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh

if openstack image show "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "Image '$IMAGE_NAME' already exists. Delete it first if you want to replace it."
  exit 0
fi

openstack image create "$IMAGE_NAME" \
  --file "$IMAGE" \
  --disk-format qcow2 \
  --container-format bare \
  --public

echo "Uploaded image: $IMAGE_NAME"
EOF