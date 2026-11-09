#!/usr/bin/env bash
#
# Check CPU compatibility across all OpenStack compute nodes.
# A common CPU baseline is required for reliable live migration.
#

set -uo pipefail

cd "$(dirname "$0")/../ansible" || exit 1

echo
echo "=============================================================="
echo "           OPENSTACK COMPUTE CPU COMPATIBILITY"
echo "=============================================================="
echo
echo "Checking Nehalem CPU baseline on all compute nodes..."
echo

# Execute remote checks
ANSIBLE_NOCOLOR=1 ansible compute \
    -b \
    -m script \
    -a "../scripts/cpu-flags.sh" \
    -o > /tmp/cpu-checks-output.$$ 2>&1

ANSIBLE_RC=$?

# Extract and format host output
sed -E \
    -e 's/^([^ ]+) \| (CHANGED|SUCCESS|FAILED) => .*"stdout": "([^"]*)".*/\1 | \3/' \
    -e 's/\\r\\n/ ; /g' \
    -e 's/\\n/ ; /g' \
    /tmp/cpu-checks-output.$$

echo

# Count results
PASS_COUNT=$(grep -c 'RESULT: PASS' /tmp/cpu-checks-output.$$ || true)
FAIL_COUNT=$(grep -c 'RESULT: FAIL' /tmp/cpu-checks-output.$$ || true)
UNREACHABLE_COUNT=$(grep -c 'UNREACHABLE!' /tmp/cpu-checks-output.$$ || true)

TOTAL=$((PASS_COUNT + FAIL_COUNT + UNREACHABLE_COUNT))

echo "=============================================================="
echo "                       SUMMARY"
echo "=============================================================="
echo
printf "Total checked : %s\n" "$TOTAL"
printf "Passed        : %s\n" "$PASS_COUNT"
printf "Failed        : %s\n" "$FAIL_COUNT"
printf "Unreachable   : %s\n" "$UNREACHABLE_COUNT"
echo

if (( FAIL_COUNT == 0 && UNREACHABLE_COUNT == 0 && ANSIBLE_RC == 0 )); then

    echo "RESULT: ALL COMPUTE NODES PASSED"
    echo
    echo "Recommended Nova configuration:"
    echo
    echo "[libvirt]"
    echo "cpu_mode = custom"
    echo "cpu_models = Nehalem"
    echo
    echo "Nehalem minimum CPU flags are available on all nodes."

else

    echo "RESULT: CPU COMPATIBILITY CHECK FAILED"
    echo
    echo "Review failed or unreachable compute nodes."
    echo "Do not assume Nehalem is a valid common CPU baseline."
    echo
    echo "Check the following:"
    echo "  1. CPU flags on failed compute nodes."
    echo "  2. SSH connectivity and Ansible privileges."
    echo "  3. Actual libvirt CPU model compatibility."
    echo

fi

rm -f /tmp/cpu-checks-output.$$

echo "=============================================================="

if (( FAIL_COUNT > 0 || UNREACHABLE_COUNT > 0 || ANSIBLE_RC != 0 )); then
    exit 1
fi

exit 0