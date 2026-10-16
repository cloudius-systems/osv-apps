# Copyright (C) 2026 Greg Burd
#
# This work is open source software, licensed under the terms of the
# BSD license as described in the LICENSE file in the top-level directory.
#
# icu: build ICU4C (International Components for Unicode) from the pinned
# released sources and install the shared libraries + ICU data for an OSv
# image. ICU is C++; OSv's libc is musl-derived but glibc-ABI compatible and
# the loader statically links a host libstdc++, so (like every osv-apps C++
# module, e.g. keydb, rpm) ICU is built with the host g++ toolchain and OSv
# resolves it against its single libc at runtime. No ICU source is committed
# or shipped; the libraries and data are build artifacts from the pinned
# tarball (URL + sha256 below).
#
# Build-line options (reach this Makefile through the environment):
#   conf_icu_data=full   (default) ship ICU's full data (icudtNNl.dat linked
#                        into libicudata.so, ~30 MB) so every locale/collation
#                        ICU ships is available.
#   conf_icu_data=small  ship a filtered data library (collation + the common
#                        tables only) via ICU's data filtering, for images that
#                        only need collation and want a far smaller footprint.

ICU_VERSION=78.3
ICU_TARBALL=icu4c-$(ICU_VERSION)-sources.tgz
ICU_URL=https://github.com/unicode-org/icu/releases/download/release-$(ICU_VERSION)/$(ICU_TARBALL)
ICU_SHA256=3a2e7a47604ba702f345878308e6fefeca612ee895cf4a5f222e7955fabfe0c0

conf_icu_data ?= full

DOWNLOAD=download
SRCDIR=src/icu
INSTALL=install
STAMP=$(INSTALL)/.stamp
MODE_MARKER=.icu-data-mode

module: $(STAMP)

$(DOWNLOAD)/$(ICU_TARBALL):
	@mkdir -p $(DOWNLOAD)
	cd $(DOWNLOAD) && wget -q -O $(ICU_TARBALL) "$(ICU_URL)"

# Verify the pin before trusting a byte of it.
$(DOWNLOAD)/$(ICU_TARBALL).ok: $(DOWNLOAD)/$(ICU_TARBALL)
	echo "$(ICU_SHA256)  $(DOWNLOAD)/$(ICU_TARBALL)" | sha256sum -c -
	touch $@

# The tarball unpacks to icu/source/...; extract into src/.
$(SRCDIR)/source/configure: $(DOWNLOAD)/$(ICU_TARBALL).ok
	@mkdir -p $(SRCDIR)
	tar xzf $(DOWNLOAD)/$(ICU_TARBALL) -C $(SRCDIR) --strip-components=1
	touch $@

$(STAMP): $(SRCDIR)/source/configure build.sh $(MODE_MARKER) $(lastword $(MAKEFILE_LIST))
	sh build.sh "$(abspath $(SRCDIR)/source)" "$(abspath $(INSTALL))" \
		"$(conf_icu_data)" "$(CURDIR)" "$(ICU_VERSION)"
	touch $@

# A mode marker at the module root (build.sh clears only install/, so this
# survives a rebuild). Rewritten only when conf_icu_data changed, so a changed
# mode makes it newer than $(STAMP) and the data is rebuilt.
$(MODE_MARKER): FORCE
	@if [ "$$(cat $(MODE_MARKER) 2>/dev/null)" != "$(conf_icu_data)" ]; then \
		echo "$(conf_icu_data)" > $(MODE_MARKER); \
	fi

FORCE:

clean:
	rm -rf $(INSTALL) src usr.manifest $(MODE_MARKER)

.PHONY: module clean FORCE
