.PHONY: module build
module: build

# Fetch PostgreSQL 18 source, build it with musl-gcc as an OSv PIE, apply the
# minimal OSv-environment neuters, initialize a small demo cluster, build the
# seed_copy helper, and emit usr.manifest pointing at the build output.
build:
	./build.sh

.PHONY: clean
clean:
	rm -rf src build install usr.manifest *.tar.gz seed_copy emptydir
