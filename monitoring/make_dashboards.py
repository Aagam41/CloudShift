#!/usr/bin/env python3
"""Generates the Grafana dashboards into ../kolla/config/grafana/dashboards/ (Kolla provisions that folder).
Edit queries here, run `python3 make_dashboards.py`, then `kolla-ansible reconfigure -t grafana -i ~/multinode`."""
import json
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "kolla", "config", "grafana", "dashboards")
DS = {"type": "prometheus", "uid": "${ds}"}
JOIN = " * on(instance) group_left(nodename) node_uname_info"      # adds the host name to node_exporter series
VM = "cloud_vm_info{project=~\"$project\",host=~\"$host\"}"         # filtered VM list used for joins
VLANS = "mgmt|storage|tunnel|api|egress|provider|dns"


def cpu_pct(window="5m"):
    return "100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[%s])))" % window


def vm_rate(metric, by="domain"):
    return "sum by (%s) (rate(%s[5m]))" % (by, metric)


def per_vm(expr, labels="name, project, host", flt=VM):
    """Join a per-domain expression with VM names/projects."""
    return expr + " * on(domain) group_left(%s) %s" % (labels, flt)


class Dash:
    def __init__(self, uid, title, tags, variables=()):
        self.uid, self.title, self.tags = uid, title, tags
        self.panels, self._id = [], 0
        self.variables = [{"name": "ds", "label": "Data source", "type": "datasource", "query": "prometheus",
                           "refresh": 1, "hide": 0, "current": {}}]
        for name, label, query in variables:
            self.variables.append({
                "name": name, "label": label, "type": "query", "datasource": DS, "refresh": 2, "sort": 1,
                "query": {"query": query, "refId": "v_" + name}, "definition": query,
                "includeAll": True, "multi": True, "allValue": ".*",
                "current": {"selected": True, "text": ["All"], "value": ["$__all"]}})

    def _add(self, p, x, y, w, h):
        self._id += 1
        p.update(id=self._id, gridPos={"x": x, "y": y, "w": w, "h": h})
        self.panels.append(p)

    @staticmethod
    def _targets(targets, instant=False, table=False):
        out = []
        for i, t in enumerate(targets):
            expr, legend = t if isinstance(t, tuple) else (t, "")
            d = {"datasource": DS, "expr": expr, "legendFormat": legend, "refId": chr(65 + i)}
            if instant or table:
                d.update(instant=True, range=False)
            if table:
                d["format"] = "table"
            out.append(d)
        return out

    def row(self, title, y):
        self._add({"type": "row", "title": title, "collapsed": False, "panels": []}, 0, y, 24, 1)

    def text(self, content, x, y, w, h):
        self._add({"type": "text", "title": "", "options": {"mode": "markdown", "content": content}}, x, y, w, h)

    def ts(self, title, targets, x, y, w, h, unit="short", desc="", stack=False, maxv=None):
        custom = {"drawStyle": "line", "lineWidth": 1, "fillOpacity": 15 if stack else 8, "showPoints": "never",
                  "spanNulls": True, "stacking": {"mode": "normal" if stack else "none", "group": "A"}}
        defaults = {"unit": unit, "custom": custom}
        if maxv is not None:
            defaults["max"] = maxv
            defaults["min"] = 0
        self._add({"type": "timeseries", "title": title, "description": desc, "datasource": DS,
                   "targets": self._targets(targets), "fieldConfig": {"defaults": defaults, "overrides": []},
                   "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["lastNotNull", "max"]},
                               "tooltip": {"mode": "multi", "sort": "desc"}}}, x, y, w, h)

    def stat(self, title, expr, x, y, w, h, unit="short", red_above=None, desc=""):
        steps = [{"color": "green", "value": None}]
        if red_above is not None:
            steps.append({"color": "red", "value": red_above})
        self._add({"type": "stat", "title": title, "description": desc, "datasource": DS,
                   "targets": self._targets([expr], instant=True),
                   "fieldConfig": {"defaults": {"unit": unit, "thresholds": {"mode": "absolute", "steps": steps},
                                                "color": {"mode": "thresholds"}}, "overrides": []},
                   "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                               "colorMode": "value", "graphMode": "area", "textMode": "auto"}}, x, y, w, h)

    def bars(self, title, targets, x, y, w, h, unit="short"):
        self._add({"type": "bargauge", "title": title, "datasource": DS,
                   "targets": self._targets(targets, instant=True),
                   "fieldConfig": {"defaults": {"unit": unit, "color": {"mode": "continuous-GrYlRd"}, "min": 0}, "overrides": []},
                   "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                               "orientation": "horizontal", "displayMode": "gradient", "showUnfilled": True}}, x, y, w, h)

    def pie(self, title, targets, x, y, w, h, unit="short"):
        self._add({"type": "piechart", "title": title, "datasource": DS,
                   "targets": self._targets(targets, instant=True),
                   "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
                   "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                               "pieType": "donut", "legend": {"displayMode": "table", "placement": "right", "values": ["value"]}}}, x, y, w, h)

    def table(self, title, expr, x, y, w, h, hide=(), rename=None, status_col=None, unit="short"):
        overrides = []
        if status_col:                                   # colour 0/1 as DOWN/UP
            overrides.append({"matcher": {"id": "byName", "options": status_col}, "properties": [
                {"id": "mappings", "value": [{"type": "value", "options": {
                    "0": {"text": "DOWN", "color": "red"}, "1": {"text": "UP", "color": "green"}}}]},
                {"id": "custom.cellOptions", "value": {"type": "color-background"}}]})
        self._add({"type": "table", "title": title, "datasource": DS,
                   "targets": self._targets([expr], table=True),
                   "fieldConfig": {"defaults": {"unit": unit}, "overrides": overrides},
                   "options": {"showHeader": True, "cellHeight": "sm"},
                   "transformations": [{"id": "organize", "options": {
                       "excludeByName": {k: True for k in ("Time", "__name__", "job") + tuple(hide)},
                       "renameByName": rename or {}}}]}, x, y, w, h)

    def build(self):
        return {"uid": self.uid, "title": self.title, "tags": ["cloud03"] + self.tags, "timezone": "browser",
                "schemaVersion": 39, "version": 1, "refresh": "30s", "graphTooltip": 1, "editable": True,
                "time": {"from": "now-6h", "to": "now"}, "annotations": {"list": []},
                "templating": {"list": self.variables}, "panels": self.panels}


# ------------------------------------------------------------------------------------------------
def overview():
    d = Dash("c03-overview", "Cloud03 / Cluster overview", ["hosts"])
    ram_pct = "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)"
    root = "{mountpoint=\"/\",fstype!~\"tmpfs|overlay\"}"
    d.stat("Nodes reporting", "count(node_uname_info)", 0, 0, 4, 4)
    d.stat("CPU cores", "count(node_cpu_seconds_total{mode=\"idle\"})", 4, 0, 4, 4)
    d.stat("Total RAM", "sum(node_memory_MemTotal_bytes)", 8, 0, 4, 4, "bytes")
    d.stat("Cluster CPU", "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])))", 12, 0, 4, 4, "percent", 85)
    d.stat("Cluster RAM used", "100 * (1 - sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes))", 16, 0, 4, 4, "percent", 85)
    d.stat("Active VMs", "count(cloud_vm_info{status=\"ACTIVE\"}) or vector(0)", 20, 0, 4, 4)
    d.row("Compute and memory per node", 4)
    d.ts("CPU used %", [(cpu_pct() + JOIN, "{{nodename}}")], 0, 5, 12, 8, "percent", maxv=100)
    d.ts("Memory used %", [(ram_pct + JOIN, "{{nodename}}")], 12, 5, 12, 8, "percent", maxv=100)
    d.ts("Load average (1 min)", [("node_load1" + JOIN, "{{nodename}}")], 0, 13, 12, 8)
    d.ts("Root filesystem used %", [("100 * (1 - node_filesystem_avail_bytes%s / node_filesystem_size_bytes%s)" % (root, root) + JOIN, "{{nodename}}")],
         12, 13, 12, 8, "percent", "VM disks, images and telemetry are stored on the controllers' disks (GlusterFS), so watch the three controllers here", maxv=100)
    d.row("Network", 21)
    d.ts("Traffic per VLAN: received", [("sum by (device) (rate(node_network_receive_bytes_total{device=~\"%s\"}[5m]))" % VLANS, "{{device}}")],
         0, 22, 12, 8, "Bps", "mgmt=API/RabbitMQ/DB, storage=GlusterFS (VM disks), tunnel=tenant VXLAN, egress=Internet, provider=floating IPs")
    d.ts("Traffic per VLAN: sent", [("sum by (device) (rate(node_network_transmit_bytes_total{device=~\"%s\"}[5m]))" % VLANS, "{{device}}")],
         12, 22, 12, 8, "Bps")
    d.ts("Storage VLAN (GlusterFS) throughput per node",
         [("sum by (instance) (rate(node_network_receive_bytes_total{device=\"storage\"}[5m]) + rate(node_network_transmit_bytes_total{device=\"storage\"}[5m]))" + JOIN, "{{nodename}}")],
         0, 30, 12, 8, "Bps", "VM disk traffic: every write goes to all 3 controllers, so a compute node sends 3x what its VMs write")
    d.ts("Internet (egress VLAN) throughput per node",
         [("sum by (instance) (rate(node_network_receive_bytes_total{device=\"egress\"}[5m]) + rate(node_network_transmit_bytes_total{device=\"egress\"}[5m]))" + JOIN, "{{nodename}}")],
         12, 30, 12, 8, "Bps", "Everything leaving the lab goes through the gateway controller's Wi-Fi")
    d.row("Disks", 38)
    d.ts("Disk throughput per node", [("sum by (instance) (rate(node_disk_read_bytes_total[5m]) + rate(node_disk_written_bytes_total[5m]))" + JOIN, "{{nodename}}")],
         0, 39, 24, 8, "Bps")
    return d


def compute():
    d = Dash("c03-compute", "Cloud03 / Compute and VMs", ["vms"],
             [("project", "Project", "label_values(cloud_vm_info, project)"), ("host", "Host", "label_values(cloud_vm_info, host)")])
    d.stat("Active VMs", "count(cloud_vm_info{project=~\"$project\",host=~\"$host\",status=\"ACTIVE\"}) or vector(0)", 0, 0, 5, 4)
    d.stat("VMs not ACTIVE", "count(cloud_vm_info{project=~\"$project\",host=~\"$host\",status!=\"ACTIVE\"}) or vector(0)", 5, 0, 5, 4, red_above=1)
    d.stat("vCPUs allocated", "sum(cloud_vm_vcpus{project=~\"$project\",host=~\"$host\"}) or vector(0)", 10, 0, 5, 4)
    d.stat("RAM allocated", "(sum(cloud_vm_ram_mb{project=~\"$project\",host=~\"$host\"}) * 1048576) or vector(0)", 15, 0, 5, 4, "bytes")
    d.stat("Live migrations (24h)", "sum(increase(cloud_migrations_total{status=\"completed\"}[24h])) or vector(0)", 20, 0, 4, 4)
    d.row("Placement", 4)
    d.ts("Active VMs per host", [("count by (host) (cloud_vm_info{project=~\"$project\",host=~\"$host\",status=\"ACTIVE\"})", "{{host}}")], 0, 5, 12, 8)
    d.ts("vCPUs allocated per host", [("sum by (host) (cloud_vm_vcpus{project=~\"$project\",host=~\"$host\"})", "{{host}}")], 12, 5, 12, 8)
    d.row("Busiest VMs (top 10)", 13)
    cpu = vm_rate("libvirt_domain_info_cpu_time_seconds_total")
    d.ts("CPU cores in use", [("topk(10, %s)" % per_vm(cpu), "{{name}} ({{project}})")], 0, 14, 12, 8, desc="1.0 = one full vCPU busy")
    d.ts("CPU utilisation of the VM's own vCPUs %",
         [("topk(10, 100 * %s / on(domain) group_left(name, project, host) cloud_vm_vcpus{project=~\"$project\",host=~\"$host\"})" % cpu, "{{name}} ({{project}})")],
         12, 14, 12, 8, "percent")
    d.ts("Memory in use", [("topk(10, %s)" % per_vm("libvirt_domain_info_memory_usage_bytes"), "{{name}} ({{project}})")], 0, 22, 12, 8, "bytes")
    d.ts("Disk throughput (read + write)",
         [("topk(10, %s)" % per_vm("sum by (domain) (rate(libvirt_domain_block_stats_read_bytes_total[5m]) + rate(libvirt_domain_block_stats_write_bytes_total[5m]))"), "{{name}} ({{project}})")],
         12, 22, 12, 8, "Bps")
    d.ts("Network received", [("topk(10, %s)" % per_vm(vm_rate("libvirt_domain_interface_stats_receive_bytes_total")), "{{name}} ({{project}})")], 0, 30, 12, 8, "Bps")
    d.ts("Network sent", [("topk(10, %s)" % per_vm(vm_rate("libvirt_domain_interface_stats_transmit_bytes_total")), "{{name}} ({{project}})")], 12, 30, 12, 8, "Bps")
    d.row("Inventory", 38)
    d.table("All VMs", "cloud_vm_info{project=~\"$project\",host=~\"$host\"}", 0, 39, 24, 10,
            hide=("Value", "instance", "domain"),
            rename={"name": "VM", "project": "Project", "host": "Host", "flavor": "Flavor", "status": "Status", "id": "ID"})
    return d


def projects():
    d = Dash("c03-projects", "Cloud03 / Projects and usage", ["usage"], [("project", "Project", "label_values(cloud_vm_info, project)")])
    pf = "{project=~\"$project\"}"
    used = "sum by (project) (%s)" % per_vm(vm_rate("libvirt_domain_info_cpu_time_seconds_total"), "project", "cloud_vm_info" + pf)
    d.stat("Projects with VMs", "count(cloud_project_instances%s)" % pf, 0, 0, 6, 4)
    d.stat("VMs", "sum(cloud_project_instances%s)" % pf, 6, 0, 6, 4)
    d.stat("vCPUs allocated", "sum(cloud_project_vcpus%s)" % pf, 12, 0, 6, 4)
    d.stat("RAM allocated", "sum(cloud_project_ram_mb%s) * 1048576" % pf, 18, 0, 6, 4, "bytes")
    d.row("Allocation", 4)
    d.bars("VMs per project", [("cloud_project_instances" + pf, "{{project}}")], 0, 5, 8, 8)
    d.pie("vCPUs per project", [("cloud_project_vcpus" + pf, "{{project}}")], 8, 5, 8, 8)
    d.pie("RAM per project", [("cloud_project_ram_mb%s * 1048576" % pf, "{{project}}")], 16, 5, 8, 8, "bytes")
    d.row("Actual consumption", 13)
    d.ts("CPU cores in use", [(used, "{{project}}")], 0, 14, 12, 8, desc="Sum over the project's VMs, 1.0 = one vCPU fully busy")
    d.ts("CPU efficiency: used / allocated vCPUs %", [("100 * %s / on(project) (cloud_project_vcpus%s > 0)" % (used, pf), "{{project}}")],
         12, 14, 12, 8, "percent", "Low values = the project pays for vCPUs it does not use")
    d.ts("Network sent", [("sum by (project) (%s)" % per_vm(vm_rate("libvirt_domain_interface_stats_transmit_bytes_total"), "project", "cloud_vm_info" + pf), "{{project}}")], 0, 22, 12, 8, "Bps")
    d.ts("Network received", [("sum by (project) (%s)" % per_vm(vm_rate("libvirt_domain_interface_stats_receive_bytes_total"), "project", "cloud_vm_info" + pf), "{{project}}")], 12, 22, 12, 8, "Bps")
    d.ts("Disk throughput", [("sum by (project) (%s)" % per_vm("sum by (domain) (rate(libvirt_domain_block_stats_read_bytes_total[5m]) + rate(libvirt_domain_block_stats_write_bytes_total[5m]))", "project", "cloud_vm_info" + pf), "{{project}}")], 0, 30, 12, 8, "Bps")
    d.ts("VMs per project over time", [("cloud_project_instances" + pf, "{{project}}")], 12, 30, 12, 8)
    return d


def billing():
    d = Dash("c03-billing", "Cloud03 / Billing (CloudKitty)", ["billing"], [("project", "Project", "label_values(cloud_billing_cost, project)")])
    pf = "{project=~\"$project\"}"
    d.stat("Cost this month", "sum(cloud_billing_cost%s) or vector(0)" % pf, 0, 0, 8, 4, "none", desc="Rating units, see openstack/02-billing-rates.sh. Month-to-date.")
    d.stat("Cost last 24 h", "sum(increase(cloud_billing_cost%s[24h])) or vector(0)" % pf, 8, 0, 8, 4, "none", desc="Wrong around the 1st of the month (the total resets)")
    d.stat("Billed projects", "count(count by (project) (cloud_billing_cost%s)) or vector(0)" % pf, 16, 0, 8, 4)
    d.bars("Cost this month by project", [("sum by (project) (cloud_billing_cost%s)" % pf, "{{project}}")], 0, 4, 8, 8, "none")
    d.pie("Cost this month by service", [("sum by (service) (cloud_billing_cost%s)" % pf, "{{service}}")], 8, 4, 8, 8, "none")
    d.pie("Billed quantity this month by service", [("sum by (service) (cloud_billing_quantity%s)" % pf, "{{service}}")], 16, 4, 8, 8)
    d.ts("Month-to-date cost over time", [("sum by (project) (cloud_billing_cost%s)" % pf, "{{project}}")], 0, 12, 12, 8, "none")
    d.ts("Cost per day", [("sum by (project) (increase(cloud_billing_cost%s[1d]))" % pf, "{{project}}")], 12, 12, 12, 8, "none")
    d.table("Project x service", "cloud_billing_cost" + pf, 0, 20, 24, 10, hide=("instance",),
            rename={"project": "Project", "service": "Service", "Value": "Cost"})
    d.text("**Empty?** Billing data appears after CloudKitty's first full collection period (about an hour after the first VM runs) "
           "and needs the rating rules from `openstack/02-billing-rates.sh`. Check `journalctl -u cloud-exporter` if "
           "`cloud_exporter_errors_total{source=\"billing\"}` keeps rising.", 0, 30, 24, 3)
    return d


def migration():
    d = Dash("c03-migration", "Cloud03 / Live migration and balance", ["migration"])
    d.stat("Migrations completed", "sum(cloud_migrations_total{type=\"live-migration\",status=\"completed\"}) or vector(0)", 0, 0, 6, 4)
    d.stat("Migrations failed", "sum(cloud_migrations_total{type=\"live-migration\",status=~\"error|failed\"}) or vector(0)", 6, 0, 6, 4, red_above=1)
    d.stat("CPU spread (busiest - idlest node)", "max(%s) - min(%s)" % (cpu_pct(), cpu_pct()), 12, 0, 6, 4, "percent",
           desc="The scheduler acts when this exceeds its threshold (live-migration/config.yaml)")
    d.stat("Compute hosts up", "count(count by (host) (cloud_vm_info)) or vector(0)", 18, 0, 6, 4, desc="Hosts that currently run at least one VM")
    d.ts("Live migrations per hour", [("sum by (status) (increase(cloud_migrations_total{type=\"live-migration\"}[1h]))", "{{status}}")], 0, 4, 12, 8)
    d.ts("Active VMs per host (balance)", [("count by (host) (cloud_vm_info{status=\"ACTIVE\"})", "{{host}}")], 12, 4, 12, 8)
    d.ts("CPU used % per node (what the scheduler balances)", [(cpu_pct() + JOIN, "{{nodename}}")], 0, 12, 12, 8, "percent", maxv=100)
    d.ts("vCPUs allocated per host", [("sum by (host) (cloud_vm_vcpus)", "{{host}}")], 12, 12, 12, 8)
    d.table("Migration history by route", "sum by (source, dest, status, type) (cloud_migrations_total)", 0, 20, 24, 9, hide=("Time",),
            rename={"source": "From", "dest": "To", "status": "Status", "type": "Type", "Value": "Count"})
    return d


def platform():
    d = Dash("c03-platform", "Cloud03 / Platform health", ["health"])
    d.stat("Scrape targets down", "count(up == 0) or vector(0)", 0, 0, 6, 4, red_above=1)
    d.stat("Galera cluster size (want 3)", "min(mysql_global_status_wsrep_cluster_size)", 6, 0, 6, 4)
    d.stat("Galera ready (want 1)", "min(mysql_global_status_wsrep_ready)", 12, 0, 6, 4)
    d.stat("Nova services down", "count(openstack_nova_agent_state == 0) or vector(0)", 18, 0, 6, 4, red_above=1)
    d.table("Scrape targets", "up", 0, 4, 12, 12, hide=("Time",), status_col="Value", rename={"Value": "State"})
    d.table("Nova services", "openstack_nova_agent_state", 12, 4, 12, 12, hide=("Time", "instance", "id"), status_col="Value", rename={"Value": "State"})
    d.ts("MariaDB connections", [("mysql_global_status_threads_connected", "{{instance}}")], 0, 16, 12, 8)
    d.ts("MariaDB queries per second", [("rate(mysql_global_status_questions[5m])", "{{instance}}")], 12, 16, 12, 8)
    d.ts("Top 10 containers by CPU", [("topk(10, sum by (name) (rate(container_cpu_usage_seconds_total{name!=\"\"}[5m])))", "{{name}}")], 0, 24, 12, 9, desc="cores")
    d.ts("Top 10 containers by memory", [("topk(10, sum by (name) (container_memory_working_set_bytes{name!=\"\"}))", "{{name}}")], 12, 24, 12, 9, "bytes")
    d.ts("cloud-exporter: seconds since last success",
         [("time() - cloud_exporter_last_success_timestamp_seconds", "{{source}}")], 0, 33, 12, 7, "s", "Grows past a few minutes = exporter or API problem")
    d.ts("cloud-exporter: errors", [("cloud_exporter_errors_total", "{{source}}")], 12, 33, 12, 7)
    return d


def openstack_resources():
    d = Dash("c03-openstack", "Cloud03 / OpenStack resources", ["openstack"])
    d.text("Source: Kolla's **openstack-exporter**. Metric names can differ slightly between releases: "
           "a panel showing *No data* means look up the right name under Explore -> `openstack_`.", 0, 0, 24, 2)
    for i, (title, metric) in enumerate([("Projects", "openstack_identity_projects"), ("Users", "openstack_identity_users"),
                                         ("Networks", "openstack_neutron_networks"), ("Routers", "openstack_neutron_routers"),
                                         ("Floating IPs", "openstack_neutron_floating_ips"), ("Images", "openstack_glance_images")]):
        d.stat(title, "max(%s)" % metric, i * 4, 2, 4, 4)
    d.ts("Running VMs per hypervisor", [("openstack_nova_running_vms", "{{hostname}}")], 0, 6, 12, 8)
    d.ts("vCPUs used vs available per hypervisor",
         [("openstack_nova_vcpus_used", "{{hostname}} used"), ("openstack_nova_vcpus_available", "{{hostname}} total")], 12, 6, 12, 8)
    d.ts("Memory used per hypervisor", [("openstack_nova_memory_used_bytes", "{{hostname}}")], 0, 14, 12, 8, "bytes")
    d.ts("Memory available per hypervisor", [("openstack_nova_memory_available_bytes", "{{hostname}}")], 12, 14, 12, 8, "bytes")
    return d


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".json"):
            os.remove(os.path.join(OUT, f))
    for build in (overview, compute, projects, billing, migration, platform, openstack_resources):
        dash = build()
        path = os.path.join(OUT, dash.uid + ".json")
        with open(path, "w") as fh:
            json.dump(dash.build(), fh, indent=1)
        print("wrote", os.path.basename(path), "-", len([p for p in dash.panels if p["type"] != "row"]), "panels")


if __name__ == "__main__":
    main()
