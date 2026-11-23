#!/usr/bin/env bash
# CloudKitty pricing. Costs apply PER HOUR (the collection period), in arbitrary "credits". Edit the numbers.
# Kolla's CloudKitty API exposes only the v1 rating API, so every call is forced to v1.
# Re-running this script is safe: services/fields are reused and mappings are recreated.
set -euo pipefail
source ~/kolla-venv/bin/activate
source /etc/kolla/admin-openrc.sh

rating() { openstack --rating-api-version 1 rating "$@"; }

rating module enable hashmap >/dev/null 2>&1 || true
rating module set priority hashmap 100 >/dev/null 2>&1 || true

# --- helpers: get-or-create, parsed via JSON so differing CLI column names do not break us ---
svc() {  # print id of a hashmap service, creating it if needed
    local name="$1" id
    id=$(rating hashmap service list -f json 2>/dev/null | NAME="$name" python3 -c '
import sys, json, os
name = os.environ["NAME"]
def walk(o):
    if isinstance(o, list):
        for it in o: yield from walk(it)
    elif isinstance(o, dict):
        if (o.get("Name") or o.get("name")) == name:
            yield o.get("Service ID") or o.get("service_id") or o.get("id") or ""
        for v in o.values():
            yield from walk(v)
try: data = json.load(sys.stdin)
except Exception: data = []
for v in walk(data):
    if v:
        print(v); break
')
    if [ -z "$id" ]; then
        id=$(rating hashmap service create "$name" -f json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print(d.get("Service ID") or d.get("service_id") or d.get("id") or "")
')
    fi
    [ -n "$id" ] || { echo "ERROR: could not get/create service '$name'" >&2; return 1; }
    echo "$id"
}

field_id() {  # print id of a field on a service, creating it if needed
    local svc_id="$1" name="$2" fid
    fid=$(rating hashmap field list "$svc_id" -f json 2>/dev/null | NAME="$name" python3 -c '
import sys, json, os
name = os.environ["NAME"]
def walk(o):
    if isinstance(o, list):
        for it in o: yield from walk(it)
    elif isinstance(o, dict):
        if (o.get("Name") or o.get("name")) == name:
            yield o.get("Field ID") or o.get("field_id") or o.get("id") or ""
        for v in o.values():
            yield from walk(v)
try: data = json.load(sys.stdin)
except Exception: data = []
for v in walk(data):
    if v:
        print(v); break
')
    if [ -z "$fid" ]; then
        fid=$(rating hashmap field create "$svc_id" "$name" -f json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print(d.get("Field ID") or d.get("field_id") or d.get("id") or "")
')
    fi
    echo "$fid"
}

clear_mappings() {  # delete all mappings of a service (best effort)
    local svc_id="$1"
    rating hashmap mapping list -s "$svc_id" -f json 2>/dev/null | python3 -c '
import sys, json
def walk(o):
    if isinstance(o, list):
        for it in o: yield from walk(it)
    elif isinstance(o, dict):
        mid = o.get("Mapping ID") or o.get("mapping_id") or o.get("id")
        if mid: yield mid
        for v in o.values():
            yield from walk(v)
try: data = json.load(sys.stdin)
except Exception: data = []
for mid in walk(data):
    print(mid)
' | while read -r mid; do
        rating hashmap mapping delete "$mid" >/dev/null 2>&1 || true
    done
}

# --- Instances: per-flavor pricing is only effective when Ceilometer pushes flavor attributes ---
# (libvirt inspector does not, so a default flat mapping is also created for charges to appear now).
S=$(svc instance)
F=$(field_id "$S" flavor_name)
clear_mappings "$S"
if [ -n "$F" ]; then
    # Per-flavor rules (active only when Gnocchi instance resources carry flavor_name).
    rating hashmap mapping create --field-id "$F" --value m1.tiny   --type flat 1.5 >/dev/null 2>&1 || true
    rating hashmap mapping create --field-id "$F" --value m1.small  --type flat 2.5 >/dev/null 2>&1 || true
    rating hashmap mapping create --field-id "$F" --value c1.medium --type flat 4.5 >/dev/null 2>&1 || true
    rating hashmap mapping create --field-id "$F" --value c1.large  --type flat 8.5 >/dev/null 2>&1 || true
fi
# Default fallback so charges appear with the libvirt inspector (no flavor attributes).
rating hashmap mapping create --service-id "$S" --type flat 2.5 >/dev/null 2>&1 || true

# --- Other services: default (no-field) flat rate ---
rating hashmap mapping create --service-id "$(svc volume.size)" --type flat 2.5 >/dev/null 2>&1 || true   # per GiB-hour
rating hashmap mapping create --service-id "$(svc ip.floating)" --type flat 5.0 >/dev/null 2>&1 || true    # per floating IP-hour
rating hashmap mapping create --service-id "$(svc network.outgoing.bytes)" --type flat 1.5 >/dev/null 2>&1 || true  # per MB sent
rating hashmap mapping create --service-id "$(svc image.size)" --type flat 2.0 >/dev/null 2>&1 || true      # per MiB-hour

# --- Verify mappings actually exist ---
INST_MAPS=$(rating hashmap mapping list -s "$S" -f json 2>/dev/null | python3 -c '
import sys, json
def walk(o):
    if isinstance(o, list): 
        for it in o: yield from walk(it)
    elif isinstance(o, dict):
        mid = o.get("Mapping ID") or o.get("mapping_id") or o.get("id")
        if mid: yield mid
        for v in o.values(): yield from walk(v)
try: data = json.load(sys.stdin)
except Exception: data = []
print(sum(1 for _ in walk(data)))
')
if [ "${INST_MAPS:-0}" = "0" ]; then
    echo "ERROR: no mappings created for the instance service - billing will produce zero charges" >&2
    exit 1
fi

echo "Billing rates configured. Instance mappings: $INST_MAPS"
rating hashmap service list
