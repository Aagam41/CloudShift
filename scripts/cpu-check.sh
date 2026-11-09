#!/usr/bin/env bash
# Live migration needs one CPU model that every compute node can provide (kolla/config/nova/nova-compute.conf).
cd "$(dirname "$0")/../ansible"
ansible compute -b -m script -a "../scripts/cpu-flags.sh" -o 2>&1 | sed 's/ | CHANGED.*>> / /; s/ | SUCCESS.*>> / /'
echo
echo "All OK     -> keep cpu_models = Nehalem (or choose a newer common model for better guest performance)"
echo "Any FAIL   -> set cpu_models = qemu64 in kolla/config/nova/nova-compute.conf before deploying"
echo "All nodes the same CPU -> you may use cpu_mode = host-passthrough instead"
