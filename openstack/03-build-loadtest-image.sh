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

cat > "$WORKDIR/vm-load.py" <<'PY'
#!/usr/bin/env python3
import os
import threading
import time

# Keep every vCPU busy about 80% of the time without needing stress-ng.
def worker():
    while True:
        start = time.monotonic()
        while time.monotonic() - start < 0.8:
            pass
        time.sleep(0.2)

for _ in range(os.cpu_count() or 1):
    threading.Thread(target=worker, daemon=True).start()

while True:
    time.sleep(3600)
PY

cat > "$WORKDIR/vm-details.py" <<'PY'
#!/usr/bin/env python3
import http.server
import json
import os
import platform
import socket
import subprocess
import time
from urllib.parse import urlparse

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
    try:
        output = subprocess.check_output(
            ["ip", "-4", "-o", "addr", "show"], text=True, stderr=subprocess.DEVNULL
        )
        for line in output.splitlines():
            fields = line.split()
            if "inet" in fields:
                address = fields[fields.index("inet") + 1].split("/")[0]
                if not address.startswith("127."):
                    addresses.append(address)
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    return sorted(set(addresses))

def read_meminfo():
    values = {}
    with open("/proc/meminfo", encoding="utf-8") as f:
        for line in f:
            key, value = line.split(":", 1)
            values[key] = int(value.split()[0])
    return values

def cpu_times():
    with open("/proc/stat", encoding="utf-8") as f:
        fields = f.readline().split()
    values = [int(value) for value in fields[1:]]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return idle, sum(values)

def cpu_percent():
    idle_before, total_before = cpu_times()
    time.sleep(0.2)
    idle_after, total_after = cpu_times()
    delta_total = total_after - total_before
    if delta_total <= 0:
        return 0.0
    delta_idle = idle_after - idle_before
    return round(100.0 * (1 - delta_idle / delta_total), 1)

def system_info():
    mem = read_meminfo()
    total_kb = mem["MemTotal"]
    available_kb = mem.get("MemAvailable", mem.get("MemFree", 0))
    used_kb = total_kb - available_kb
    percent = (used_kb / total_kb * 100) if total_kb else 0.0
    with open("/proc/uptime", encoding="utf-8") as f:
        uptime = int(float(f.read().split()[0]))

    return {
        "hostname": socket.gethostname(),
        "ips": ip_addresses(),
        "cpu_model": cpu_model(),
        "vcpus": os.cpu_count() or 1,
        "cpu_percent": cpu_percent(),
        "memory_total_mb": total_kb // 1024,
        "memory_used_mb": used_kb // 1024,
        "memory_percent": round(percent, 1),
        "uptime_seconds": uptime,
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
ExecStart=/usr/bin/python3 /usr/local/bin/vm-load.py
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
  --upload "$WORKDIR/vm-load.py:/usr/local/bin/vm-load.py" \
  --upload "$WORKDIR/vm-details.py:/usr/local/bin/vm-details.py" \
  --upload "$WORKDIR/vm-load.service:/etc/systemd/system/vm-load.service" \
  --upload "$WORKDIR/vm-web.service:/etc/systemd/system/vm-web.service" \
  --run-command 'chmod 0755 /usr/local/bin/vm-load.py /usr/local/bin/vm-details.py' \
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