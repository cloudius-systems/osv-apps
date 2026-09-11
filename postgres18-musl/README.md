# postgres18-musl

Stock **PostgreSQL 18** (branch `REL_18_STABLE`) built from source with the
**musl** C toolchain as an OSv position-independent executable, booting on OSv
and serving SQL over TCP.

This is a demo: it boots a small baked cluster and answers `psql` queries over
the guest's forwarded port. It is deliberately single-backend-safe (see
[Status](#status)).

## What it does

1. `build.sh` fetches the PostgreSQL 18 source, builds it with `musl-gcc`,
   `initdb`s a small demo cluster containing a `demo` database with a
   `greetings` table, and lays the install tree + baked cluster out for the
   image manifest.
2. At boot, `module.py` mounts a writable ramfs over `/data`, copies the
   read-only baked cluster from `/data-seed` (on rofs) into it with the tiny
   `seed_copy` helper, then starts `postgres -D /data`.
3. PostgreSQL listens on TCP `0.0.0.0:5432` and serves queries.

## Build & run

From the top-level OSv directory (this app lives under `apps/`):

```bash
# Build the OSv image with this app.  conf_fork=1 pulls in OSv's fork/COW
# cross-address-space coherence (PostgreSQL's postmaster forks a backend per
# connection).  fs=ramfs makes the root (and thus the writable /data) a ramfs.
./scripts/build -j$(nproc) conf_fork=1 fs=ramfs image=postgres18-musl

# Boot under KVM, forwarding the guest's 5432 to the host (fork needs >=2 vCPUs):
./scripts/run.py -c2 -nvV --forward tcp::5432-:5432

# From the host, query the demo over the forwarded port:
psql -h 127.0.0.1 -p 5432 -U postgres -d demo -c 'select * from greetings;'
```

> **OSv kernel requirement.** PostgreSQL forks a backend per connection, so this
> demo needs the OSv fork/COW cross-address-space coherence work (`conf_fork=1`,
> plus the DSM/POSIX-shm-registry, ramfs, net-stack, mbuf and thread-stack
> identity-heap fixes). On an OSv tree without those, the postmaster boots but a
> forked backend hits `could not open shared memory segment` (DSM ENOENT) and no
> query is served. Those fixes are a separate OSv kernel effort (fork-arena /
> PR #1455 line of work); this app is the userspace half of the demo.

Expected output:

```
 id |    who     |          msg
----+------------+------------------------
  1 | osv        | hello from a unikernel
  2 | postgres18 | stock musl build
  3 | demo       | this row came over TCP
(3 rows)
```

## Snapshot / restore (Firecracker) -- boot once, resume already-serving

Booting PostgreSQL is not free: on OSv the musl PIE `postgres` install tree is
memory-mapped and the process initialized on every cold boot, which dominates
launch time. Firecracker full-VM snapshots let you pay that **once**: boot
OSv+PostgreSQL to "ready to accept connections", snapshot the whole VM (guest
memory + device/vCPU state), and on every later launch **restore** that
snapshot so PostgreSQL is *already serving* -- no reboot, no re-`initdb`, no
re-mmap.

### Measured, real numbers

Measured on an `m5d.metal` EC2 instance (AL2023, Firecracker v1.7.0, OSv v0.57
with PostgreSQL 18.4-musl + OpenZFS 2.4.3, a single-file ZFS pool at
`recordsize=8k`, guest `select 1` over the real virtio-net path):

| Path | launch -> first external `select 1` |
|---|---|
| **cold** boot (kernel + ZFS import + PG mmap/init + ready + first query) | **11.75 s** |
| **restore** from a Full snapshot | **0.24 s** (median of 5; range 0.234-0.244) |

That is **~48x faster**; the ~6.7 s PostgreSQL musl-PIE mmap+init is eliminated
because it is baked into the snapshotted memory. The Firecracker resume itself
(load + resume) is ~0.05 s; the rest is the first TCP query round-trip.

Cold-boot breakdown (for reference): kernel 0.61 s, ZFS import+mount 0.71 s, PG
spawn+init **6.70 s**, PG start->ready 0.28 s, ready->first query ~1.4 s.

### How to snapshot and restore

`fc-snapshot.sh` (with its helper `fc-snap.py`, which drives Firecracker's HTTP
API over a unix socket) automates the flow. It needs a bare-metal host
(`/dev/kvm`), `firecracker` v1.7+, and `qemu-img`.

```bash
# 0. Build a ZFS-rooted image so the cluster is a real ZFS pool that stays
#    consistent across snapshot/restore (ramfs would not survive a restore
#    as a real filesystem). fork/COW is still required for the forked backends.
./scripts/build -j$(nproc) conf_fork=1 fs=zfs conf_zfs=openzfs image=postgres18-musl

cd apps/postgres18-musl

# 1. One-time host setup: bring up the tap+DNAT and convert the OSv qcow2
#    rootfs to raw (Firecracker only reads RAW block devices).
sudo ./fc-snapshot.sh setup

# 2. Seed a single-file ZFS pool with an initdb'd PG18 cluster (once). Point
#    DATAINIT at an initdb'd cluster directory on the host; the pool is created
#    in-guest and the cluster is cpiod-pushed into /data, then exported and
#    saved as pool-pristine.raw.
DATAINIT=$HOME/data-init sudo -E ./fc-snapshot.sh seed

# 3. Boot to "ready", then take a Full snapshot (memory + vmstate):
sudo ./fc-snapshot.sh boot
sudo ./fc-snapshot.sh snapshot     # -> snap/osvpg.vmstate (~90 KB) + snap/osvpg.mem

# 4. Restore + verify PG is already serving (no reboot):
sudo ./fc-snapshot.sh restore
sudo ./fc-snapshot.sh query        # select 1 returns immediately

# 5. Benchmark restore -> first query (median of N restores):
sudo ./fc-snapshot.sh measure 5

# 6. Persistent WARM checkpoint lifecycle: first warm launch, insert data in
#    the restored session, FREEZE (snapshot-B + preserve pool), CLEANLY shut
#    Firecracker down, then a SECOND warm launch from the frozen state. The
#    table, its rows, and the original pg_postmaster_start_time() all survive.
sudo ./fc-snapshot.sh lifecycle
```

The snapshot is two files: a tiny **vmstate** (device + vCPU state, ~90 KB) and
a **mem** file the size of the guest RAM (dense). Boot the guest with a small
`GMEM` (e.g. 2-4 GiB, matched to `shared_buffers` + working set) to keep the
mem file small; the memory is mostly zero pages and compresses heavily (a 16
GiB dump gzipped to ~160 MB in testing). Firecracker diff snapshots shrink it
further.

### Persistent warm checkpoint (freeze -> clean shutdown -> warm restart)

A Firecracker Full snapshot is an immutable restore-as-template. To freeze new
work and keep it warm across a full process shutdown you take a FRESH snapshot
after the work and preserve the ZFS backing file at that instant. The
`lifecycle` subcommand demonstrates the whole cycle and times it:

1. Cold boot once to build the base warm snapshot-A (setup only, not the
   headline).
2. FIRST warm launch: restore snapshot-A. Restore to first `select 1` is about
   0.2 s.
3. In the restored session, create a table and insert rows.
4. FREEZE: take snapshot-B (captures the table and rows in guest memory),
   preserve the pool backing file, then cleanly kill Firecracker so the VM
   process is gone.
5. SECOND warm launch: a fresh Firecracker process loads snapshot-B and
   resumes. Restore to first `select 1` is again about 0.2 s.
6. The table, all its rows, and the original `pg_postmaster_start_time()` are
   all still there, and PostgreSQL is writable.

Measured on m5d.metal (Firecracker v1.7, 4 GiB guest, single-file ZFS pool):
both warm launches were about 0.17 s to first query, and
`pg_postmaster_start_time()` stayed equal to the very first launch across every
freeze/clean-shutdown/warm-restart cycle. The instance identity and its data
survive the freeze/thaw.

### Disk consistency (memory <-> disk must agree)

A restored guest's in-memory ZFS ARC, PostgreSQL `shared_buffers`, and dirty
pages reflect the disk **as of the snapshot instant**. The pool backing file
must match. `fc-snapshot.sh` copies the exact pool file at snapshot time to
`pool-at-snapshot.raw` and gives **every restore a fresh copy** (via
`cp --reflink=auto`, a copy-on-write clone on reflink-capable filesystems such
as XFS/Btrfs/ZFS; it falls back to a plain copy elsewhere). This is the
zero-/low-copy COW overlay approach: memory and disk always agree, and each
restored clone gets an isolated writable pool. Verified: a row `INSERT`ed
*before* the snapshot is readable *after* restore, `CHECKPOINT` flushes, and
cold table reads serve -- memory + disk state genuinely resumed.

### Gotchas (honest)

- **Clock skew.** A restored guest wakes "in the past" relative to the host
  wall clock. In testing OSv's `kvmclock` re-reads the KVM pvclock/wall-clock
  MSRs on resume (there is a 1 Hz wall-clock sync thread), so the guest clock
  re-tracks the host with only a **small, stable offset (~50-85 ms ahead)** --
  no backward jump, no timer storm, no hang. PostgreSQL timestamps are correct.
  Tolerated with no OSv change. If sub-millisecond accuracy on the very first
  post-resume tick is ever required, force an immediate kvmclock resync instead
  of waiting up to 1 s for the sync thread.
- **virtio device re-attach.** Firecracker restores virtio-net/virtio-blk
  device + virtqueue state, but the **host** side must pre-exist identically:
  the `fc_tap0` tap and the DNAT rules must already be up on the restoring host
  (`fc-snapshot.sh setup` establishes them; they persist). After restore a
  fresh TCP connection completes through the restored virtio-net, and
  virtio-blk serves reads/writes + `CHECKPOINT`.
- **RNG / entropy.** Two restores from the *same* snapshot produced different
  `random()` and `gen_random_uuid()` values (no observable duplication at the
  app layer). This is only a weak probe, though -- a security-sensitive clone
  fleet should add an explicit OS-entropy reseed on resume so cloned VMs cannot
  share RNG state.

### Does OSv resume cleanly?  Yes -- no OSv changes needed.

OSv v0.57 (the full PG-serving fix stack) resumes cleanly from a Firecracker
Full snapshot with a live PostgreSQL+OpenZFS workload: **no core fault, no
clock discontinuity, no virtio re-attach failure, no IRQ/APIC re-arm bug**. The
definitive proof that it is a resume and not a reboot: `pg_postmaster_start_time()`
after restore reports the *original* pre-snapshot boot time, not the restore
wall clock -- the postmaster and its timers continue, never restart. This demo
therefore does **not** depend on any new OSv kernel change for correct resume.
(The two optional hardening items above -- RNG reseed, immediate clock resync
-- are not required for correctness here and would be separate OSv kernel PRs
if a production clone fleet ever needs them.)

> One deployment gotcha that is **not** an OSv bug: OSv's `usr.img` is a QCOW2
> image and Firecracker only accepts RAW block devices. Convert once with
> `qemu-img convert -O raw usr.img usr.raw` (`fc-snapshot.sh setup` does this).
> Skipping it makes the ZFS root import fail (`spa_import_rootpool ... failed: 5`).

## OSv deviations from stock PostgreSQL

Every deviation below is an **OSv-workaround**, not an improvement to
PostgreSQL. Each exists only because a current OSv capability gap forces it,
and each is tracked to be **erased** as those gaps close. Nothing here changes
PostgreSQL's on-disk format or SQL behavior.

**Build flags** (`build.sh`, step 3):

| Deviation | Why | Erase when |
|---|---|---|
| `CC=musl-gcc` | OSv's libc is musl | n/a (intrinsic to the musl target) |
| `--without-icu/zlib/readline/lz4/zstd/libxml` | those libs are not baked into the demo image | those libs are packaged for OSv |
| `-DWAIT_USE_SELF_PIPE` | OSv's epoll/signalfd latch path is incomplete; use PostgreSQL's portable self-pipe latch | OSv latch path is complete |
| `LDFLAGS_EX=-pie` | OSv runs applications as PIEs | n/a (intrinsic to OSv) |

**Source neuters** (`build.sh`, step 2 -- two one-line `if (0 && ...)` guards):

| Deviation | Why | Erase when |
|---|---|---|
| `check_root()` in `main.c` | OSv runs the app as uid 0; there is no unprivileged user to drop to | OSv models an unprivileged user |
| `checkDataDir()` perms in `miscinit.c` | OSv filesystems do not report Unix-style directory modes | OSv fs reports Unix modes |

**Cluster config** (`build.sh`, step 5, baked into `postgresql.conf`/`pg_hba.conf`):

| Deviation | Why | Erase when |
|---|---|---|
| `initdb --locale=C` | musl provides only the C locale | musl locale support lands |
| `io_method = sync` | OSv's async-I/O (io_uring/worker) path is incomplete | OSv AIO path is complete |
| `unix_socket_directories = ''` | OSv has no AF_UNIX | OSv AF_UNIX support lands |
| `listen_addresses = '*'` + `pg_hba trust` | demo reachability over the forwarded TCP port | it's a demo (ephemeral ramfs cluster) |

## Status

- **Works: single-backend query serving.** The demo boots PostgreSQL to
  "database system is ready to accept connections" and serves real SQL
  (`SELECT`, DDL, DML, aggregates) over TCP. Sequential `psql` connections are
  reliable.
- **WIP: sustained multi-backend concurrency.** PostgreSQL's postmaster forks a
  backend per connection, and OSv's `fork()`/COW cross-address-space coherence
  is still being hardened (a separate OSv kernel effort). A demo doing
  sequential queries is fine; hammering it with many concurrent connections can
  trip the fork/reap lifecycle wall. This app is intentionally scoped to the
  single-backend demo.

## Files

- `Makefile` -- osv-apps entry point; runs `build.sh`.
- `build.sh` -- fetch + build PostgreSQL, build `seed_copy`, `initdb` the demo
  cluster, emit `usr.manifest`.
- `seed_copy.c` -- boot-time recursive rofs→ramfs copy helper (libc only).
- `module.py` -- boot command (mount ramfs, seed_copy, run postgres).
- `usr.manifest` -- generated by `build.sh`; maps the build output into the image.
- `fc-snapshot.sh` -- Firecracker snapshot/restore driver (boot-once,
  resume-already-serving). See "Snapshot / restore" above.
- `fc-snap.py` -- helper that drives Firecracker's HTTP API (boot / Full
  snapshot / restore+resume) over a unix socket.
