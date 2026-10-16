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
# Pin PostgreSQL to an exact commit for reproducibility (a branch head moves).
# PG_COMMIT is immutable; the sha256 is a best-effort check (GitHub may
# regenerate the archive bytes, so a mismatch warns rather than fails, and the
# commit is the real pin).  Override PG_COMMIT to build a different revision.
PG_COMMIT="${PG_COMMIT:-10b2d9986b958b413d169b30ea43ae32a405bc72}"  # REL_18_STABLE 2026-10-16
PG_SHA256="66dd62850e216ebdd476f42ae251be1f1f5ed0106e313c01e3bc6a80397f5084"
SRC="$HERE/src"
BUILD="$HERE/build"
PREFIX="$HERE/install"
SEED="$PREFIX/data-seed"
JOBS="${JOBS:-$(nproc)}"

# Stage 4: build --with-icu against the Stage 3 ICU osv-apps module. ICU is
# installed by the sibling apps/icu module (shared libs + data, built with the
# host g++ toolchain). We wire it in with explicit ICU_CFLAGS/ICU_LIBS rather
# than pkg-config, because the musl-gcc build sysroot does not see the host
# pkg-config path. ICU_HOME can override the location (default: ../icu/install).
ICU_HOME="${ICU_HOME:-$HERE/../icu/install}"

: "${CC:=musl-gcc}"
export CC

# ---------------------------------------------------------------------------
# 1. Fetch the PostgreSQL 18 source.
# ---------------------------------------------------------------------------
if [ ! -f "$SRC/configure" ]; then
	echo "== fetching PostgreSQL commit $PG_COMMIT =="
	rm -rf "$SRC"
	TARBALL="$HERE/postgres-$PG_COMMIT.tar.gz"
	[ -f "$TARBALL" ] || wget -q -O "$TARBALL" \
		"https://github.com/postgres/postgres/archive/$PG_COMMIT.tar.gz"
	if ! echo "$PG_SHA256  $TARBALL" | sha256sum -c - >/dev/null 2>&1; then
		echo "warning: $TARBALL sha256 != $PG_SHA256 (GitHub may have regenerated the archive; the commit $PG_COMMIT is the pin)" >&2
	fi
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
#      --with-icu             -- Stage 4: ICU collation provider, from the
#                                apps/icu module. ICU_CFLAGS/ICU_LIBS point at
#                                its install tree (set below); OSv's loader
#                                resolves ICU's glibc-ABI shared objects (and
#                                libstdc++) at runtime, same as the icu smoke
#                                test. The ICU libs/data are baked into the
#                                image by the icu module (api.require('icu')).
#      --without-zlib/        -- avoid optional libs not baked into the image
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
	# musl-gcc builds with -nostdinc, so the kernel UAPI headers under the
	# multiarch dir (/usr/include/<triplet>/asm, needed by <linux/fs.h> in e.g.
	# pg_combinebackup) are not on the search path. Add the triplet include dir
	# with -idirafter so those asm/* headers resolve (host-sysroot fix, not an
	# OSv one; independent of --with-icu).
	MULTIARCH="$($CC -print-multiarch 2>/dev/null)"
	MULTIARCH_CFLAGS=''
	[ -n "$MULTIARCH" ] && [ -d "/usr/include/$MULTIARCH" ] && \
		MULTIARCH_CFLAGS="-idirafter /usr/include/$MULTIARCH"
	# Allow the optimisation and debug flags to be overridden, so that a build
	# for profiling can ask for -fno-omit-frame-pointer or a lower -O without
	# editing this file.  Unset, these expand to the flags used before.
	PG_OPT_CFLAGS="${PG_OPT_CFLAGS:--O2 -g}"
	CFLAGS="$PG_OPT_CFLAGS -fPIC -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -DWAIT_USE_SELF_PIPE $ARCH_CFLAGS -idirafter /usr/include $MULTIARCH_CFLAGS${PG_EXTRA_CFLAGS:+ $PG_EXTRA_CFLAGS}"

	# Point --with-icu at the Stage 3 ICU install. PostgreSQL's configure
	# tries pkg-config first and falls back to ICU_CFLAGS/ICU_LIBS; we set
	# both explicitly so the musl-gcc build finds ICU without a sysroot
	# pkg-config path. ICU exposes a C API (ucol_*, u_*) in libicui18n/
	# libicuuc that PG links; the C++ runtime deps resolve on OSv at runtime.
	if [ ! -f "$ICU_HOME/lib/libicui18n.so" ] && \
	   [ -z "$(ls "$ICU_HOME"/lib/libicui18n.so.* 2>/dev/null)" ]; then
		echo "== ERROR: ICU not found at $ICU_HOME; build the apps/icu module first ==" >&2
		exit 1
	fi
	ICU_CFLAGS="-I$ICU_HOME/include"
	ICU_LIBS="-L$ICU_HOME/lib -licui18n -licuuc -licudata"
	"$SRC/configure" \
		--prefix="$PREFIX" \
		--with-icu --without-zlib --without-readline \
		--without-libxml --without-lz4 --without-zstd \
		ICU_CFLAGS="$ICU_CFLAGS" ICU_LIBS="$ICU_LIBS" \
		CFLAGS="$CFLAGS" >/tmp/pg-configure.log 2>&1 || { tail -30 /tmp/pg-configure.log; exit 1; }

	echo "== building (-j$JOBS) =="
	# A fully clean parallel build can race src/common ahead of the generated
	# catalog/error-code headers; generate those serially first.
	make -C src/backend generated-headers >/tmp/pg-genhdr.log 2>&1 || { tail -20 /tmp/pg-genhdr.log; exit 1; }
	make -j"$JOBS" LDFLAGS_EX='-pie' >/tmp/pg-make.log 2>&1 || { tail -30 /tmp/pg-make.log; exit 1; }
	make install >/tmp/pg-install.log 2>&1 || { tail -20 /tmp/pg-install.log; exit 1; }
fi
echo "== built: $(file "$PREFIX/bin/postgres" | cut -d: -f2-) =="

# ---------------------------------------------------------------------------
# 3b. Seed-only glibc build of the SAME PostgreSQL source.
#
#     The cluster is baked by running initdb/postgres on the build host. The
#     shipped postgres is musl-linked, but ICU is a C++ (glibc-ABI) shared
#     library, and the host's musl loader cannot load a glibc C++ .so in the
#     same process (two libcs). So we build a throwaway GLIBC copy of the same
#     source, linked against the SAME ICU, purely to run initdb and seed the
#     cluster here; it is never shipped. On OSv the shipped musl postgres opens
#     that cluster (the on-disk format is independent of the build libc, and it
#     uses the same ICU 78.3, so the ICU collation version matches). This whole
#     step vanishes once initdb can run on OSv (it currently cannot: OSv stubs
#     popen(), which initdb uses for its `postgres -V` version check).
# ---------------------------------------------------------------------------
SEED_PREFIX="$HERE/install-seed"
SEED_BUILD="$HERE/build-seed"
if [ -x "$SEED_PREFIX/bin/initdb" ]; then
	echo "== seed-build (glibc) already present, skipping =="
else
	echo "== seed-build: configuring glibc PostgreSQL for host seeding =="
	rm -rf "$SEED_BUILD" "$SEED_PREFIX"
	mkdir -p "$SEED_BUILD"
	cd "$SEED_BUILD"
	ICU_CFLAGS="-I$ICU_HOME/include"
	ICU_LIBS="-L$ICU_HOME/lib -licui18n -licuuc -licudata"
	"$SRC/configure" \
		--prefix="$SEED_PREFIX" \
		--with-icu --without-zlib --without-readline \
		--without-libxml --without-lz4 --without-zstd \
		ICU_CFLAGS="$ICU_CFLAGS" ICU_LIBS="$ICU_LIBS" \
		CFLAGS="-O2 -g" CC=gcc >/tmp/pg-seed-configure.log 2>&1 \
		|| { tail -30 /tmp/pg-seed-configure.log; exit 1; }
	echo "== seed-build: building (-j$JOBS) =="
	make -C src/backend generated-headers >/tmp/pg-seed-genhdr.log 2>&1 \
		|| { tail -20 /tmp/pg-seed-genhdr.log; exit 1; }
	make -j"$JOBS" >/tmp/pg-seed-make.log 2>&1 \
		|| { tail -30 /tmp/pg-seed-make.log; exit 1; }
	make install >/tmp/pg-seed-install.log 2>&1 \
		|| { tail -20 /tmp/pg-seed-install.log; exit 1; }
fi
SEED_BIN="$SEED_PREFIX/bin"
echo "== seed tools: $(file "$SEED_BIN/initdb" | cut -d: -f2-) =="
cd "$HERE"

# ---------------------------------------------------------------------------
# 4. Build the seed_copy boot helper (rofs -> ramfs cluster copy) and the
#    pg_runsql helper (run a SQL file through a single-user standalone backend,
#    for the on-OSv collation demo that does not need a forked backend).
# ---------------------------------------------------------------------------
echo "== building seed_copy + pg_runsql =="
"$CC" -O2 -fPIC -pie -o "$HERE/seed_copy" "$HERE/seed_copy.c"
"$CC" -O2 -fPIC -pie -o "$HERE/pg_runsql" "$HERE/pg_runsql.c"

# ---------------------------------------------------------------------------
# 5. Initialize a small demo cluster (runs natively in the build container).
#
#    OSv deviations baked into the cluster:
#      initdb --locale=en_US.UTF-8 --locale-provider=libc
#                             -- Stage 4 default: a REAL locale with the libc
#                                provider, the glibc-parity choice now that
#                                Stages 0-2 give OSv named locales + the
#                                locale-data module ships en_US.UTF-8. This
#                                bakes datcollate='en_US.UTF-8' into the
#                                template databases; OSv opens it at runtime
#                                (the datcollate round-trip #1477 fixed). For a
#                                kernel WITHOUT the locale work, override with
#                                PG_DEMO_LOCALE=C (documented in the README).
#                                A second database demo_icu is created with the
#                                ICU provider (--with-icu, Stage 4) so both
#                                collation providers are exercised.
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

# Default demo locale: a real libc locale (glibc parity). The build host must
# have en_US.UTF-8 generated so initdb can validate it here; override with
# PG_DEMO_LOCALE=C for a C-only cluster. The runtime (OSv) gets the matching
# locale data from the locale-data module.
PG_DEMO_LOCALE="${PG_DEMO_LOCALE:-en_US.UTF-8}"
if [ "$PG_DEMO_LOCALE" != C ] && ! locale -a 2>/dev/null | grep -qiE "^en_US\.(utf8|UTF-8)$"; then
	echo "== generating en_US.UTF-8 on the build host for initdb =="
	if command -v locale-gen >/dev/null 2>&1; then
		sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null || \
			echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
		locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
	elif command -v localedef >/dev/null 2>&1; then
		localedef -i en_US -f UTF-8 en_US.UTF-8 >/dev/null 2>&1 || true
	fi
fi
export LC_ALL=C LANG=C

# The seeding is done by the GLIBC seed-build tools ($SEED_BIN), which coexist
# with the glibc ICU in one host process (the shipped musl postgres cannot).
# Point the loader at the Stage 3 ICU shared libraries so the seed tools find
# them here. (On OSv the icu module supplies them in the image.)
export LD_LIBRARY_PATH="$ICU_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

PGRUN=""
if [ "$(id -u)" = 0 ]; then
	id pgbuild >/dev/null 2>&1 || useradd -m pgbuild
	chown -R pgbuild "$SEED" "$HERE" 2>/dev/null || true
	# runuser -- does not preserve the environment, so pass LD_LIBRARY_PATH
	# through explicitly via env.
	PGRUN="runuser -u pgbuild -- env LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
fi

$PGRUN "$SEED_BIN/initdb" -D "$SEED" -U postgres \
	--locale-provider=libc --locale="$PG_DEMO_LOCALE" -E UTF8 \
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

# Seed the demo databases with a single-user standalone backend
# ($SEED_BIN/postgres --single, no postmaster/TCP needed; the host shell pipes
# the SQL in). We exercise BOTH collation providers now that Stage 4 builds
# --with-icu and the kernel has real locales:
#   demo        the default database, with a greetings table and a words table
#               for the collation demo (inherits the cluster's en_US.UTF-8
#               libc locale).
#   demo_libc   CREATE DATABASE with the libc provider on en_US.UTF-8.
#   demo_icu    CREATE DATABASE with the ICU provider (icu_locale 'en-US').
# The datcollate round-trip (that #1477 fixed) is what makes CREATE DATABASE
# with a non-C locale open on OSv at all.
echo "== seeding demo data (libc + icu providers) =="
seed_single() {
	# $1 = database, stdin = SQL. postgres --single reads ONE statement per
	# input line (no multi-line statements), and returns 0 even on SQL errors,
	# so we grep the log for ERROR afterwards and fail the build if any seeding
	# statement failed.
	$PGRUN "$SEED_BIN/postgres" --single -D "$SEED" "$1" \
		>>/tmp/pg-seed.log 2>&1
}
: > /tmp/pg-seed.log
# CREATE DATABASE must run outside a transaction block, so one statement per
# single-user invocation (each --single line is its own implicit transaction).
printf "CREATE DATABASE demo;\n" | seed_single postgres
printf "CREATE DATABASE demo_libc LOCALE_PROVIDER libc LOCALE 'en_US.UTF-8' TEMPLATE template0;\n" | seed_single postgres
printf "CREATE DATABASE demo_icu LOCALE_PROVIDER icu ICU_LOCALE 'en-US' LOCALE 'en_US.UTF-8' TEMPLATE template0;\n" | seed_single postgres
# One statement per line (postgres --single has no multi-line statements). The
# words table mixes ASCII and Swedish letters so the collation providers differ.
seed_single demo <<'SQL'
CREATE TABLE greetings (id serial PRIMARY KEY, who text, msg text);
INSERT INTO greetings (who, msg) VALUES ('osv', 'hello from a unikernel'), ('postgres18', 'stock musl build --with-icu'), ('demo', 'this row came over TCP');
CREATE TABLE words (w text);
INSERT INTO words (w) VALUES ('apple'), ('Apple'), ('banana'), ('zebra'), (U&'\00E4pple'), (U&'\00F6l'), (U&'\00E5r'), ('orange');
SQL
if grep -q 'ERROR:' /tmp/pg-seed.log; then
	echo "== ERROR seeding demo data: ==" >&2
	grep 'ERROR:' /tmp/pg-seed.log >&2
	exit 1
fi

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
/usr/bin/pg_runsql: ${MODULE_DIR}/pg_runsql
/etc/demo-collation.sql: ${MODULE_DIR}/demo-collation.sql
/usr/lib/**: ${MODULE_DIR}/install/lib/**
/usr/share/**: ${MODULE_DIR}/install/share/**
/data-seed/**: ${MODULE_DIR}/install/data-seed/**
# empty mount point for the writable ramfs /data (rofs cannot mkdir at runtime)
/data: ${MODULE_DIR}/emptydir
MAN

echo "== done. postgres18-musl app built. =="
