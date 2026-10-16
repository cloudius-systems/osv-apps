#!/bin/sh
# Copyright (C) 2026 Greg Burd
#
# This work is open source software, licensed under the terms of the
# BSD license as described in the LICENSE file in the top-level directory.
#
# Build ICU4C from the pinned source tree and install its shared libraries and
# data for an OSv image, then write the module's usr.manifest and build the
# ICU smoke-test program:
#   build.sh <icu-source-dir> <install-dir> <data-mode> <module-dir> <version>
# <data-mode> is 'full' (ICU's full data, ~30 MB, linked into libicudata.so)
# or 'small' (collation + common tables only, via ICU's data filtering).
#
# ICU is built with the host g++ toolchain, as every osv-apps C++ module is:
# OSv's libc is musl-derived but glibc-ABI compatible and the loader statically
# links a host libstdc++, so a host-g++ shared library resolves against OSv's
# single libc at runtime. (A musl C++ toolchain is not viable here: musl-tools
# ships only a C wrapper and the distro libstdc++ headers assume glibc.)
#
# The manifest is written here, not in module.py, because scripts/module.py
# imports module.py during dependency resolution (before 'make module' runs),
# so a module.py that walked install/ would capture a stale or empty tree.
set -eu

SRC=$1
INSTALL=$2
MODE=$3
MODULE_DIR=$4
VERSION=$5

BUILD="$MODULE_DIR/build-icu"
MANIFEST="$MODULE_DIR/usr.manifest"
JOBS="${JOBS:-$(nproc)}"

: "${CXX:=g++}"
: "${CC:=gcc}"
export CXX CC

command -v "$CXX" >/dev/null 2>&1 || {
    echo "icu: no C++ compiler ($CXX); install g++" >&2
    exit 1
}

# ICU data filter for the 'small' mode: keep the collation data and the common
# tables ICU always needs; drop the large per-feature resource bundles. This is
# ICU's documented data-filtering mechanism (ICU_DATA_FILTER_FILE).
DATA_FILTER="$MODULE_DIR/icu-data-filter.json"
if [ "$MODE" = small ]; then
    cat > "$DATA_FILTER" <<'JSON'
{
  "strategy": "subset",
  "featureFilters": {
    "coll_tree": "include",
    "coll_ucadata": "include",
    "unames": "exclude",
    "cnvalias": "exclude",
    "conversionMappings": "exclude",
    "brkitr_rules": "exclude",
    "brkitr_dictionaries": "exclude",
    "rbnf_tree": "exclude",
    "translit": "exclude"
  }
}
JSON
    ICU_DATA_FILTER_FILE="$DATA_FILTER"
    export ICU_DATA_FILTER_FILE
    echo "icu: data-mode=small (collation + common tables; ICU_DATA_FILTER_FILE set)"
elif [ "$MODE" = full ]; then
    echo "icu: data-mode=full (ICU's full data linked into libicudata.so)"
else
    echo "icu: unknown conf_icu_data='$MODE' (want full or small)" >&2
    exit 1
fi

rm -rf "$INSTALL" "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

# runConfigureICU Linux picks gcc/g++; -fPIC so the shared libs are relocatable
# in the OSv image. Drop the parts an OSv image does not need (samples, tests,
# extras, layoutex) to keep the build small and fast.
echo "icu: configuring (CXX=$CXX)"
CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" \
    "$SRC/runConfigureICU" Linux \
    --prefix="$INSTALL" \
    --enable-shared --disable-static \
    --disable-samples --disable-tests --disable-extras --disable-layoutex \
    >/tmp/icu-configure.log 2>&1 || { tail -25 /tmp/icu-configure.log; exit 1; }

echo "icu: building (-j$JOBS)"
gmake -j"$JOBS" >/tmp/icu-make.log 2>&1 || { tail -30 /tmp/icu-make.log; exit 1; }
gmake install >/tmp/icu-install.log 2>&1 || { tail -20 /tmp/icu-install.log; exit 1; }

echo "icu: built: $(ls -1 "$INSTALL"/lib/libicuuc.so.* | head -1)"

# ------------------------------------------------------------------
# Smoke test: open an ICU collator for two locales, sort a word list,
# print the order. Built against the just-installed ICU headers/libs.
# ------------------------------------------------------------------
echo "icu: building smoke test"
"$CXX" -O2 -fPIC -std=c++17 -o "$MODULE_DIR/icu_smoke" \
    "$MODULE_DIR/icu_smoke.cc" \
    -I"$INSTALL/include" -L"$INSTALL/lib" \
    -licui18n -licuuc -licudata \
    >/tmp/icu-smoke-build.log 2>&1 || { tail -20 /tmp/icu-smoke-build.log; exit 1; }

# ------------------------------------------------------------------
# usr.manifest: map the shared libraries, the ICU data (if a standalone .dat
# was produced) and the smoke-test binary into the image. ICU installs the
# versioned .so as the real file and unversioned/major-version symlinks beside
# it; the loader resolves by SONAME (libicuuc.so.NN), so ship all three names.
# ------------------------------------------------------------------
echo "icu: writing usr.manifest"
printf '[manifest]\n' > "$MANIFEST"

# All .so files and symlinks under install/lib (keep the symlinks: the loader
# needs the SONAME name libicuXX.so.NN to resolve).
( cd "$INSTALL/lib" && find . \( -type f -o -type l \) -name '*.so*' | LC_ALL=C sort ) \
  | while read -r rel; do
    rel=${rel#./}
    printf '/usr/lib/%s: ${MODULE_DIR}/install/lib/%s\n' "$rel" "$rel" >> "$MANIFEST"
done

# A standalone ICU data file (only present if data packaging is not 'library';
# with the default 'library' packaging the data is inside libicudata.so and no
# .dat is installed). Ship it if present.
if [ -d "$INSTALL/share/icu/$VERSION" ]; then
    ( cd "$INSTALL/share/icu/$VERSION" && find . -type f -name '*.dat' ) \
      | while read -r rel; do
        rel=${rel#./}
        printf '/usr/share/icu/%s/%s: ${MODULE_DIR}/install/share/icu/%s/%s\n' \
            "$VERSION" "$rel" "$VERSION" "$rel" >> "$MANIFEST"
    done
fi

printf '/usr/bin/icu_smoke: ${MODULE_DIR}/icu_smoke\n' >> "$MANIFEST"

echo "icu: done; install $(du -sh "$INSTALL" | cut -f1), libicudata $(du -h "$INSTALL"/lib/libicudata.so.*.* 2>/dev/null | cut -f1 | head -1)"
