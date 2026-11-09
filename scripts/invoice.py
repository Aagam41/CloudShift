#!/usr/bin/env python3
"""Monthly invoice per client from CloudKitty.   ~/kolla-venv/bin/python invoice.py --month 2026-10 --out inv.csv
Check the raw API response once (see README) if the columns differ on your release."""
import argparse
import csv
import datetime as dt

import openstack

ap = argparse.ArgumentParser()
ap.add_argument("--month", required=True, help="YYYY-MM")
ap.add_argument("--cloud", default="kolla-admin")
ap.add_argument("--out", default="invoice.csv")
a = ap.parse_args()

y, m = map(int, a.month.split("-"))
begin, end = dt.datetime(y, m, 1), dt.datetime(y + (m == 12), m % 12 + 1, 1)
conn = openstack.connect(cloud=a.cloud)
names = {p.id: p.name for p in conn.identity.projects()}
r = conn.session.get("/v2/summary", endpoint_filter={"service_type": "rating", "interface": "internal"},
                     params={"begin": begin.isoformat(), "end": end.isoformat(), "groupby": "project_id,type"})
r.raise_for_status()
data = r.json()
rows = data["results"]
if rows and not isinstance(rows[0], dict):
    rows = [dict(zip(data["columns"], x)) for x in rows]

totals = {}
with open(a.out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["client", "service", "quantity", "cost"])
    for x in sorted(rows, key=lambda x: (names.get(x["project_id"], ""), x["type"])):
        client = names.get(x["project_id"], x["project_id"])
        w.writerow([client, x["type"], round(float(x["qty"]), 4), round(float(x["rate"]), 4)])
        totals[client] = totals.get(client, 0) + float(x["rate"])
    w.writerow([])
    for client, total in sorted(totals.items()):
        w.writerow([client, "TOTAL", "", round(total, 4)])
for client, total in sorted(totals.items()):
    print(f"{client:20} {total:10.2f}")
print("written", a.out)
