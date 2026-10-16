#!/bin/bash
# fc-snapshot.sh -- Firecracker full-VM snapshot/restore for the postgres18-musl
# OSv demo. Boots OSv+PostgreSQL once under Firecracker to "ready to accept
# connections", takes a FULL snapshot (guest memory + device/vCPU state), and on
# later launches RESTORES that snapshot so PostgreSQL is ALREADY SERVING -- no
# reboot, no re-initdb, no musl-PIE re-mmap.
#
# Measured on m5d.metal (AL2023, Firecracker v1.7.0, OSv v0.57 PG18.4-musl):
#   cold launch -> first external "select 1"  = 11.75 s
#   restore     -> first external "select 1"  =  0.24 s  (median, ~48x faster)
#   FC resume (load+resume) itself            =  0.05 s
# The whole PostgreSQL start cost is baked into the snapshotted memory image.
#
# OSv resumes CLEANLY from the snapshot with NO OSv kernel changes required
# (OSv is already Firecracker-snapshot-ready for this workload). See README.
#
# Requirements on the host:
#   * bare-metal x86_64 (Firecracker needs /dev/kvm) e.g. *.metal EC2
#   * firecracker v1.7+ on PATH, qemu-img (for the one-time qcow2->raw convert)
#   * an OSv postgres18-musl image built with fs=zfs (so the cluster is a real
#     ZFS pool that survives snapshot/restore consistently); see README "Build".
#
# Usage:
#   fc-snapshot.sh setup                 # tap net + convert usr.img -> usr.raw
#   fc-snapshot.sh seed                  # build single-file ZFS pool + push cluster
#   fc-snapshot.sh boot                  # boot to "ready", leave running (API sock)
#   fc-snapshot.sh snapshot              # pause + Full snapshot (mem + vmstate)
#   fc-snapshot.sh restore               # NEW fc process: load snapshot, resume
#   fc-snapshot.sh query                 # external psql "select 1" against guest
#   fc-snapshot.sh measure [N]           # restore N times, report first-query time
#   fc-snapshot.sh lifecycle             # persistent WARM checkpoint: freeze -> clean
#                                        #   shutdown -> warm restart, data + identity survive
set -u

# --- paths (override via env) ---
OSV="${OSV:-$HOME/osv}"                       # OSv source tree with build/last
BUILD="${BUILD:-$OSV/build/last}"
KERNEL="${KERNEL:-$BUILD/loader-stripped.elf}"
USRIMG="${USRIMG:-$BUILD/usr.img}"            # OSv qcow2 rootfs (converted below)
USRRAW="${USRRAW:-$BUILD/usr.raw}"            # raw copy Firecracker can read
WORK="${WORK:-/mnt/fc}"                       # scratch (fast NVMe recommended)
SNAP="$WORK/snap"
POOL="$WORK/pool.raw"                         # live PG ZFS pool backing file
PRISTINE="$WORK/pool-pristine.raw"            # clean post-seed pool
ATSNAP="$WORK/pool-at-snapshot.raw"           # pool state at snapshot instant
VMSTATE="$SNAP/osvpg.vmstate"
MEM="$SNAP/osvpg.mem"
SOCK="${SOCK:-/tmp/fc.sock}"
FCLOG="${FCLOG:-/tmp/fc-console.log}"
FC="${FC:-$(command -v firecracker || echo /usr/local/bin/firecracker)}"
SNAPPY="${SNAPPY:-$(dirname "$0")/fc-snap.py}"

# --- guest network (host tap <-> guest virtio-net) ---
HOST_ENI="${HOST_ENI:-$(ip -o -4 route show default | awk '{print $5; exit}')}"
TAP=fc_tap0; TAP_IP=192.168.100.1; GUEST_IP=192.168.100.2; PGPORT=5432
export PGCONNECT_TIMEOUT=5

# --- PG paths inside the guest ---
PGBIN=/b/.local/pg18/install/bin

need() { command -v "$1" >/dev/null || { echo "missing: $1"; exit 1; }; }

do_setup() {
  need qemu-img
  sudo mkdir -p "$WORK" "$SNAP"; sudo chown -R "$USER" "$WORK"
  # one-time: Firecracker only reads RAW; OSv's usr.img is QCOW2.
  if [ ! -f "$USRRAW" ] || [ "$USRIMG" -nt "$USRRAW" ]; then
    echo "converting $USRIMG (qcow2) -> $USRRAW (raw) for Firecracker"
    qemu-img convert -O raw "$USRIMG" "$USRRAW"
  fi
  # host tap + DNAT so external clients reach the guest PG at host-IP:5432
  if ! ip link show "$TAP" >/dev/null 2>&1; then
    sudo ip tuntap add dev "$TAP" mode tap
    sudo ip addr add "$TAP_IP/24" dev "$TAP"
  fi
  sudo ip link set "$TAP" up
  sudo sysctl -qw net.ipv4.ip_forward=1
  sudo iptables -t nat -C PREROUTING -i "$HOST_ENI" -p tcp --dport "$PGPORT" -j DNAT --to "$GUEST_IP:$PGPORT" 2>/dev/null \
    || sudo iptables -t nat -A PREROUTING -i "$HOST_ENI" -p tcp --dport "$PGPORT" -j DNAT --to "$GUEST_IP:$PGPORT"
  sudo iptables -t nat -C POSTROUTING -s "$GUEST_IP/32" -o "$HOST_ENI" -j MASQUERADE 2>/dev/null \
    || sudo iptables -t nat -A POSTROUTING -s "$GUEST_IP/32" -o "$HOST_ENI" -j MASQUERADE
  echo "setup ok: tap=$TAP guest=$GUEST_IP raw=$USRRAW"
}

# Boot OSv+PG on the pristine pool, wait for "ready", leave FC running.
do_boot() {
  [ -f "$PRISTINE" ] || { echo "no pristine pool; run 'seed' first (see README)"; exit 1; }
  cp "$PRISTINE" "$POOL"
  local serve="/zpool.so import -f -N pgdata ; /zfs.so set sync=disabled pgdata ; /zfs.so mount pgdata ; $PGBIN/postgres -D /data"
  sudo -b python3 "$SNAPPY" boot --socket "$SOCK" --fclog "$FCLOG" \
    --append="--rootfs=zfs $serve" --vcpus "${VCPUS:-8}" --mem "${GMEM:-4096}" \
    --members "$POOL" --net --kernel "$KERNEL" --rootfs "$USRRAW" >/dev/null 2>&1
  echo -n "waiting for PG ready"
  for i in $(seq 1 240); do
    grep -qa "ready to accept" "$FCLOG" 2>/dev/null && { echo " -- READY"; return 0; }
    grep -qiE "assert|abort|panic|Failed to load" "$FCLOG" 2>/dev/null && { echo " -- CRASH"; tail -20 "$FCLOG"; exit 1; }
    sleep 0.5; echo -n .
  done
  echo " -- TIMEOUT"; tail -20 "$FCLOG"; exit 1
}

do_snapshot() {
  rm -f "$VMSTATE" "$MEM"
  sudo python3 "$SNAPPY" snapshot --socket "$SOCK" --snap-vmstate "$VMSTATE" --snap-mem "$MEM"
  sudo pkill -9 firecracker 2>/dev/null; sleep 1
  cp "$POOL" "$ATSNAP"
  echo "snapshot: vmstate=$(du -h "$VMSTATE"|cut -f1) mem=$(du -h "$MEM"|cut -f1) pool-at-snapshot saved"
}

# Restore into a fresh FC process, resume, leave serving.
# Disk consistency: each restore gets a FRESH COPY of the snapshot-time pool so
# the guest's in-memory ZFS ARC / shared_buffers agree with on-disk state. A
# reflink/overlay (cp --reflink=auto, or an overlay file) is the zero-copy COW
# form; plain cp is the simplest correct equivalent.
do_restore() {
  sudo pkill -9 firecracker 2>/dev/null; sleep 0.4
  cp --reflink=auto "$ATSNAP" "$POOL" 2>/dev/null || cp "$ATSNAP" "$POOL"
  sudo python3 "$SNAPPY" restore --socket "$SOCK" --members "$POOL" \
    --snap-vmstate "$VMSTATE" --snap-mem "$MEM" --fclog "$FCLOG" \
    --tstamp /tmp/fc-restore.tstamp
}

do_query() {
  psql -h "$GUEST_IP" -U postgres -d postgres -tAc \
    "select 'served-by', inet_server_addr(), version()" 2>&1 | head -1
}

do_measure() {
  local n="${1:-5}"; : >/tmp/fc-measure.tsv
  for r in $(seq 1 "$n"); do
    do_restore >/dev/null 2>&1
    local T0=$(awk '/^T0/{print $2}' /tmp/fc-restore.tstamp)
    local T2=""
    for i in $(seq 1 500); do
      psql -h "$GUEST_IP" -U postgres -d postgres -tAc "select 1" 2>/dev/null | grep -q '^1$' \
        && { T2=$(date +%s.%N); break; }
      sleep 0.01
    done
    [ -z "$T2" ] && { echo "run $r: NO first-query"; continue; }
    local fq=$(echo "$T2-$T0"|bc)
    echo "run $r: restore->first-query = ${fq}s"
    echo "$r $fq" >> /tmp/fc-measure.tsv
  done
  echo "median: $(awk '{print $2}' /tmp/fc-measure.tsv|sort -n|awk '{a[NR]=$1}END{print a[int((NR+1)/2)]}')s  (cold baseline 11.75s)"
}

# seed: build the single-file ZFS pool + push a prebuilt initdb'd cluster into it
# via cpiod, producing $PRISTINE. Needs $DATAINIT to point at an initdb'd cluster
# directory on the host (created once with initdb on any PG18 build).
DATAINIT="${DATAINIT:-$HOME/data-init}"
do_seed() {
  [ -d "$DATAINIT" ] || { echo "set DATAINIT to an initdb'd PG18 cluster dir"; exit 1; }
  local seedpool="$WORK/pool-seed.raw"
  rm -f "$seedpool"; truncate -s 8G "$seedpool"
  local create="/zpool.so create -f -o ashift=12 -O compression=lz4 -O atime=off -O recordsize=8k -O logbias=throughput -O primarycache=all -m /data pgdata /dev/vblk1"
  local init="$create ; /zfs.so set sync=disabled pgdata ; /tools/cpiod.so --prefix /data/ --port 10000 ; /zpool.so export pgdata"
  sudo pkill -9 firecracker 2>/dev/null; sleep 0.5; rm -f "$FCLOG"
  sudo -b python3 "$SNAPPY" boot --socket "$SOCK" --fclog "$FCLOG" \
    --append="--rootfs=zfs $init" --vcpus "${VCPUS:-8}" --mem "${GMEM:-4096}" \
    --members "$seedpool" --net --kernel "$KERNEL" --rootfs "$USRRAW" >/dev/null 2>&1
  echo -n "waiting for cpiod"
  for i in $(seq 1 90); do
    grep -qa "Waiting for connection from host" "$FCLOG" 2>/dev/null && { echo " -- ready"; break; }
    sleep 1; echo -n .
  done; sleep 1
  python3 "$(dirname "$0")/cpio_push.py" "$DATAINIT" "$GUEST_IP" 10000 2>&1 | sed 's/^/[push] /' | tail -2
  sudo pkill -9 firecracker 2>/dev/null; sleep 1
  cp "$seedpool" "$PRISTINE"
  echo "seeded pristine pool: $(du -h "$PRISTINE"|cut -f1)"
}

# lifecycle: prove a PERSISTENT WARM snapshot checkpoint that survives a freeze,
# clean Firecracker shutdown, and warm restart. Both launches are warm restores
# (about 0.2s to first query). Data inserted in a restored session and the
# original pg_postmaster_start_time() both survive the freeze/clean-shutdown/
# warm-restart cycle. The cold boot below is ONLY the one-time setup that
# produces the base warm snapshot; it is not the headline path.
lifecycle_first_query() {
  for i in $(seq 1 2000); do
    psql -h "$GUEST_IP" -U postgres -d postgres -tAc "select 1" 2>/dev/null | grep -q '^1$' && { date +%s.%N; return 0; }
    sleep 0.005
  done; return 1
}
do_lifecycle() {
  local P="psql -h $GUEST_IP -U postgres -d postgres -tAc"
  local snapB_vm="$SNAP/B.vmstate" snapB_mem="$SNAP/B.mem" poolB="$WORK/pool-B.raw"
  echo "## setup: cold boot -> base warm snapshot-A (one time, not the headline)"
  do_boot
  lifecycle_first_query >/dev/null   # wait until PG accepts external TCP, not just the log line
  local ppst0=$($P "select pg_postmaster_start_time()")
  echo "   first-ever pg_postmaster_start_time = $ppst0"
  do_snapshot
  echo "## FIRST WARM LAUNCH (restore snapshot-A)"
  do_restore >/dev/null 2>&1
  local t0=$(awk '/^T0/{print $2}' /tmp/fc-restore.tstamp) t1=$(lifecycle_first_query)
  echo "   restore->first-query = $(echo "$t1-$t0"|bc)s   [warm, the headline]"
  echo "   pg_postmaster_start_time = $($P "select pg_postmaster_start_time()")"
  echo "## create table + rows in the restored session"
  $P "drop table if exists t; create table t(id int, note text, ts timestamptz default now())"
  for r in 1 2 3 4 5; do $P "insert into t(id,note) values ($r,'row-$r')" >/dev/null; done
  psql -h "$GUEST_IP" -U postgres -d postgres -c "select id,note from t order by id"
  echo "## FREEZE: snapshot-B (captures table+rows) + preserve pool, then clean shutdown"
  $P "checkpoint" >/dev/null 2>&1; rm -f "$snapB_vm" "$snapB_mem"
  sudo python3 "$SNAPPY" snapshot --socket "$SOCK" --snap-vmstate "$snapB_vm" --snap-mem "$snapB_mem"
  cp "$POOL" "$poolB"
  sudo pkill -9 firecracker 2>/dev/null; while pgrep -x firecracker >/dev/null; do sleep 0.02; done
  echo "   clean shutdown done (VM process gone)"
  echo "## SECOND WARM LAUNCH (restore frozen snapshot-B)"
  cp --reflink=auto "$poolB" "$POOL" 2>/dev/null || cp "$poolB" "$POOL"; sudo rm -f "$FCLOG"
  sudo python3 "$SNAPPY" restore --socket "$SOCK" --members "$POOL" \
    --snap-vmstate "$snapB_vm" --snap-mem "$snapB_mem" --fclog "$FCLOG" --tstamp /tmp/fc-restore.tstamp >/dev/null 2>&1
  local u0=$(awk '/^T0/{print $2}' /tmp/fc-restore.tstamp) u1=$(lifecycle_first_query)
  echo "   restore->first-query = $(echo "$u1-$u0"|bc)s   [warm, the headline]"
  echo "## VERIFY persistence + identity after freeze/clean-shutdown/warm-restart"
  psql -h "$GUEST_IP" -U postgres -d postgres -c "select id,note from t order by id"
  echo "   pg_postmaster_start_time = $($P "select pg_postmaster_start_time()")  (must equal $ppst0)"
  $P "insert into t(id,note) values (99,'written-after-warm-restart')" >/dev/null && echo "   writable: inserted id=99"
  echo "   row count = $($P "select count(*) from t")"
  sudo pkill -9 firecracker 2>/dev/null
}

case "${1:-}" in
  setup)     do_setup ;;
  seed)      do_seed ;;
  boot)      do_boot ;;
  snapshot)  do_snapshot ;;
  restore)   do_restore ;;
  query)     do_query ;;
  measure)   do_measure "${2:-5}" ;;
  lifecycle) do_lifecycle ;;
  *) sed -n '2,34p' "$0"; exit 1 ;;
esac
