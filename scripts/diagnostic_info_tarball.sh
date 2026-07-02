#!/usr/bin/env bash
# Collect GPU / PCI / NUMA / IOMMU information useful for reproducing devices
# in Nova or Cyborg tests.  The script is intentionally simple and best-effort:
# every command is allowed to fail and collection continues.

set -u

OUTDIR="gpu-info-$(hostname -s 2>/dev/null || echo host)-$(date -u +%Y%m%dT%H%M%SZ)"
MAKE_TAR=1
ALL_PCI=0
BDFS=""

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -o, --output DIR   Output directory. Default: $OUTDIR
  --bdf BDF          Collect a specific PCI device, e.g. 0000:3b:00.0.
                     Can be specified multiple times.
  --all-pci          Collect per-device sysfs/lspci details for every PCI device,
                     not only NVIDIA/display/3D devices.
  --no-tar           Do not create a .tar.gz archive.
  -h, --help         Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--output)
            OUTDIR="$2"
            shift 2
            ;;
        --bdf)
            BDFS="$BDFS $2"
            shift 2
            ;;
        --all-pci)
            ALL_PCI=1
            shift
            ;;
        --no-tar)
            MAKE_TAR=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

mkdir -p "$OUTDIR" "$OUTDIR/commands" "$OUTDIR/sysfs" "$OUTDIR/iommu_groups"
LOG="$OUTDIR/collection.log"
: > "$LOG"

log() {
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG" >&2
}

safe_name() {
    printf '%s' "$1" | tr '/ :' '___'
}

bdf_to_nodedev_name() {
    # 0000:17:00.0 -> pci_0000_17_00_0
    printf 'pci_%s\n' "$1" | tr ':. ' '___'
}

pci_parent_chain() {
    # Print PCI ancestor BDFs for a device, nearest parent first. This captures
    # root ports, PCI bridges, and PCI switch upstream/downstream ports.
    local bdf="$1"
    local cur parent name
    cur="$(readlink -f "/sys/bus/pci/devices/$bdf" 2>/dev/null || true)"
    [ -n "$cur" ] || return 0

    while :; do
        parent="$(dirname "$cur")"
        name="$(basename "$parent")"
        case "$name" in
            [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F].[0-7])
                if [ -e "/sys/bus/pci/devices/$name" ]; then
                    printf '%s\n' "$name"
                    cur="$parent"
                    continue
                fi
                ;;
        esac
        break
    done
}

run_cmd() {
    local name="$1"
    local file rc
    shift
    file="$OUTDIR/commands/$(safe_name "$name").txt"
    log "running: $name"
    {
        echo "# command: $*"
        echo "# date: $(date -u +%FT%TZ)"
        echo
        "$@"
        rc=$?
        echo
        echo "# exit_status: $rc"
    } >"$file" 2>&1 || true
}

copy_file() {
    local src="$1"
    local dst="$2"
    if [ -r "$src" ] && [ -f "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cat "$src" > "$dst" 2>/dev/null || true
    fi
}

link_target() {
    local path="$1"
    local out="$2"
    if [ -L "$path" ]; then
        readlink -f "$path" > "$out" 2>/dev/null || true
    fi
}

hex_dump_file() {
    local src="$1"
    local dst="$2"
    local max_bytes="$3"
    if [ ! -r "$src" ] || [ ! -f "$src" ]; then
        return 0
    fi
    mkdir -p "$(dirname "$dst")"
    if command -v hexdump >/dev/null 2>&1; then
        dd if="$src" bs="$max_bytes" count=1 2>/dev/null | hexdump -C > "$dst" 2>/dev/null || true
    elif command -v xxd >/dev/null 2>&1; then
        dd if="$src" bs="$max_bytes" count=1 2>/dev/null | xxd > "$dst" 2>/dev/null || true
    fi
}

copy_sysfs_tree() {
    local src="$1"
    local dst="$2"
    local max_depth="${3:-4}"
    local f rel base
    [ -e "$src" ] || return 0

    if [ -L "$src" ]; then
        mkdir -p "$(dirname "$dst.target")"
        readlink -f "$src" > "$dst.target" 2>/dev/null || true
        return 0
    fi

    if [ -f "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        timeout 2 head -c 1048576 "$src" > "$dst" 2>/dev/null || true
        return 0
    fi

    [ -d "$src" ] || return 0
    mkdir -p "$dst"
    find "$src" -maxdepth "$max_depth" \( -type f -o -type l \) 2>/dev/null | sort | while read -r f; do
        rel="${f#$src/}"
        base="$(basename "$f")"
        case "$base" in
            config|rom|resource[0-9]*|resource[0-9]*_wc|resource_wc)
                continue
                ;;
        esac
        if [ -L "$f" ]; then
            mkdir -p "$(dirname "$dst/$rel.target")"
            readlink -f "$f" > "$dst/$rel.target" 2>/dev/null || true
        elif [ -r "$f" ]; then
            mkdir -p "$(dirname "$dst/$rel")"
            timeout 2 head -c 1048576 "$f" > "$dst/$rel" 2>/dev/null || true
        fi
    done
}

sysfs_snapshot() {
    local bdf="$1"
    local dev dst link f base path
    dev="/sys/bus/pci/devices/$bdf"
    [ -d "$dev" ] || return 0

    dst="$OUTDIR/sysfs/$bdf"
    mkdir -p "$dst"
    log "collecting sysfs for $bdf"

    # Capture symlink relationships first; these are often the most useful bits.
    for link in driver iommu_group subsystem physfn; do
        link_target "$dev/$link" "$dst/${link}.target"
    done
    for link in "$dev"/virtfn*; do
        [ -e "$link" ] || continue
        link_target "$link" "$dst/$(basename "$link").target"
    done

    # Small text/sysfs attributes. Avoid raw BAR resourceN and ROM files.
    find "$dev" -maxdepth 1 -type f 2>/dev/null | sort | while read -r f; do
        base="$(basename "$f")"
        case "$base" in
            config|rom|resource[0-9]*|resource[0-9]*_wc)
                continue
                ;;
        esac
        # Sysfs files are normally tiny, but cap anyway for robustness.
        if [ -r "$f" ]; then
            timeout 2 head -c 1048576 "$f" > "$dst/$base" 2>/dev/null || true
        fi
    done

    # Bounded config-space dump can help reproduce PCI capability details.
    hex_dump_file "$dev/config" "$dst/config.hex" 4096

    # Mediated-device/vGPU, SR-IOV, and NVIDIA-specific information, if present.
    # These subtrees are still capped per file and skip obvious binary PCI BAR/ROM data.
    for path in "$dev"/sriov_* "$dev"/mdev_supported_types "$dev"/mdev_bus "$dev"/nvidia* "$dev"/virtfn* "$dev"/physfn; do
        [ -e "$path" ] || continue
        copy_sysfs_tree "$path" "$dst/$(basename "$path")" 5
    done

    if [ -d "/sys/class/mdev_bus/$bdf" ]; then
        copy_sysfs_tree "/sys/class/mdev_bus/$bdf" "$dst/sys_class_mdev_bus" 5
    fi
}

discover_bdfs() {
    if [ -n "$BDFS" ]; then
        printf '%s\n' $BDFS
        return 0
    fi

    if [ "$ALL_PCI" -eq 1 ]; then
        find /sys/bus/pci/devices -maxdepth 1 -mindepth 1 -type l -printf '%f\n' 2>/dev/null | sort
        return 0
    fi

    # Start from lspci and collect every NVIDIA PCI function (vendor ID 10de).
    # That includes display/3D functions plus related NVIDIA bridge/audio/USB/etc.
    # functions that may matter for topology or IOMMU grouping.
    if command -v lspci >/dev/null 2>&1; then
        lspci -Dnn 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /\[10de:/ {print $1}' | sort -u
    else
        for dev in /sys/bus/pci/devices/*; do
            [ -d "$dev" ] || continue
            vendor="$(cat "$dev/vendor" 2>/dev/null || true)"
            class="$(cat "$dev/class" 2>/dev/null || true)"
            case "$vendor:$class" in
                0x10de:*|*:0x03*) basename "$dev" ;;
            esac
        done | sort -u
    fi
}

# Host metadata.
run_cmd uname uname -a
copy_file /etc/os-release "$OUTDIR/os-release"
copy_file /proc/cmdline "$OUTDIR/kernel-cmdline"
copy_file /proc/cpuinfo "$OUTDIR/cpuinfo"
copy_file /proc/meminfo "$OUTDIR/meminfo"
run_cmd lscpu lscpu
run_cmd lscpu_extended lscpu -e
run_cmd numactl_hardware numactl -H
run_cmd lsmod lsmod
run_cmd dmesg_iommu sh -c "dmesg 2>/dev/null | grep -Ei 'iommu|amd-vi|intel-iommu|vfio|nvidia|nouveau' || true"

# Global PCI topology and capabilities.
run_cmd lspci_Dnn lspci -Dnn
run_cmd lspci_tree lspci -Dtv
run_cmd lspci_verbose lspci -Dvvv
run_cmd lspci_kernel lspci -Dk
run_cmd lspci_path lspci -DPPnn
run_cmd lspci_path_verbose lspci -DPPvv

# NVIDIA command output, where available/supported.
run_cmd nvidia_smi nvidia-smi
run_cmd nvidia_smi_L nvidia-smi -L
run_cmd nvidia_smi_q nvidia-smi -q
run_cmd nvidia_smi_topo_m nvidia-smi topo -m
run_cmd nvidia_smi_topo_p2p_rw nvidia-smi topo -p2p rw
run_cmd nvidia_smi_nvlink_s nvidia-smi nvlink -s
run_cmd nvidia_smi_vgpu_q nvidia-smi vgpu -q
run_cmd nvidia_smi_vgpu_supported nvidia-smi vgpu -s
run_cmd nvidia_smi_query_gpu nvidia-smi --query-gpu=index,pci.bus_id,uuid,gpu_name,gpu_serial,driver_version,vbios_version,inforom.img,minor_number,numa.node,pci.device_id,pci.sub_device_id --format=csv
run_cmd mdevctl_types mdevctl types
run_cmd mdevctl_list mdevctl list
run_cmd sysfs_mdev_bus_find sh -c "find /sys/class/mdev_bus /sys/bus/mdev -maxdepth 5 -print 2>/dev/null || true"
run_cmd sysfs_nvidia_find sh -c "find /sys/class /sys/module -maxdepth 3 \( -name 'nvidia*' -o -name '*nvidia*' \) -print 2>/dev/null || true"
run_cmd proc_driver_nvidia_find sh -c "find /proc/driver/nvidia -maxdepth 5 -print 2>/dev/null || true"

# Global mdev/NVIDIA views from sysfs/procfs, where present.
copy_sysfs_tree /sys/class/mdev_bus "$OUTDIR/sysfs_class_mdev_bus" 6
copy_sysfs_tree /sys/bus/mdev "$OUTDIR/sysfs_bus_mdev" 6
copy_sysfs_tree /sys/class/nvidia "$OUTDIR/sysfs_class_nvidia" 5
copy_sysfs_tree /sys/class/nvidia-caps "$OUTDIR/sysfs_class_nvidia-caps" 5
copy_sysfs_tree /sys/module/nvidia "$OUTDIR/sysfs_module_nvidia" 5
copy_sysfs_tree /sys/module/nvidia_vgpu_vfio "$OUTDIR/sysfs_module_nvidia_vgpu_vfio" 5
copy_sysfs_tree /proc/driver/nvidia "$OUTDIR/proc_driver_nvidia" 5

# Libvirt view. Nova/Cyborg often consume libvirt capabilities and node-device
# XML rather than raw PCI/sysfs directly, so capture both default and qemu:///system.
run_cmd virsh_version virsh version
run_cmd virsh_uri virsh uri
run_cmd virsh_capabilities virsh capabilities
run_cmd virsh_domcapabilities virsh domcapabilities
run_cmd virsh_nodedev_list_all virsh nodedev-list
run_cmd virsh_nodedev_list_tree virsh nodedev-list --tree
run_cmd virsh_nodedev_list_pci virsh nodedev-list --cap pci
run_cmd virsh_nodedev_list_mdev_types virsh nodedev-list --cap mdev_types
run_cmd virsh_nodedev_list_mdev virsh nodedev-list --cap mdev
run_cmd virsh_system_capabilities virsh -c qemu:///system capabilities
run_cmd virsh_system_domcapabilities virsh -c qemu:///system domcapabilities
run_cmd virsh_system_nodedev_list_tree virsh -c qemu:///system nodedev-list --tree
run_cmd virsh_system_nodedev_list_pci virsh -c qemu:///system nodedev-list --cap pci
run_cmd virsh_system_nodedev_list_mdev_types virsh -c qemu:///system nodedev-list --cap mdev_types
run_cmd virsh_system_nodedev_list_mdev virsh -c qemu:///system nodedev-list --cap mdev

# IOMMU group inventory.
if [ -d /sys/kernel/iommu_groups ]; then
    find /sys/kernel/iommu_groups -maxdepth 2 -type l 2>/dev/null | sort | while read -r link; do
        group="$(basename "$(dirname "$link")")"
        devname="$(basename "$link")"
        mkdir -p "$OUTDIR/iommu_groups/$group"
        readlink -f "$link" > "$OUTDIR/iommu_groups/$group/$devname.target" 2>/dev/null || true
    done
fi

# Per-device details.
BDF_FILE="$OUTDIR/selected-bdfs.txt"
discover_bdfs > "$BDF_FILE"
SUMMARY="$OUTDIR/gpu-summary.tsv"
MDEV_SUMMARY="$OUTDIR/mdev-capable-devices.tsv"
NVIDIA_VGPU_SUMMARY="$OUTDIR/nvidia-vgpu-capable-devices.tsv"
PARENT_MAP="$OUTDIR/pci-parent-map.tsv"
PARENT_BDF_FILE="$OUTDIR/parent-bdfs.txt"
printf 'bdf\tvendor\tdevice\tsubsystem_vendor\tsubsystem_device\tclass\trevision\tdriver\tiommu_group\tnuma_node\tlocal_cpulist\tmdev_supported_types\n' > "$SUMMARY"
printf 'bdf\tmdev_type\tname\tavailable_instances\tdescription\tdevice_api\n' > "$MDEV_SUMMARY"
printf 'bdf\tcreatable_vgpu_types\tcurrent_vgpu_type\tgpu_instance_id\tplacement_id\tvgpu_params\n' > "$NVIDIA_VGPU_SUMMARY"
printf 'gpu_bdf\tparent_bdf\tdepth\n' > "$PARENT_MAP"
: > "$PARENT_BDF_FILE"

while read -r bdf; do
    [ -n "$bdf" ] || continue
    dev="/sys/bus/pci/devices/$bdf"

    run_cmd "lspci_${bdf}_vvvxxxx" lspci -Dvvvxxxx -s "$bdf"
    run_cmd "lspci_${bdf}_kernel" lspci -Dk -s "$bdf"
    nodedev="$(bdf_to_nodedev_name "$bdf")"
    run_cmd "virsh_nodedev_dumpxml_${bdf}" virsh nodedev-dumpxml "$nodedev"
    run_cmd "virsh_system_nodedev_dumpxml_${bdf}" virsh -c qemu:///system nodedev-dumpxml "$nodedev"
    sysfs_snapshot "$bdf"

    depth=0
    pci_parent_chain "$bdf" | while read -r parent_bdf; do
        [ -n "$parent_bdf" ] || continue
        depth=$((depth + 1))
        printf '%s\t%s\t%s\n' "$bdf" "$parent_bdf" "$depth" >> "$PARENT_MAP"

        if ! grep -qx "$parent_bdf" "$PARENT_BDF_FILE" 2>/dev/null; then
            echo "$parent_bdf" >> "$PARENT_BDF_FILE"
            run_cmd "lspci_parent_${parent_bdf}_vvvxxxx" lspci -Dvvvxxxx -s "$parent_bdf"
            run_cmd "lspci_parent_${parent_bdf}_kernel" lspci -Dk -s "$parent_bdf"
            parent_nodedev="$(bdf_to_nodedev_name "$parent_bdf")"
            run_cmd "virsh_parent_nodedev_dumpxml_${parent_bdf}" virsh nodedev-dumpxml "$parent_nodedev"
            run_cmd "virsh_system_parent_nodedev_dumpxml_${parent_bdf}" virsh -c qemu:///system nodedev-dumpxml "$parent_nodedev"
            sysfs_snapshot "$parent_bdf"
        fi
    done

    vendor="$(cat "$dev/vendor" 2>/dev/null || true)"
    device="$(cat "$dev/device" 2>/dev/null || true)"
    subvendor="$(cat "$dev/subsystem_vendor" 2>/dev/null || true)"
    subdevice="$(cat "$dev/subsystem_device" 2>/dev/null || true)"
    class="$(cat "$dev/class" 2>/dev/null || true)"
    revision="$(cat "$dev/revision" 2>/dev/null || true)"
    driver="$(readlink -f "$dev/driver" 2>/dev/null | xargs -r basename 2>/dev/null || true)"
    iommu="$(readlink -f "$dev/iommu_group" 2>/dev/null | xargs -r basename 2>/dev/null || true)"
    numa="$(cat "$dev/numa_node" 2>/dev/null || true)"
    cpulist="$(cat "$dev/local_cpulist" 2>/dev/null || true)"
    mdev_types=""
    if [ -d "$dev/mdev_supported_types" ]; then
        mdev_types="$(find "$dev/mdev_supported_types" -maxdepth 1 -mindepth 1 -type d -printf '%f,' 2>/dev/null | sed 's/,$//')"
        find "$dev/mdev_supported_types" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | while read -r type_dir; do
            type_name="$(basename "$type_dir")"
            type_label="$(cat "$type_dir/name" 2>/dev/null || true)"
            available="$(cat "$type_dir/available_instances" 2>/dev/null || true)"
            description="$(tr '\n\t' '  ' < "$type_dir/description" 2>/dev/null || true)"
            device_api="$(cat "$type_dir/device_api" 2>/dev/null || true)"
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$bdf" "$type_name" "$type_label" "$available" "$description" "$device_api" >> "$MDEV_SUMMARY"
        done
    fi
    if [ -d "$dev/nvidia" ]; then
        creatable="$(tr '\n\t' '  ' < "$dev/nvidia/creatable_vgpu_types" 2>/dev/null || true)"
        current="$(tr '\n\t' '  ' < "$dev/nvidia/current_vgpu_type" 2>/dev/null || true)"
        gpu_instance="$(tr '\n\t' '  ' < "$dev/nvidia/gpu_instance_id" 2>/dev/null || true)"
        placement="$(tr '\n\t' '  ' < "$dev/nvidia/placement_id" 2>/dev/null || true)"
        vgpu_params="$(tr '\n\t' '  ' < "$dev/nvidia/vgpu_params" 2>/dev/null || true)"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$bdf" "$creatable" "$current" "$gpu_instance" "$placement" "$vgpu_params" >> "$NVIDIA_VGPU_SUMMARY"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$bdf" "$vendor" "$device" "$subvendor" "$subdevice" "$class" "$revision" "$driver" "$iommu" "$numa" "$cpulist" "$mdev_types" >> "$SUMMARY"
done < "$BDF_FILE"

if [ "$MAKE_TAR" -eq 1 ]; then
    tarball="$OUTDIR.tar.gz"
    parent="$(dirname "$OUTDIR")"
    base="$(basename "$OUTDIR")"
    log "creating archive $tarball"
    tar -C "$parent" -czf "$tarball" "$base" 2>>"$LOG" || true
fi

log "done: $OUTDIR"
if [ "$MAKE_TAR" -eq 1 ]; then
    log "archive: $OUTDIR.tar.gz"
fi
exit 0
