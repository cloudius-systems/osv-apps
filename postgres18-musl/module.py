from osv.modules import api

# Stage 4: PostgreSQL is built --with-icu against the Stage 3 ICU module, so
# pull in the ICU shared libraries + data (the collation provider). OSv
# resolves ICU's glibc-ABI shared objects (and libstdc++) at runtime.
api.require('icu')

# Boot sequence (OSv runs ;-separated commands in one instance over a shared
# filesystem):
#   1. mount a writable ramfs over the empty /data mount point (the baked
#      cluster on rofs is read-only; PostgreSQL must write to its data dir);
#   2. seed_copy the read-only baked cluster (/data-seed) into /data;
#   3. start the postmaster on the writable copy.
#
# The baked postgresql.conf sets unix_socket_directories='' (OSv has no
# AF_UNIX) and listen_addresses='*', so PostgreSQL serves TCP on 0.0.0.0:5432.
default = api.run(
    '--mount-fs=ramfs,/dev/null,/data '
    '/usr/bin/seed_copy /data-seed /data ; '
    '/usr/bin/postgres -D /data'
)

# collation_demo (image=postgres18-musl.collation_demo): seed the cluster into
# a writable ramfs, then run the collation demo SQL through a SINGLE-USER
# standalone backend (postgres --single, via pg_runsql) and exit. This serves
# real queries on OSv -- sorting under the libc provider (en_US.UTF-8) and the
# ICU provider -- WITHOUT forking a backend. The normal postmaster path forks a
# backend per connection, and OSv's fork()/COW cross-address-space coherence is
# still WIP (a forked backend currently faults in the pagecache/COW path), so
# the served-query evidence comes from this single-user path.
collation_demo = api.run(
    '--mount-fs=ramfs,/dev/null,/data '
    '/usr/bin/seed_copy /data-seed /data ; '
    '/usr/bin/pg_runsql /data demo /etc/demo-collation.sql'
)
