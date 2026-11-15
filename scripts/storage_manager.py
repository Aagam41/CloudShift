#!/usr/bin/env python3
"""Interactive GlusterFS storage selection for one CloudShift controller.

Usage:
    ./storage-manager.sh controller01
    python3 scripts/storage_manager.py controller01

The script:
  1. runs ansible/03a-prepare-glusterfs.yml in discovery mode on exactly one node,
  2. displays a complete storage inventory,
  3. asks the administrator to choose a device and an operation,
  4. writes an extra-vars file,
  5. runs ansible/03a-prepare-gluster-disk.yml with those variables.

Nothing is modified during discovery. Every destructive step requires
explicit confirmation, and formatting or repurposing requires a second
confirmation.
"""

import argparse
import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANSIBLE_DIR = os.path.join(REPO_ROOT, "ansible")
INVENTORY = "inventory.yml"
PLAYBOOK = "03a-prepare-glusterfs.yml"
MOUNT_POINT = "/srv/gluster"
CRITICAL_MOUNTS = ["/", "/boot", "/boot/efi"]
SPECIAL_TYPES = {"swap", "LVM2_member", "crypto_LUKS", "linux_raid_member"}


def run_interactive(command, cwd):
    """Run a command that may prompt the user (ansible -K)."""
    result = subprocess.run(command, cwd=cwd)
    if result.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(command)}")


def run_capture(command, cwd):
    """Run a command and return its stdout as text."""
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(command)}\n{result.stderr}")
    return result.stdout


def resolve_node(node):
    """Accept a full or short host name and return the inventory name."""
    raw = run_capture(["ansible-inventory", "-i", INVENTORY, "--list"], ANSIBLE_DIR)
    inventory = json.loads(raw)
    hosts = sorted(inventory.get("_meta", {}).get("hostvars", {}).keys())
    if node in hosts:
        return node
    prefixed = f"cloud03-{node}"
    if prefixed in hosts:
        return prefixed
    matches = [h for h in hosts if h.endswith(node)]
    if len(matches) == 1:
        return matches[0]
    raise SystemExit(f"could not resolve node '{node}' in the inventory")


def discover(node):
    """Run the read-only discovery playbook and return the JSON inventory."""
    print(f"\nDiscovering storage on {node} (read-only)...\n")
    run_interactive(
        ["ansible-playbook", "-i", INVENTORY, PLAYBOOK, "-l", node, "-e", "discover_mode=true"],
        ANSIBLE_DIR,
    )
    path = f"/tmp/{node}-storage.json"
    if not os.path.exists(path):
        raise SystemExit(f"discovery did not create {path}")
    with open(path) as fh:
        return json.load(fh)


def parse_size(text):
    """Parse a parted/lsblk size string such as 123B, 1.5TB or 500G into bytes."""
    if text is None:
        return 0
    text = str(text).strip()
    match = re.match(r"^([0-9]+(?:\.[0-9]+)?)\s*([BKMGTP]?)(?:B|IB)?$", text, re.I)
    if not match:
        return 0
    number = float(match.group(1))
    suffix = (match.group(2) or "B").upper()
    multiplier = {"B": 1, "K": 1024, "M": 1024**2, "G": 1024**3,
                  "T": 1024**4, "P": 1024**5}[suffix]
    return int(number * multiplier)


def human_size(size):
    """Return a human-readable size string."""
    size = float(size)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB", "PiB"):
        if size < 1024 or unit == "PiB":
            if unit == "B":
                return f"{int(size)} B"
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} PiB"


def parse_requested_size(text):
    """Parse an administrator-supplied size such as 250G, 1.5T or all."""
    text = text.strip().lower()
    if text in ("all", "max", "100%"):
        return "all"
    match = re.match(r"^([0-9]+(?:\.[0-9]+)?)\s*([bkmgtp])$", text)
    if not match:
        return None
    number = float(match.group(1))
    suffix = match.group(2).upper()
    multiplier = {"B": 1, "K": 1024, "M": 1024**2, "G": 1024**3,
                  "T": 1024**4, "P": 1024**5}[suffix]
    return int(number * multiplier)


def flatten_lsblk(devices, parent=None):
    """Flatten lsblk's nested block devices into a list of dicts."""
    flat = []
    for dev in devices or []:
        item = dict(dev)
        item["parent"] = parent
        flat.append(item)
        flat.extend(flatten_lsblk(dev.get("children", []), dev.get("name")))
    return flat


def flatten_findmnt(filesystems):
    """Flatten findmnt's nested filesystems into a list of dicts."""
    flat = []
    for fs in filesystems or []:
        flat.append(fs)
        flat.extend(flatten_findmnt(fs.get("children", [])))
    return flat


def build_inventory(raw):
    """Turn the discovery JSON into disk, partition, mount and free-space lists."""
    lsblk = raw["lsblk"]
    findmnt = raw.get("findmnt", {})
    blkid_raw = raw.get("blkid", "") or ""
    df_raw = raw.get("df", "") or ""

    blkid = {}
    if blkid_raw.strip():
        try:
            blkid_data = json.loads(blkid_raw)
            if isinstance(blkid_data, list):
                devices = blkid_data
            elif isinstance(blkid_data, dict):
                devices = blkid_data.get("blockdevices", [])
            else:
                devices = []
            for dev in devices:
                name = dev.get("name") or os.path.basename(dev.get("device", ""))
                if name:
                    blkid[name] = dev
        except json.JSONDecodeError:
            blkid = {}

    mounts_by_source = {}
    for fs in flatten_findmnt(findmnt.get("filesystems", [])):
        source = fs.get("source", "")
        target = fs.get("target", "")
        if source and not source.startswith("/dev/"):
            source = "/dev/" + source
        if source:
            mounts_by_source[source] = target

    df_rows = []
    for line in df_raw.splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 6:
            df_rows.append({
                "source": fields[0],
                "target": fields[1],
                "fstype": fields[2],
                "size": int(fields[3]),
                "used": int(fields[4]),
                "avail": int(fields[5]),
            })

    flat_devices = flatten_lsblk(lsblk.get("blockdevices", []))
    disks = []
    partitions = []
    disk_names = raw.get("disk_names", [])

    for index, name in enumerate(disk_names):
        disk_info = next((d for d in flat_devices if d.get("name") == name), {})
        parted_raw = raw.get("parted_outputs", [])[index] if index < len(raw.get("parted_outputs", [])) else "{}"
        try:
            parted = json.loads(parted_raw) if parted_raw.strip() else {}
        except json.JSONDecodeError:
            parted = {}
        disk = parted.get("disk", {})
        parted_parts = disk.get("partitions", [])
        free_regions = [p for p in parted_parts if p.get("type") == "free"]
        total = parse_size(disk.get("size")) or parse_size(disk_info.get("size"))
        unallocated = sum(parse_size(p.get("size")) for p in free_regions)
        allocated = max(total - unallocated, 0)

        disks.append({
            "name": name,
            "path": f"/dev/{name}",
            "model": disk_info.get("model", "") or disk.get("model", ""),
            "serial": disk_info.get("serial", ""),
            "size": total,
            "label": disk.get("label", ""),
            "allocated": allocated,
            "unallocated": unallocated,
            "free_regions": free_regions,
            "rotational": bool(disk_info.get("rota", 0)),
            "removable": bool(disk_info.get("rm", 0)),
        })

    for dev in flat_devices:
        if dev.get("type") != "part":
            continue
        name = dev.get("name", "")
        path = dev.get("path", f"/dev/{name}")
        blk = blkid.get(name, {})
        fstype = dev.get("fstype") or blk.get("type") or ""
        mountpoint = mounts_by_source.get(path, "")
        special = fstype in SPECIAL_TYPES
        children = dev.get("children", []) or []
        child_types = {c.get("type", "") for c in children}
        if child_types & {"lvm", "crypt", "raid"}:
            special = True
        partitions.append({
            "name": name,
            "path": path,
            "parent": dev.get("pkname") or dev.get("parent") or "",
            "size": parse_size(dev.get("size")),
            "fstype": fstype,
            "uuid": dev.get("uuid") or blk.get("uuid") or "",
            "label": dev.get("label") or blk.get("label") or "",
            "mountpoint": mountpoint,
            "mounted": bool(mountpoint),
            "special": special,
            "critical": mountpoint in CRITICAL_MOUNTS or fstype == "swap",
        })

    current_gluster = next((p for p in partitions if p["mountpoint"] == MOUNT_POINT), None)
    return {
        "node": raw.get("node", ""),
        "disks": disks,
        "partitions": partitions,
        "mounts": df_rows,
        "current_gluster": current_gluster,
    }


def display_inventory(inv):
    """Print the storage inventory tables."""
    print("=" * 72)
    print(f"NODE: {inv['node']}")
    print("=" * 72)

    print("\nPhysical disk inventory")
    print("-" * 72)
    print(f"{'Disk':<12} {'Total':>10} {'Allocated':>12} {'Unallocated':>12}  Model")
    for d in inv["disks"]:
        print(f"{d['path']:<12} {human_size(d['size']):>10} "
              f"{human_size(d['allocated']):>12} {human_size(d['unallocated']):>12}  {d['model']}")

    print("\nPartition inventory")
    print("-" * 72)
    print(f"{'Partition':<16} {'Size':>10} {'Filesystem':<10} {'Mount point':<20} Status")
    for p in inv["partitions"]:
        status = "Mounted" if p["mounted"] else "Unmounted"
        if p["special"]:
            status += " (special)"
        print(f"{p['path']:<16} {human_size(p['size']):>10} "
              f"{p['fstype'] or '-':<10} {p['mountpoint'] or '-':<20} {status}")

    print("\nMounted filesystem usage")
    print("-" * 72)
    print(f"{'Source':<20} {'Mount':<20} {'Total':>10} {'Used':>10} {'Free':>10}")
    for m in inv["mounts"]:
        print(f"{m['source']:<20} {m['target']:<20} "
              f"{human_size(m['size']):>10} {human_size(m['used']):>10} {human_size(m['avail']):>10}")

    if inv["current_gluster"]:
        print(f"\nCurrent {MOUNT_POINT}: {inv['current_gluster']['path']} "
              f"({inv['current_gluster']['fstype']})")
    else:
        print(f"\nCurrent {MOUNT_POINT}: not mounted")
    print()


def dedicated_disk_required():
    """Read the dedicated-disk setting from the deploy host."""
    path = os.path.join(REPO_ROOT, "ansible", "group_vars", "all.yml")
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("gluster_require_dedicated_disk:"):
                    value = line.split(":", 1)[1].split("#", 1)[0].strip().lower()
                    return value == "true"
    except FileNotFoundError:
        return False
    return False


def build_candidates(inv):
    """Build the list of selectable storage candidates."""
    candidates = []
    for d in inv["disks"]:
        if d["unallocated"] > 0:
            candidates.append({
                "type": "unallocated",
                "disk": d,
                "description": f"{d['path']} - {human_size(d['unallocated'])} unallocated",
            })
    for p in inv["partitions"]:
        if p["special"] or p["critical"]:
            continue
        if not p["mounted"]:
            candidates.append({
                "type": "unmounted",
                "partition": p,
                "description": f"{p['path']} - {human_size(p['size'])} {p['fstype'] or 'unformatted'}, unmounted",
            })
    if inv["current_gluster"]:
        candidates.append({
            "type": "current_gluster",
            "partition": inv["current_gluster"],
            "description": f"{inv['current_gluster']['path']} - current {MOUNT_POINT} mount",
        })
    for p in inv["partitions"]:
        if p["special"] or p["critical"] or not p["mounted"]:
            continue
        if p["mountpoint"] == MOUNT_POINT:
            continue
        candidates.append({
            "type": "mounted",
            "partition": p,
            "description": f"{p['path']} - {human_size(p['size'])} {p['fstype']}, mounted at {p['mountpoint']}",
        })

    if not dedicated_disk_required():
        candidates.append({
            "type": "root",
            "description": f"Use {MOUNT_POINT} on the root filesystem (no dedicated disk)",
        })
    return candidates


def prompt(text):
    """Prompt the user and return the trimmed answer."""
    try:
        return input(text).strip()
    except EOFError:
        return ""


def confirm(question, default=False):
    """Ask a yes/no question."""
    suffix = " [y/N] " if not default else " [Y/n] "
    answer = prompt(question + suffix).lower()
    if not answer:
        return default
    return answer in ("y", "yes")


def choose_candidate(candidates):
    """Show the candidate list and let the administrator choose one."""
    print("=" * 72)
    print("GLUSTERFS STORAGE CONFIGURATION")
    print("=" * 72)
    print("\nAvailable storage candidates:\n")
    for index, cand in enumerate(candidates, start=1):
        print(f"{index}. {cand['description']}")
    while True:
        answer = prompt("\nSelect storage candidate (number, or blank to cancel): ")
        if not answer:
            return None
        if answer.isdigit() and 1 <= int(answer) <= len(candidates):
            return candidates[int(answer) - 1]
        print("Invalid selection.")


def choose_unallocated_action(candidate):
    """Choose how to use unallocated space on a disk."""
    disk = candidate["disk"]
    print(f"\nSelected disk: {disk['path']}")
    print(f"Unallocated space: {human_size(disk['unallocated'])}\n")
    print("1. Use all available unallocated space.")
    print("2. Specify a custom partition size.")
    print("3. Leave the unallocated space untouched.")
    while True:
        choice = prompt("Your selection: ")
        if choice == "1":
            return {"action": "create_partition", "size": "all", "disk": disk, "format": True}
        if choice == "2":
            while True:
                size_text = prompt("Enter size (for example 250G, 1.5T): ")
                size = parse_requested_size(size_text)
                if size is None:
                    print("Could not parse the size.")
                    continue
                if size <= 0:
                    print("Size must be positive.")
                    continue
                if size > disk["unallocated"]:
                    print(f"Requested size exceeds the available {human_size(disk['unallocated'])}.")
                    continue
                return {"action": "create_partition", "size": f"+{size_text.upper()}", "disk": disk, "format": True}
        if choice == "3":
            return None
        print("Invalid selection.")


def choose_unmounted_action(candidate):
    """Choose how to use an unmounted partition."""
    part = candidate["partition"]
    print(f"\nSelected partition: {part['path']}")
    print(f"Capacity: {human_size(part['size'])}")
    print(f"Existing filesystem: {part['fstype'] or 'none'}")
    print(f"UUID: {part['uuid'] or 'unknown'}")
    print("\nWARNING: formatting destroys all data on the partition.\n")
    print("1. Format as XFS and use it for GlusterFS.")
    print("2. Preserve the existing filesystem and mount it at /srv/gluster.")
    print("3. Leave the partition untouched.")
    while True:
        choice = prompt("Your selection: ")
        if choice == "1":
            return {"action": "use_existing", "device": part["path"], "format": True, "old_mount": ""}
        if choice == "2":
            if not part["fstype"]:
                print("Cannot preserve a partition without a filesystem.")
                continue
            return {"action": "use_existing", "device": part["path"], "format": False, "old_mount": ""}
        if choice == "3":
            return None
        print("Invalid selection.")


def choose_current_gluster_action(candidate):
    """Choose what to do with the current /srv/gluster mount."""
    part = candidate["partition"]
    print(f"\nCurrent GlusterFS partition: {part['path']}")
    print(f"Filesystem: {part['fstype']}")
    print(f"Size: {human_size(part['size'])}\n")
    print("1. Keep the existing configuration (verify mount and fstab).")
    print("2. Inspect the filesystem.")
    print("3. Reformat the partition (destructive).")
    print("4. Skip.")
    while True:
        choice = prompt("Your selection: ")
        if choice == "1":
            return {"action": "use_existing", "device": part["path"], "format": False, "old_mount": ""}
        if choice == "2":
            print("Inspection is informational only; no changes will be made.")
            return None
        if choice == "3":
            return {"action": "use_existing", "device": part["path"], "format": True, "old_mount": ""}
        if choice == "4":
            return None
        print("Invalid selection.")


def choose_mounted_action(candidate):
    """Choose what to do with a mounted data partition."""
    part = candidate["partition"]
    print(f"\nSelected mounted partition: {part['path']}")
    print(f"Current mount point: {part['mountpoint']}")
    print(f"Filesystem: {part['fstype']}")
    print(f"Size: {human_size(part['size'])}\n")
    print("1. Keep the existing configuration.")
    print("2. Inspect the filesystem.")
    print("3. Repurpose this partition for /srv/gluster (advanced).")
    print("4. Skip.")
    while True:
        choice = prompt("Your selection: ")
        if choice == "1":
            return None
        if choice == "2":
            print("Inspection is informational only; no changes will be made.")
            return None
        if choice == "3":
            print("\nWARNING: repurposing will unmount this partition from its current mount point.")
            if not confirm("Continue with repurposing?", default=False):
                return None
            print("1. Reformat as XFS (destructive).")
            print("2. Preserve the existing filesystem.")
            sub = prompt("Your selection: ")
            if sub == "1":
                return {"action": "use_existing", "device": part["path"], "format": True,
                        "old_mount": part["mountpoint"]}
            if sub == "2":
                if not part["fstype"]:
                    print("Cannot preserve a partition without a filesystem.")
                    continue
                return {"action": "use_existing", "device": part["path"], "format": False,
                        "old_mount": part["mountpoint"]}
            print("Invalid selection.")
            continue
        if choice == "4":
            return None
        print("Invalid selection.")


def choose_root_action():
    """Choose whether to use the root filesystem for /srv/gluster."""
    print("\nNo dedicated storage candidate was selected.")
    print(f"Use {MOUNT_POINT} on the root filesystem? This stores VM data on the OS disk.")
    if not confirm("Use the root filesystem for /srv/gluster?", default=False):
        return None
    return {"action": "use_root"}


def build_plan(candidates):
    """Let the administrator choose a candidate and an operation."""
    candidate = choose_candidate(candidates)
    if candidate is None:
        return None
    if candidate["type"] == "unallocated":
        return choose_unallocated_action(candidate)
    if candidate["type"] == "unmounted":
        return choose_unmounted_action(candidate)
    if candidate["type"] == "current_gluster":
        return choose_current_gluster_action(candidate)
    if candidate["type"] == "mounted":
        return choose_mounted_action(candidate)
    if candidate["type"] == "root":
        return choose_root_action()
    return None


def preview_plan(node, plan):
    """Show the final configuration before execution."""
    print("\n" + "=" * 72)
    print("FINAL CONFIGURATION")
    print("=" * 72)
    print(f"Node: {node}")
    if plan["action"] == "create_partition":
        disk = plan["disk"]
        print(f"Physical disk: {disk['path']}")
        print(f"Total capacity: {human_size(disk['size'])}")
        print("Selected operation: create a new partition")
        print(f"Partition size: {plan['size']}")
        print("Remaining unallocated space stays untouched.")
    elif plan["action"] == "use_root":
        print("Selected operation: use /srv/gluster on the root filesystem")
        print("No dedicated disk will be used.")
    else:
        print(f"Selected partition: {plan['device']}")
        print("Selected operation: use existing partition")
        print(f"Format: {'yes (XFS)' if plan['format'] else 'no (preserve filesystem)'}")
        if plan["old_mount"]:
            print(f"Old mount point to remove: {plan['old_mount']}")
    print(f"Mount point: {MOUNT_POINT}")
    print("Existing partitions are never modified or resized.")
    print("=" * 72)


def extra_vars_for(node, plan):
    """Build the extra-vars dict for the apply playbook."""
    data = {
        "storage_action": plan["action"],
        "storage_parent_disk": plan["disk"]["path"] if plan["action"] == "create_partition" else "",
        "storage_device": plan.get("device", ""),
        "partition_size": plan.get("size", "all"),
        "format_device": bool(plan.get("format", False)),
        "old_mount_point": plan.get("old_mount", ""),
        "filesystem_type": "xfs",
        "mount_point": MOUNT_POINT,
        "approved": True,
        "use_root": plan["action"] == "use_root",
    }
    return data


def process_node(node, args):
    """Discover, select and apply storage for one node."""
    if args.mock:
        with open(args.mock) as fh:
            raw = json.load(fh)
        raw["node"] = raw.get("node", node)
    else:
        raw = discover(node)

    inv = build_inventory(raw)
    display_inventory(inv)
    candidates = build_candidates(inv)
    if not candidates:
        print("No safe storage candidates were found on this node.")
        return 0

    plan = build_plan(candidates)
    if plan is None:
        print("No storage changes were requested.")
        return 0

    preview_plan(node, plan)

    if not confirm("\nApply this configuration?", default=False):
        print("Cancelled. No storage changes were made.")
        return 0

    destructive = plan["action"] == "create_partition" or plan.get("format") or plan.get("old_mount")
    if destructive:
        if not confirm("This is a destructive operation. Type 'yes' to continue: ", default=False):
            print("Cancelled. No storage changes were made.")
            return 0

    extra = extra_vars_for(node, plan)
    extra_path = f"/tmp/{node}-gluster-extra-vars.json"
    with open(extra_path, "w") as fh:
        json.dump(extra, fh, indent=2)
    print(f"\nExtra vars written to {extra_path}")

    if args.dry_run:
        print("Dry run: not running the apply playbook.")
        print(json.dumps(extra, indent=2))
        return 0

    if not args.apply:
        print("\nConfiguration prepared.")
        print(f"Apply later with: cd ansible && ansible-playbook 03a-prepare-glusterfs.yml -l {node}")
        return 0

    print(f"\nApplying the configuration on {node}...\n")
    run_interactive(
        ["ansible-playbook", "-i", INVENTORY, PLAYBOOK,
         "-l", node, "-e", f"@{extra_path}", "-e", "approved=true"],
        ANSIBLE_DIR,
    )
    print(f"\nDone. Verify with: findmnt {MOUNT_POINT}")
    return 0


def main():
    if not sys.stdin.isatty():
        try:
            tty = open("/dev/tty", "r+")
            sys.stdin = tty
            sys.stdout = tty
            sys.stderr = tty
        except OSError:
            pass

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("node", nargs="?", help="controller name, for example controller01")
    parser.add_argument("--mock", help="use a mock discovery JSON file instead of Ansible")
    parser.add_argument("--dry-run", action="store_true",
                        help="show the extra vars and do not run the apply playbook")
    parser.add_argument("--apply", action="store_true",
                        help="also run the Ansible apply playbook immediately")
    args = parser.parse_args()

    if args.mock:
        node = args.node or "mock-node"
        return process_node(node, args)

    if args.node:
        node = resolve_node(args.node)
        return process_node(node, args)

    nodes = control_hosts()
    if not nodes:
        raise SystemExit("no control hosts found in the inventory")
    for node in nodes:
        print(f"\n{'=' * 72}")
        print(f"Node: {node}")
        print("=" * 72)
        if not confirm(f"Configure {node}?", default=False):
            print(f"Skipping {node}.")
            continue
        try:
            process_node(node, args)
        except SystemExit as exc:
            print(f"Failed on {node}: {exc}")
            return 1
    return 0


def control_hosts():
    raw = run_capture(["ansible-inventory", "-i", INVENTORY, "--list"], ANSIBLE_DIR)
    inventory = json.loads(raw)
    return inventory.get("control", {}).get("hosts", [])


if __name__ == "__main__":
    sys.exit(main())
