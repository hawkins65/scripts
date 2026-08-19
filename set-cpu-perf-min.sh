#!/bin/bash

# Wait a bit for the CPU scaling driver (amd-pstate) to be fully initialized
# Adjust delay as needed. Longer may be required on some systems.
sleep 5

echo "Setting CPU governors to performance..."

# Set the scaling governor to 'performance' for all CPU policies
for gov_file in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
    if [ -f "$gov_file" ]; then
        echo "performance" | sudo tee $gov_file >/dev/null
    fi
done

# If available, set the energy performance preference (EPP) to 'performance'
# This applies primarily if using amd-pstate-epp.
for epp_file in /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference; do
    if [ -f "$epp_file" ]; then
        echo "performance" | sudo tee $epp_file >/dev/null
    fi
done

echo "Disabling deep idle states to minimize latency..."
sudo cpupower idle-set -D 1

echo
echo "Verification:"
echo "============"
cpupower frequency-info | grep -E 'Driver|governor|analyzing CPU|current policy'
echo
echo "Current governors:"
cat /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
echo
if ls /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference &>/dev/null; then
    echo "Current EPP values:"
    cat /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference
else
    echo "No EPP settings found (not using amd-pstate-epp)."
fi

echo
echo "All done."
