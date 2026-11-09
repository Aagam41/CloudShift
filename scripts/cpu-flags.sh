#!/usr/bin/env bash
# Runs on each compute node (via cpu-check.sh): does the CPU provide what the "Nehalem" guest model needs?
need="cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3"
missing=""
for f in $need; do grep -qm1 -w "$f" /proc/cpuinfo || missing="$missing $f"; done
model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)
if [ -z "$missing" ]; then echo "OK    $model"; else echo "FAIL  $model  (missing:$missing) -> use cpu_models = qemu64"; fi
