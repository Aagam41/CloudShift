#!/usr/bin/env bash
#
# Check whether this compute node supports the minimum CPU flags
# required by the selected Nehalem guest CPU baseline.
#

set -u

REQUIRED_FLAGS=(
    cx16
    lahf_lm
    popcnt
    sse4_1
    sse4_2
    ssse3
)

# CPU information
CPU_VENDOR=$(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)
CPU_MODEL=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)
CPU_ARCH=$(uname -m)

# Read CPU flags
CPU_FLAGS=$(awk -F': ' '/^flags/ {print $2; exit}' /proc/cpuinfo)

if [[ -z "$CPU_MODEL" || -z "$CPU_FLAGS" ]]; then
    echo "FAIL | Unable to detect CPU information"
    exit 1
fi

MISSING_FLAGS=()
PRESENT_FLAGS=()

for flag in "${REQUIRED_FLAGS[@]}"; do
    if [[ " $CPU_FLAGS " == *" $flag "* ]]; then
        PRESENT_FLAGS+=("$flag")
    else
        MISSING_FLAGS+=("$flag")
    fi
done

# CPU vendor description
case "$CPU_VENDOR" in
    GenuineIntel)
        CPU_VENDOR="Intel"
        ;;
    AuthenticAMD)
        CPU_VENDOR="AMD"
        ;;
    *)
        CPU_VENDOR="${CPU_VENDOR:-Unknown}"
        ;;
esac

echo "CPU Vendor : $CPU_VENDOR"
echo "CPU Model  : $CPU_MODEL"
echo "Architecture: $CPU_ARCH"
echo "----------------------------------------"

echo "Required CPU flags:"
echo "  ${REQUIRED_FLAGS[*]}"

echo
echo "Available CPU flags:"
echo "  ${PRESENT_FLAGS[*]:-none}"

if ((${#MISSING_FLAGS[@]} > 0)); then
    echo
    echo "Missing CPU flags:"
    echo "  ${MISSING_FLAGS[*]}"

    echo
    echo "RESULT: FAIL"
    echo "Recommendation: Investigate a compatible CPU baseline."

    exit 1
fi

echo
echo "RESULT: PASS"
echo "Nehalem minimum CPU flags are available."

exit 0