#!/usr/bin/env bash
set -u

section() {
  printf '\n===== %s =====\n' "$1"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

section "SYSTEM"
if have hostnamectl; then
  hostnamectl 2>/dev/null || true
else
  echo "Hostname: $(hostname)"
  echo "Kernel: $(uname -r)"
  echo "Arch: $(uname -m)"
fi

if [ -r /etc/os-release ]; then
  . /etc/os-release
  echo "OS: ${PRETTY_NAME:-unknown}"
fi

if have pveversion; then
  echo "Proxmox: $(pveversion 2>/dev/null)"
fi

section "CPU"
if have lscpu; then
  lscpu | grep -E '^(Model name|Socket\(s\)|Core\(s\) per socket|Thread\(s\) per core|CPU\(s\)|Architecture|CPU max MHz|CPU min MHz):' || lscpu
elif [ -r /proc/cpuinfo ]; then
  grep -E 'model name|processor' /proc/cpuinfo | head -20
elif have sysctl; then
  echo "Model: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model 2>/dev/null || echo unknown)"
  echo "Logical CPUs: $(sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo unknown)"
  echo "Physical CPUs: $(sysctl -n hw.physicalcpu 2>/dev/null || echo unknown)"
else
  echo "CPU information unavailable."
fi

section "RAM"
if have free; then
  free -h
elif have sysctl; then
  bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  if [ "$bytes" -gt 0 ] 2>/dev/null; then
    awk -v b="$bytes" 'BEGIN {printf "Total RAM: %.2f GiB\n", b/1024/1024/1024}'
  fi
fi

if have dmidecode && [ "$(id -u)" -eq 0 ]; then
  echo
  echo "Memory modules:"
  dmidecode -t memory 2>/dev/null | awk '
    /^Memory Device$/ {in_dev=1; size=""; locator=""; type=""; speed=""; vendor=""; part=""}
    in_dev && /^[[:space:]]+Size:/ {sub(/^[[:space:]]+/, ""); size=$0}
    in_dev && /^[[:space:]]+Locator:/ && locator=="" {sub(/^[[:space:]]+/, ""); locator=$0}
    in_dev && /^[[:space:]]+Type:/ && type=="" {sub(/^[[:space:]]+/, ""); type=$0}
    in_dev && /^[[:space:]]+Configured Memory Speed:/ {sub(/^[[:space:]]+/, ""); speed=$0}
    in_dev && /^[[:space:]]+Manufacturer:/ {sub(/^[[:space:]]+/, ""); vendor=$0}
    in_dev && /^[[:space:]]+Part Number:/ {sub(/^[[:space:]]+/, ""); part=$0}
    in_dev && /^$/ {
      if (size !~ /No Module Installed/ && size != "") {
        printf "%s | %s | %s | %s | %s | %s\n", locator, size, type, speed, vendor, part
      }
      in_dev=0
    }
  '
elif have dmidecode; then
  echo
  echo "Run as root to show RAM modules (dmidecode)."
fi

section "GPU"
if have lspci; then
  lspci -nn | grep -Ei 'vga compatible controller|3d controller|display controller' || echo "No GPU/display controller found via lspci."
else
  echo "lspci not installed (package: pciutils)."
fi

if have nvidia-smi; then
  echo
  nvidia-smi --query-gpu=name,memory.total,driver_version,pci.bus_id --format=csv,noheader 2>/dev/null || true
fi

section "DISKS"
if have lsblk; then
  lsblk -d -o NAME,SIZE,ROTA,TYPE,TRAN,MODEL,SERIAL 2>/dev/null ||     lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL
else
  echo "lsblk not available."
fi

echo
echo "Partitions / filesystems:"
if have lsblk; then
  lsblk -o NAME,SIZE,FSTYPE,FSVER,MOUNTPOINTS 2>/dev/null || lsblk
fi

section "NETWORK"
if have lspci; then
  lspci -nn | grep -Ei 'ethernet controller|network controller' || echo "No PCI network controller found."
fi

if have ip; then
  echo
  ip -br link 2>/dev/null || true
  echo
  ip -br addr 2>/dev/null || true
fi

section "PCI SUMMARY"
if have lspci; then
  lspci
else
  echo "lspci not installed (package: pciutils)."
fi
