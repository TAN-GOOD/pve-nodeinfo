#!/bin/sh
# pve-hwinfo.sh - read-only hardware info collector for the PVE node status patch.
# Reads kernel hwmon / cpufreq sysfs only. No external dependencies, no writes.
# usage: pve-hwinfo.sh thermal|cpu

set -u

do_thermal() {
    for h in /sys/class/hwmon/hwmon*; do
        [ -d "$h" ] || continue
        chip=$(cat "$h/name" 2>/dev/null) || continue
        case "$chip" in
            coretemp) prefix="CPU" ;;
            acpitz)   prefix="Board" ;;
            nvme)     prefix="NVMe" ;;
            iwlwifi*) prefix="WLAN" ;;
            *)        prefix="$chip" ;;
        esac

        for f in "$h"/temp*_input; do
            [ -f "$f" ] || continue
            v=$(cat "$f" 2>/dev/null) || continue
            case "$v" in ''|*[!0-9-]*) continue ;; esac
            b=${f%_input}
            lbl=$(cat "${b}_label" 2>/dev/null)
            if [ -z "$lbl" ]; then
                lbl="$prefix"
            else
                case "$chip:$lbl" in
                    coretemp:"Package id 0") lbl="CPU Package" ;;
                    coretemp:Core\ *)        lbl="CPU${lbl#Core }" ;;
                    *)                       lbl="$prefix $lbl" ;;
                esac
            fi
            val=$(awk -v t="$v" 'BEGIN { printf "%.1f", t/1000 }' 2>/dev/null) || continue
            printf '%s: %s\n' "$lbl" "$val"
        done

        for f in "$h"/fan*_input; do
            [ -f "$f" ] || continue
            v=$(cat "$f" 2>/dev/null) || continue
            case "$v" in ''|*[!0-9]*) continue ;; esac
            [ "$v" -gt 0 ] || continue
            printf 'Fan: %s\n' "$v"
        done
    done
}

do_cpu() {
    awk -F: '/^[Cc][Pp][Uu] [Mm][Hh][Zz]/ { gsub(/ /, "", $2); printf "mhz=%d\n", $2 }' /proc/cpuinfo

    g=/sys/devices/system/cpu/cpufreq/policy0/scaling_governor
    mn=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq
    mx=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq

    if [ -r "$g" ]; then printf 'gov=%s\n' "$(cat "$g")"; else printf 'gov=none\n'; fi
    if [ -r "$mn" ]; then
        printf 'min=%s\n' "$(awk -v t="$(cat "$mn")" 'BEGIN { printf "%d", t/1000 }')"
    else
        printf 'min=0\n'
    fi
    if [ -r "$mx" ]; then
        printf 'max=%s\n' "$(awk -v t="$(cat "$mx")" 'BEGIN { printf "%d", t/1000 }')"
    else
        printf 'max=0\n'
    fi
}

case "${1:-}" in
    thermal) do_thermal ;;
    cpu)     do_cpu ;;
    *)       echo "usage: $0 thermal|cpu" >&2; exit 2 ;;
esac
