#!/usr/bin/env python3
"""cloud-exporter: Prometheus metrics that the node/libvirt exporters cannot know.

  cloud_vm_*                   one series per VM: name, project, host, flavor, status
                               (Grafana joins these onto libvirt's CPU/disk/network series by "domain")
  cloud_project_*              instances / vCPUs / RAM per project
  cloud_migrations_total       live-migration history from Nova
  cloud_billing_cost           month-to-date cost per project and service (from CloudKitty)

Runs on every controller (ansible/05-exporter.yml); each controller's Prometheus scrapes its local copy on port 9199.
Environment: OS_CLOUD (default kolla-admin), BIND (this controller's management IP), PORT (9199),
             RATING_INTERFACE (default internal)
"""
import datetime as dt
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import openstack

CLOUD = os.environ.get("OS_CLOUD", "kolla-admin")
BIND = os.environ.get("BIND", "10.0.10.11")
PORT = int(os.environ.get("PORT", "9199"))
RATING_INTERFACE = os.environ.get("RATING_INTERFACE", "internal")
NOVA_EVERY, BILLING_EVERY = 30, 300          # seconds

log = logging.getLogger("cloud-exporter")
output = {}                                   # source name -> rendered metric text
errors = {"nova": 0, "billing": 0}
last_ok = {}
lock = threading.Lock()


# ---- tiny Prometheus text-format writer -------------------------------------------------------
class Metrics:
    def __init__(self):
        self.meta, self.lines = {}, {}

    def add(self, name, kind, help_, labels, value):
        self.meta[name] = (kind, help_)
        lab = ",".join(f'{k}="{esc(v)}"' for k, v in labels.items())
        self.lines.setdefault(name, []).append(f"{name}{{{lab}}} {value}" if lab else f"{name} {value}")

    def render(self):
        out = []
        for name, lines in self.lines.items():
            kind, help_ = self.meta[name]
            out += [f"# HELP {name} {help_}", f"# TYPE {name} {kind}"] + lines
        return "\n".join(out) + "\n"


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


# ---- collectors ------------------------------------------------------------------------------
def collect_nova(conn):
    m = Metrics()
    projects = {p.id: p.name for p in conn.identity.projects()}
    per_project = {}
    for s in conn.compute.servers(details=True, all_projects=True):
        project = projects.get(s.project_id, s.project_id)
        flavor = s.flavor
        vcpus, ram = int(flavor.vcpus or 0), int(flavor.ram or 0)
        base = {"domain": s.instance_name or "", "name": s.name, "project": project, "host": s.compute_host or ""}
        m.add("cloud_vm_info", "gauge", "One series per VM", dict(base, id=s.id, status=s.status,
              flavor=flavor.original_name or flavor.name or ""), 1)
        m.add("cloud_vm_vcpus", "gauge", "vCPUs of the VM's flavor", base, vcpus)
        m.add("cloud_vm_ram_mb", "gauge", "RAM (MB) of the VM's flavor", base, ram)
        p = per_project.setdefault(project, {"instances": 0, "vcpus": 0, "ram": 0})
        p["instances"] += 1
        if s.status == "ACTIVE":
            p["vcpus"] += vcpus
            p["ram"] += ram
    for project, p in per_project.items():
        m.add("cloud_project_instances", "gauge", "VMs per project (any state)", {"project": project}, p["instances"])
        m.add("cloud_project_vcpus", "gauge", "vCPUs of ACTIVE VMs per project", {"project": project}, p["vcpus"])
        m.add("cloud_project_ram_mb", "gauge", "RAM (MB) of ACTIVE VMs per project", {"project": project}, p["ram"])

    counts = {}
    for mig in conn.compute.migrations():
        key = (mig.migration_type, mig.status, mig.source_compute, mig.dest_compute)
        counts[key] = counts.get(key, 0) + 1
    for (kind, status, src, dst), n in counts.items():
        m.add("cloud_migrations_total", "counter", "Nova migrations by type/status/source/destination",
              {"type": kind, "status": status, "source": src, "dest": dst}, n)
    return m.render()


def collect_billing(conn):
    """Month-to-date cost per project and service from the CloudKitty v2 summary API."""
    now = dt.datetime.now(dt.timezone.utc)
    begin = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    end = (begin + dt.timedelta(days=32)).replace(day=1)
    resp = conn.session.get("/v2/summary",
                            endpoint_filter={"service_type": "rating", "interface": RATING_INTERFACE},
                            params={"begin": begin.strftime("%Y-%m-%dT%H:%M:%S"),
                                    "end": end.strftime("%Y-%m-%dT%H:%M:%S"),
                                    "groupby": "project_id,type"})
    resp.raise_for_status()
    data = resp.json()
    rows = data["results"]
    if rows and not isinstance(rows[0], dict):                    # {"columns": [...], "results": [[...]]}
        rows = [dict(zip(data["columns"], r)) for r in rows]
    projects = {p.id: p.name for p in conn.identity.projects()}
    m = Metrics()
    for r in rows:
        labels = {"project": projects.get(r.get("project_id"), r.get("project_id", "")), "service": r.get("type", "")}
        m.add("cloud_billing_cost", "gauge", "Month-to-date cost (CloudKitty rating units)", labels, float(r["rate"]))
        m.add("cloud_billing_quantity", "gauge", "Month-to-date billed quantity", labels, float(r["qty"]))
    return m.render()


def loop(source, every, fn):
    conn = None
    while True:
        try:
            conn = conn or openstack.connect(cloud=CLOUD)
            text = fn(conn)
            with lock:
                output[source] = text
                last_ok[source] = time.time()
        except Exception:
            errors[source] += 1
            conn = None                                           # reconnect next time
            log.exception("%s collection failed", source)
        time.sleep(every)


def status_text():
    m = Metrics()
    for source in errors:
        m.add("cloud_exporter_errors_total", "counter", "Failed collections", {"source": source}, errors[source])
        if source in last_ok:
            m.add("cloud_exporter_last_success_timestamp_seconds", "gauge", "Last successful collection",
                  {"source": source}, int(last_ok[source]))
    return m.render()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(200); self.end_headers(); self.wfile.write(b"cloud-exporter: see /metrics\n"); return
        with lock:
            body = (status_text() + "".join(output.values())).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    for source, every, fn in (("nova", NOVA_EVERY, collect_nova), ("billing", BILLING_EVERY, collect_billing)):
        threading.Thread(target=loop, args=(source, every, fn), daemon=True).start()
    log.info("serving http://%s:%s/metrics (cloud=%s)", BIND, PORT, CLOUD)
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
