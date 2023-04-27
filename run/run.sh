#!/usr/bin/env bash
set -eu

# Docker environment variables

: ${URL:=''}            # URL of the PAT file
: ${DEBUG:='N'}         # Enable debug mode
: ${ALLOCATE:='Y'}      # Preallocate diskspace
: ${CPU_CORES:='1'}     # Amount of CPU cores
: ${DISK_SIZE:='16G'}   # Initial data disk size
: ${RAM_SIZE:='512M'}   # Maximum RAM amount

echo "Starting Virtual DSM for Docker v${VERSION}..."

STORAGE="/storage"
KERNEL=$(uname -r | cut -b 1)

[ ! -d "$STORAGE" ] && echo "Storage folder (${STORAGE}) not found!" && exit 69
[ ! -f "/run/run.sh" ] && echo "Script must run inside Docker container!" && exit 60

if [ -f "$STORAGE"/dsm.ver ]; then
  BASE=$(cat "${STORAGE}/dsm.ver")
else
  # Fallback for old installs
  BASE="DSM_VirtualDSM_42962"
fi

[ -n "$URL" ] && BASE=$(basename "$URL" .pat)

if [[ ! -f "$STORAGE/$BASE.boot.img" ]] || [[ ! -f "$STORAGE/$BASE.system.img" ]]; then
  . /run/install.sh
fi

# Initialize disks
. /run/disk.sh

# Initialize network
. /run/network.sh

# Initialize serialport
. /run/serial.sh

# Configure shutdown
. /run/power.sh

KVM_ERR=""

if [ -e /dev/kvm ] && sh -c 'echo -n > /dev/kvm' &> /dev/null; then
  if ! grep -q -e vmx -e svm /proc/cpuinfo; then
    KVM_ERR="(cpuinfo $(grep -c -e vmx -e svm /proc/cpuinfo))"
  fi
else
  [ -e /dev/kvm ] && KVM_ERR="(no write access)" || KVM_ERR="(device file missing)"
fi

if [ ! -z "${KVM_ERR}" ]; then
  echo "Error: KVM acceleration not detected ${KVM_ERR}, please enable it."
  [ "$DEBUG" != "Y" ] && exit 88
fi

KVM_OPTS=",accel=kvm -enable-kvm -cpu host"
DEF_OPTS="-nographic -nodefaults -boot strict=on -display none"
RAM_OPTS=$(echo "-m ${RAM_SIZE}" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
CPU_OPTS="-smp ${CPU_CORES},sockets=1,dies=1,cores=${CPU_CORES},threads=1"
MAC_OPTS="-machine type=q35,usb=off,dump-guest-core=off,hpet=off${KVM_OPTS}"
EXTRA_OPTS="-device virtio-balloon-pci,id=balloon0,bus=pcie.0,addr=0x4"
EXTRA_OPTS="$EXTRA_OPTS -object rng-random,id=objrng0,filename=/dev/urandom"
EXTRA_OPTS="$EXTRA_OPTS -device virtio-rng-pci,rng=objrng0,id=rng0,bus=pcie.0,addr=0x1c"

ARGS="${DEF_OPTS} ${CPU_OPTS} ${RAM_OPTS} ${MAC_OPTS} ${MON_OPTS} ${SERIAL_OPTS} ${NET_OPTS} ${DISK_OPTS} ${EXTRA_OPTS}"
ARGS=$(echo "$ARGS" | sed 's/\t/ /g' | tr -s ' ')

if [ "$DEBUG" = "Y" ]; then
  echo -n "qemu-system-x86_64 "
  echo "${ARGS}" && echo
fi

set -m
(
  qemu-system-x86_64 ${ARGS:+ $ARGS} & echo $! > "${_QEMU_PID}"
)
set +m

if (( KERNEL > 4 )); then
  pidwait -F "${_QEMU_PID}" & wait $!
else
  tail --pid "$(cat "${_QEMU_PID}")" --follow /dev/null & wait $!
fi
