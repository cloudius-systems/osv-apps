#!/bin/bash
#
# Build stock musl PostgreSQL 18 as an OSv PIE and bake a small demo cluster.
#
# Runs inside the OSv build container (fedora:39 with musl-gcc).  Produces:
#   install/            -- the PostgreSQL install tree (bin, lib, share)
#   install/data-seed/  -- a baked demo cluster (read-only at runtime on rofs)
#   seed_copy           -- the boot-time rofs->ramfs copy helper
#   usr.manifest        -- maps the above into the OSv image
#
# Everything below "OSv deviation" is a workaround for a current OSv gap, kept
# minimal and documented, and expected to be erased as those gaps close.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PG_BRANCH="${PG_BRANCH:-REL_18_STABLE}"
SRC="$HERE/src"
BUILD="$HERE/build"
PREFIX="$HERE/install"
SEED="$PREFIX/data-seed"
JOBS="${JOBS:-$(nproc)}"

: "${CC:=musl-gcc}"
export CC

# ---------------------------------------------------------------------------
# 1. Fetch the PostgreSQL 18 source.
# ---------------------------------------------------------------------------
if [ ! -f "$SRC/configure" ]; then
	echo "== fetching PostgreSQL $PG_BRANCH =="
	rm -rf "$SRC"
	TARBALL="$HERE/postgres-$PG_BRANCH.tar.gz"
	[ -f "$TARBALL" ] || wget -q -O "$TARBALL" \
		"https://github.com/postgres/postgres/archive/refs/heads/$PG_BRANCH.tar.gz"
	mkdir -p "$SRC"
	tar xzf "$TARBALL" -C "$SRC" --strip-components=1
fi

# ---------------------------------------------------------------------------
# 2. OSv deviation: neuter two host-environment checks.
#
#    OSv runs the unikernel application as uid 0 (there is no unprivileged user
#    to drop to) and its filesystems do not report Unix-style directory perms,
#    so PostgreSQL's two startup safety checks reject a perfectly valid OSv
#    environment.  We disable exactly those two checks and nothing else.  Both
#    edits are idempotent (skipped if already applied).
# ---------------------------------------------------------------------------
python3 - "$SRC" <<'PY'
import sys, io
src = sys.argv[1]

# 2a. check_root() in main.c -- allow uid 0.
p = src + "/src/backend/main/main.c"
s = io.open(p).read()
needle = '\tif (geteuid() == 0)\n\t{\n\t\twrite_stderr("\\"root\\" execution'
repl   = '\t/* OSv: unikernel app runs as uid 0; no unprivileged user. */\n\tif (0 && geteuid() == 0)\n\t{\n\t\twrite_stderr("\\"root\\" execution'
if repl not in s:
    assert s.count(needle) == 1, ("main.c check_root: matches=%d" % s.count(needle))
    io.open(p, "w").write(s.replace(needle, repl))
    print("patched main.c check_root")
else:
    print("main.c check_root already patched")

# 2b. checkDataDir() perm check in miscinit.c -- OSv fs modes are not Unix-y.
p = src + "/src/backend/utils/init/miscinit.c"
s = io.open(p).read()
needle = "\tif (stat_buf.st_mode & PG_MODE_MASK_GROUP)\n"
repl   = "\t/* OSv: filesystem modes are not Unix-y; suppress the perms check. */\n\tif (0 && (stat_buf.st_mode & PG_MODE_MASK_GROUP))\n"
if repl not in s:
    assert s.count(needle) == 1, ("miscinit.c checkDataDir: matches=%d" % s.count(needle))
    io.open(p, "w").write(s.replace(needle, repl))
    print("patched miscinit.c checkDataDir")
else:
    print("miscinit.c checkDataDir already patched")
PY

# ---------------------------------------------------------------------------
# 3. Configure + build with musl-gcc as a PIE.
#
#    OSv deviations in the build flags:
#      CC=musl-gcc            -- OSv's libc is musl; build against it.
#      --without-icu/zlib/    -- avoid optional libs not baked into the image
#        readline/lz4/zstd       (keeps the demo self-contained; add back once
#                                 those libs are packaged for OSv).
#      -DWAIT_USE_SELF_PIPE   -- OSv's epoll/signalfd latch path is not complete;
#                                force PostgreSQL's portable self-pipe latch.
#      LDFLAGS_EX=-pie        -- OSv runs applications as position-independent
#                                executables.
# ---------------------------------------------------------------------------
echo "== configuring (CC=$CC) =="
if [ -x "$PREFIX/bin/postgres" ]; then
	echo "== postgres already built, skipping configure/make (rm -rf install to force) =="
else
	rm -rf "$BUILD" "$PREFIX"
	mkdir -p "$BUILD"
	cd "$BUILD"

	# On aarch64, GCC 13 libgcc's LSE-atomics runtime init (lse-init.o)
	# references glibc's __getauxval, which musl does not export -- every link
	# then fails and PG's configure cannot detect the GCC atomic builtins.
	# -mno-outline-atomics disables that runtime-detection path (emit the LSE/
	# LL-SC atomics inline instead), which links cleanly against musl.
	ARCH_CFLAGS=''
	if [ "$(uname -m)" = "aarch64" ]; then ARCH_CFLAGS='-mno-outline-atomics'; fi
	CFLAGS="-O2 -g -fPIC -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -DWAIT_USE_SELF_PIPE $ARCH_CFLAGS -idirafter /usr/include"
	"$SRC/configure" \
		--prefix="$PREFIX" \
		--without-icu --without-zlib --without-readline \
		--without-libxml --without-lz4 --without-zstd \
		CFLAGS="$CFLAGS" >/tmp/pg-configure.log 2>&1 || { tail -20 /tmp/pg-configure.log; exit 1; }

	echo "== building (-j$JOBS) =="
	# A fully clean parallel build can race src/common ahead of the generated
	# catalog/error-code headers; generate those serially first.
	make -C src/backend generated-headers >/tmp/pg-genhdr.log 2>&1 || { tail -20 /tmp/pg-genhdr.log; exit 1; }
	make -j"$JOBS" LDFLAGS_EX='-pie' >/tmp/pg-make.log 2>&1 || { tail -30 /tmp/pg-make.log; exit 1; }
	make install >/tmp/pg-install.log 2>&1 || { tail -20 /tmp/pg-install.log; exit 1; }
fi
echo "== built: $(file "$PREFIX/bin/postgres" | cut -d: -f2-) =="

# ---------------------------------------------------------------------------
# 4. Build the seed_copy boot helper (rofs -> ramfs cluster copy).
# ---------------------------------------------------------------------------
echo "== building seed_copy =="
"$CC" -O2 -fPIC -pie -o "$HERE/seed_copy" "$HERE/seed_copy.c"

# ---------------------------------------------------------------------------
# 5. Initialize a small demo cluster (runs natively in the build container).
#
#    OSv deviations baked into the cluster:
#      initdb --locale=C      -- musl has only the C locale.
#      io_method = sync       -- conservative default for the demo cluster.
#                                io_method=worker is verified working on OSv
#                                (three IO worker processes fork and serve
#                                normally); io_method=io_uring is untested here
#                                and additionally needs --with-liburing at
#                                configure time plus liburing in the image.
#                                io_method is PGC_POSTMASTER, so any of the three
#                                can be selected at run time from this one build
#                                with `-c io_method=...` without rebuilding.
#      unix_socket_directories = ''  -- OSv has no AF_UNIX; TCP only.
#      listen_addresses = '*' + pg_hba trust  -- so the demo is reachable over
#                                the guest's forwarded TCP port for `psql -h`.
#
#    initdb/postgres refuse to run as root (a build-container concern, not an
#    OSv one -- on OSv the neuter in step 2 handles uid 0).  If we are root,
#    create/reuse an unprivileged 'pgbuild' user and run the cluster init as
#    that user, owning $SEED.
# ---------------------------------------------------------------------------
echo "== initdb demo cluster =="
rm -rf "$SEED"
mkdir -p "$SEED"
export LC_ALL=C LANG=C

PGRUN=""
if [ "$(id -u)" = 0 ]; then
	id pgbuild >/dev/null 2>&1 || useradd -m pgbuild
	chown -R pgbuild "$SEED" "$HERE" 2>/dev/null || true
	PGRUN="runuser -u pgbuild --"
fi

$PGRUN "$PREFIX/bin/initdb" -D "$SEED" -U postgres --locale=C -E UTF8 \
	>/tmp/pg-initdb.log 2>&1 || { tail -30 /tmp/pg-initdb.log; exit 1; }

cat >> "$SEED/postgresql.conf" <<'CONF'

# --- OSv demo settings (see README) ---
listen_addresses = '*'          # reachable over forwarded TCP
port = 5432
unix_socket_directories = ''    # OSv has no AF_UNIX
io_method = sync                # demo default; worker is verified working on
                                # OSv, and io_method is PGC_POSTMASTER so it can
                                # be overridden at run time with -c io_method=...
fsync = on
CONF

# Trust auth for the demo (single, local, ephemeral cluster over the demo port).
cat > "$SEED/pg_hba.conf" <<'HBA'
# OSv demo: trust auth. The cluster is ephemeral (ramfs) and only reachable
# over the guest's forwarded TCP port. Do not use trust in production.
host all all 0.0.0.0/0 trust
host all all ::/0      trust
HBA

# Seed a demo database + table with a few rows, using a throwaway local
# postmaster over a TCP port (AF_UNIX is unavailable here too, to match OSv).
echo "== seeding demo data =="
$PGRUN "$PREFIX/bin/pg_ctl" -D "$SEED" -o "-p 55432 -k '' -h 127.0.0.1" -w start \
	>/tmp/pg-seed-start.log 2>&1 || { tail -30 /tmp/pg-seed-start.log; exit 1; }
$PGRUN "$PREFIX/bin/psql" -h 127.0.0.1 -p 55432 -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE DATABASE demo;
\connect demo
CREATE TABLE greetings (id serial PRIMARY KEY, who text, msg text);
INSERT INTO greetings (who, msg) VALUES
  ('osv',        'hello from a unikernel'),
  ('postgres18', 'stock musl build'),
  ('demo',       'this row came over TCP');
SQL
$PGRUN "$PREFIX/bin/pg_ctl" -D "$SEED" -w stop >/tmp/pg-seed-stop.log 2>&1

# OSv manifest globs (**) only capture files, so empty cluster subdirectories
# (pg_notify, pg_dynshmem, pg_wal/archive_status, pg_tblspc, ...) would be
# dropped from the baked /data-seed and PostgreSQL would fail at startup with
# ENOENT.  Drop a .keep marker into each empty dir so the manifest carries it;
# seed_copy recreates the directory in the writable /data and skips the marker
# itself (so pg_tblspc, where PostgreSQL treats any entry as a tablespace, ends
# up as a clean empty directory).
find "$SEED" -type d -empty -exec touch {}/.keep \;

# ---------------------------------------------------------------------------
# 6. Emit usr.manifest -- maps the build output into the OSv image.
#    All paths are relative to this module dir ($${MODULE_DIR}); no absolute
#    build-machine paths.  /data is an empty mount point the boot command
#    mounts a ramfs over and seed_copy fills from /data-seed.
# ---------------------------------------------------------------------------
echo "== writing usr.manifest =="
mkdir -p "$HERE/emptydir"
cat > "$HERE/usr.manifest" <<'MAN'
# musl PostgreSQL 18 on OSv -- demo module.
# The read-only cluster is baked at /data-seed; at boot seed_copy copies it into
# a writable ramfs at /data (see module.py).
/usr/bin/postgres: ${MODULE_DIR}/install/bin/postgres
/usr/bin/seed_copy: ${MODULE_DIR}/seed_copy
/usr/lib/**: ${MODULE_DIR}/install/lib/**
/usr/share/**: ${MODULE_DIR}/install/share/**
/data-seed/**: ${MODULE_DIR}/install/data-seed/**
# empty mount point for the writable ramfs /data (rofs cannot mkdir at runtime)
/data: ${MODULE_DIR}/emptydir
MAN

echo "== done. postgres18-musl app built. =="
