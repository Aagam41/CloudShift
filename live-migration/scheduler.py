#!/usr/bin/env python3
"""EXAMPLE scheduler: every `interval` seconds move one VM from the busiest compute host to the idlest.

CPU data comes from Prometheus, the migration itself from migrate.py.
This is where YOUR algorithm goes: edit pick_vm() (which VM?) and check() (when/where?).
Run with the Kolla venv:  ~/kolla-venv/bin/python scheduler.py      (dry_run: true in config.yaml at first)
"""
import logging
import os
import sys
import time

import requests
import yaml

import migrate

log = logging.getLogger("scheduler")
cfg = {}


# ---- Prometheus (Kolla puts basic auth on it: user "admin", password in passwords.yml) ----
def prometheus(query):
    password = os.environ.get("PROM_PASSWORD") or \
        yaml.safe_load(open("/etc/kolla/passwords.yml"))["prometheus_password"]
    r = requests.get(cfg["prometheus_url"] + "/api/v1/query", params={"query": query},
                     auth=("admin", password), timeout=15)
    r.raise_for_status()
    return r.json()["data"]["result"]


def per_host(query):
    """Run a query with one series per node -> {nova host name: value}."""
    names = {ip: host for host, ip in cfg["hosts"].items()}      # 'instance' label looks like "10.0.10.21:9100"
    out = {}
    for series in prometheus(query):
        host = names.get(series["metric"]["instance"].split(":")[0])
        if host:
            out[host] = float(series["value"][1])
    return out


# ---- Your algorithm ---------------------------------------------------------
def pick_vm(vms, diff):
    """vms: [(server, % of the busy host's CPU this VM uses)]; diff: busy CPU % - idle CPU %.
    Return the VM to move, or None.
    Default: the VM whose share is closest to diff/2, so both hosts end up level.
    Skips VMs under 1% (pointless) and VMs >= diff (would just flip the imbalance)."""
    candidates = [(s, pct) for s, pct in vms if 1 <= pct < diff]
    return min(candidates, key=lambda c: abs(c[1] - diff / 2))[0] if candidates else None


def check(conn):
    """One look at the cluster. Returns True if a migration was started."""
    usable = set(migrate.compute_hosts(conn))
    cpu = {h: v for h, v in per_host(
        '100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[2m])))').items() if h in usable}
    if len(cpu) < 2:
        log.warning("need CPU data for at least 2 usable hosts, got %s", cpu)
        return False

    busy, idle = max(cpu, key=cpu.get), min(cpu, key=cpu.get)
    diff = cpu[busy] - cpu[idle]
    log.info("cpu%% %s", {h.replace("cloud03-", ""): round(v) for h, v in cpu.items()})
    if diff < cfg["threshold"]:
        return False

    by_host = migrate.vms_by_host(conn)
    if any(s.status == "MIGRATING" for vms in by_host.values() for s in vms):
        return False                                             # one migration at a time

    cores = per_host('count by (instance) (node_cpu_seconds_total{mode="idle"})')[busy]
    used = {s["metric"]["domain"]: float(s["value"][1]) for s in prometheus(       # cores' worth of CPU per VM
        'sum by (domain) (rate(libvirt_domain_info_cpu_time_seconds_total[2m]))')}
    vms = [(s, 100 * used.get(s.instance_name, 0) / cores) for s in by_host[busy] if s.status == "ACTIVE"]

    vm = pick_vm(vms, diff)
    if vm is None:
        log.info("imbalance %.0f%% but no suitable VM", diff)
        return False
    if cfg["dry_run"]:
        log.info("[dry run] would move %s: %s -> %s", vm.name, busy, idle)
        return False
    return migrate.migrate_vm(conn, vm, idle)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    cfg.update(yaml.safe_load(open(sys.argv[1] if len(sys.argv) > 1 else "config.yaml")))
    conn = migrate.connect()
    last_migration = 0
    while True:
        if time.time() - last_migration >= cfg["cooldown"]:
            try:
                if check(conn):
                    last_migration = time.time()
            except Exception:
                log.exception("check failed")
        time.sleep(cfg["interval"])


if __name__ == "__main__":
    main()
