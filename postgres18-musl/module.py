from osv.modules import api

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
