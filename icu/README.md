# ICU for OSv (osv-apps `icu` module)

ICU4C (International Components for Unicode) built from pinned released sources
as an osv-apps library module. It installs the ICU shared libraries and data
into an OSv image so applications that want ICU collation, case mapping and
normalisation have it. Stage 4 builds PostgreSQL `--with-icu` against this
module to get an ICU collation provider on OSv.

## What it ships

- `/usr/lib/libicuuc.so.*`   ICU common (code points, collation core, data access)
- `/usr/lib/libicui18n.so.*` ICU internationalisation (Collator, formatting)
- `/usr/lib/libicudata.so.*` ICU data (with the default `library` data packaging
  the full `icudtNNl.dat` is linked *inside* this shared object, ~30 MB)
- `/usr/lib/libicuio.so.*`, `libicutu.so.*`  (ICU I/O and tool-util helpers)
- `/usr/bin/icu_smoke`        the smoke-test program (see below)

## Pinned source

| | |
|-|-|
| version | ICU 78.3 |
| tarball | `icu4c-78.3-sources.tgz` |
| URL     | https://github.com/unicode-org/icu/releases/download/release-78.3/icu4c-78.3-sources.tgz |
| sha256  | `3a2e7a47604ba702f345878308e6fefeca612ee895cf4a5f222e7955fabfe0c0` |

The sha256 is verified in the Makefile before the tarball is used; it matches
ICU's own published `SHASUM512.txt` for the same asset.

## How it is built

ICU is C++. OSv's libc is musl-derived but glibc-ABI compatible, and the OSv
loader statically links a host `libstdc++`, so ICU is built with the **host
g++ toolchain**, exactly as the other osv-apps C++ modules (keydb, rpm) are;
OSv resolves it against its single libc at runtime. A musl C++ toolchain is not
viable here (`musl-tools` ships only a C wrapper, and the distribution's
`libstdc++` headers assume glibc).

`build.sh` runs ICU's `runConfigureICU Linux` with `--enable-shared
--disable-static` and drops the parts an image does not need (samples, tests,
extras, layoutex), then `gmake install`. It then builds `icu_smoke` against the
freshly installed ICU and writes `usr.manifest`.

## Data size: `conf_icu_data`

The full ICU data (`library` packaging) adds ~30 MB to the image via
`libicudata.so`. The data footprint is selectable from the build line:

```
conf_icu_data=full    # default: ICU's full data (every locale ICU ships)
conf_icu_data=small   # collation + common tables only (ICU data filtering)
```

`small` uses ICU's documented `ICU_DATA_FILTER_FILE` mechanism (see
`icu-data-filter.json`, written by `build.sh`) to keep only the collation data
and the common tables, for images that only need collation and want a much
smaller image.

## Smoke test (`image=icu`)

`icu_smoke` opens an ICU collator for `en-US` and `sv-SE`, sorts the same word
list under each, and prints the order. The two locales are chosen to disagree:
Swedish sorts `z` before the accented vowels `å`/`ä`/`ö`, which come at the end
of the Swedish alphabet. Running the same binary against ICU on the build host
(same ICU version) gives the comparison baseline.

```
./scripts/build image=icu conf_locale=1   # library module; no locale data needed by ICU itself
./scripts/run.py
```

## Use as a dependency

Another module pulls ICU in with `api.require('icu')` in its `module.py`; the
ICU libraries and data are merged into the image from this module's manifest.
PostgreSQL (`postgres18-musl`) does this for its `--with-icu` build.
