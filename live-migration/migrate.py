#!/usr/bin/env python3
"""Simple live migration helper (Nova API through openstacksdk).

  migrate.py --list                      compute hosts and how many VMs each one runs
  migrate.py VM                          move VM to the least-loaded other compute host
  migrate.py VM --to cloud03-compute02   move VM to a specific host
  migrate.py --drain cloud03-compute01   move every ACTIVE VM off a host (before maintenance)
  add --dry-run to print what would happen without migrating

VM disks are on shared GlusterFS storage, so only memory is copied (no block migration).
Import it too:  from migrate import connect, compute_hosts, vms_by_host, migrate_vm
"""
import argparse
import os
import sys
import time

import openstack

CLOUD = os.environ.get("OS_CLOUD", "kolla-admin")   # entry in ~/.config/openstack/clouds.yaml
TIMEOUT = 900                                       # seconds to wait for one migration


def connect():
    return openstack.connect(cloud=CLOUD)


def compute_hosts(conn):
    """Names of the compute hosts that are enabled and up."""
    return sorted(s.host for s in conn.compute.services(binary="nova-compute")
                  if s.status == "enabled" and s.state == "up")


def vms_by_host(conn):
    """{host: [servers]} for every usable compute host (all projects)."""
    result = {h: [] for h in compute_hosts(conn)}
    for server in conn.compute.servers(details=True, all_projects=True):
        if server.compute_host in result:
            result[server.compute_host].append(server)
    return result


def least_loaded(conn, exclude):
    """Usable host (not `exclude`) running the fewest VMs. Change this to change the choice."""
    load = {h: len(v) for h, v in vms_by_host(conn).items() if h != exclude}
    if not load:
        raise SystemExit(f"no other usable compute host (excluding {exclude})")
    return min(load, key=load.get)


def migrate_vm(conn, vm, dest, dry_run=False):
    """Live-migrate one VM and wait for it. Returns True on success, False if it failed or rolled back."""
    vm = conn.compute.get_server(vm.id)               # fresh copy with the current host/status
    src = vm.compute_host
    if vm.status != "ACTIVE":
        print(f"{vm.name}: status is {vm.status}, only ACTIVE VMs are live-migrated")
        return False
    if src == dest:
        print(f"{vm.name}: already on {dest}")
        return False
    if dest not in compute_hosts(conn):
        print(f"{vm.name}: {dest} is not an enabled, up compute host")
        return False

    print(f"{vm.name}: {src} -> {dest}" + ("   (dry run)" if dry_run else ""))
    if dry_run:
        return True

    conn.compute.live_migrate_server(vm, host=dest, block_migration=False)   # force=False: Nova checks dest has room
    start = time.time()
    time.sleep(3)                                     # give Nova time to switch the VM to MIGRATING
    while time.time() - start < TIMEOUT:
        now = conn.compute.get_server(vm.id)
        if now.status == "ERROR":
            print(f"{vm.name}: ERROR during migration - check nova-compute logs on {src} and {dest}")
            return False
        if now.status == "ACTIVE" and now.compute_host == dest:
            print(f"{vm.name}: done in {time.time() - start:.0f}s")
            return True
        if now.status == "ACTIVE" and now.compute_host == src and time.time() - start > 30:
            print(f"{vm.name}: rolled back, still on {src} - check nova-compute logs on {src} and {dest}")
            return False
        time.sleep(5)
    print(f"{vm.name}: timed out after {TIMEOUT}s")
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vm", nargs="?", help="server name or ID")
    ap.add_argument("--to", metavar="HOST", help="destination compute host")
    ap.add_argument("--list", action="store_true", help="show compute hosts and their VM counts")
    ap.add_argument("--drain", metavar="HOST", help="migrate all ACTIVE VMs away from HOST")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    conn = connect()

    if args.list:
        for host, vms in vms_by_host(conn).items():
            print(f"{host:26} {len(vms):3} VMs  " + ", ".join(v.name for v in vms))
        return 0

    if args.drain:
        failed = 0
        for vm in [v for v in vms_by_host(conn).get(args.drain, []) if v.status == "ACTIVE"]:
            failed += not migrate_vm(conn, vm, least_loaded(conn, exclude=args.drain), args.dry_run)
        print("drain finished" + (f", {failed} VM(s) could not be moved" if failed else ""))
        return 1 if failed else 0

    if not args.vm:
        ap.error("give a VM, or use --list / --drain")
    vm = conn.compute.find_server(args.vm, ignore_missing=False, all_projects=True)
    dest = args.to or least_loaded(conn, exclude=conn.compute.get_server(vm.id).compute_host)
    return 0 if migrate_vm(conn, vm, dest, args.dry_run) else 1


if __name__ == "__main__":
    sys.exit(main())
