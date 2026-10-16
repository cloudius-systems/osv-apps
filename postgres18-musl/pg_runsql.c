/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * pg_runsql -- run a SQL file against a database with a single-user standalone
 * backend, printing the results to the console.
 *
 * PostgreSQL's normal client path forks a backend per connection; OSv's
 * fork()/COW cross-address-space coherence is still WIP (a forked backend
 * currently crashes the kernel in the pagecache/COW path), so for a
 * self-contained on-OSv demonstration we use `postgres --single`, which runs
 * the backend in the postmaster's own process -- no fork, no TCP. The
 * standalone backend reads SQL from stdin; OSv's command line cannot redirect
 * stdin, so this helper reopens the SQL file as stdin and execs the backend.
 *
 * Usage: pg_runsql <datadir> <database> <sqlfile>
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	if (argc != 4) {
		fprintf(stderr, "usage: %s <datadir> <database> <sqlfile>\n", argv[0]);
		return 2;
	}
	const char *datadir = argv[1];
	const char *db = argv[2];
	const char *sqlfile = argv[3];

	if (!freopen(sqlfile, "r", stdin)) {
		perror(sqlfile);
		return 1;
	}
	/* -j: treat each blank-line-separated chunk as one query (so a statement
	 *     may span lines); the standalone backend otherwise ends a statement
	 *     at every newline. */
	const char *pg_argv[] = {
		"/usr/bin/postgres", "--single", "-j", "-D", datadir, db, NULL
	};
	execv(pg_argv[0], (char *const *)pg_argv);
	perror(pg_argv[0]);
	return 127;
}
