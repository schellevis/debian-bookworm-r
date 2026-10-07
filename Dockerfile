# syntax=docker/dockerfile:1
#
# A precompiled R package library for Debian 12 (bookworm) with R from CRAN's
# own Debian repository (bookworm-cran40). The published image is the library
# alone (FROM scratch): copy /usr/local/lib/R/site-library into a bookworm
# image that installs the same r-base-core version (label
# io.github.schellevis.r-version) and the runtime packages listed in
# /runtime-debs.txt. See README.md.
#
# Build args (the workflow resolves and passes all of them):
#   BASE_IMAGE             debian:bookworm-slim, pinned by digest in CI
#   R_VERSION              full r-base-core version, e.g. 4.5.3-1~bookwormcran.0
#   PACKAGE_SNAPSHOT_DATE  Posit dated source snapshot, YYYY-MM-DD, or latest
#   SOURCE_TREE            git tree hash of this repository at build time
#   SOURCE_REVISION        git commit of this repository at build time

ARG BASE_IMAGE=debian:bookworm-slim

FROM ${BASE_IMAGE} AS build

ARG R_VERSION=latest

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# R from CRAN's bookworm-cran40 repository. The repository key is fetched from
# the Ubuntu keyserver and accepted only if its primary fingerprint is exactly
# CRAN's published one: a fingerprint, not a file checksum, because keyserver
# responses legitimately change when signatures are added while the
# fingerprint does not. That proves integrity of the key we expect, not origin.
#
# r-base-dev brings the compiler (build-essential, gfortran) and R's headers;
# every -dev package below is a header set one of the packages in packages.txt
# compiles against. libtiff-dev rather than libtiff5-dev: bookworm's
# libtiff5-dev is an empty transitional package. cmake is for the packages that
# vendor a CMake project (duckdb, s2).
# hadolint ignore=DL3008
RUN set -eux; \
    set -- r-base-core r-base r-recommended r-base-dev; \
    if [ "$R_VERSION" != latest ]; then \
      printf '%s\n' "$R_VERSION" \
        | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+~bookwormcran\.[0-9]+$' \
        || { echo "R_VERSION must be 'latest' or the full Debian version of r-base-core in bookworm-cran40, such as 4.5.3-1~bookwormcran.0 (got: '${R_VERSION}')" >&2; exit 1; }; \
      set -- r-base-core="${R_VERSION}" r-base="${R_VERSION}" r-recommended="${R_VERSION}" r-base-dev="${R_VERSION}"; \
    fi; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    gnupg_home="$(mktemp -d)"; \
    curl --retry 3 -fsSL \
      'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x95C0FAF38DB3CCAD0C080A7BDC78B2DDEABC47B7' \
      -o "${gnupg_home}/cran.asc"; \
    cran_fpr="$(GNUPGHOME="$gnupg_home" gpg --show-keys --with-colons "${gnupg_home}/cran.asc" \
      | awk -F: '$1 == "pub" { p = 1; next } $1 == "sub" { p = 0 } p && $1 == "fpr" { print $10 }')"; \
    [ "$cran_fpr" = 95C0FAF38DB3CCAD0C080A7BDC78B2DDEABC47B7 ] \
      || { echo "the CRAN repository key must have exactly the primary fingerprint 95C0FAF38DB3CCAD0C080A7BDC78B2DDEABC47B7 (got: '${cran_fpr}')" >&2; exit 1; }; \
    install -m 0755 -d /etc/apt/keyrings; \
    GNUPGHOME="$gnupg_home" gpg --dearmor -o /etc/apt/keyrings/cran.gpg "${gnupg_home}/cran.asc"; \
    chmod 0644 /etc/apt/keyrings/cran.gpg; \
    rm -rf "$gnupg_home"; \
    printf '%s\n' \
      'deb [signed-by=/etc/apt/keyrings/cran.gpg] http://cloud.r-project.org/bin/linux/debian bookworm-cran40/' \
      > /etc/apt/sources.list.d/cran.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "$@" \
      cmake \
      libbz2-dev \
      libcurl4-openssl-dev \
      libfontconfig1-dev \
      libfreetype6-dev \
      libfribidi-dev \
      libgdal-dev \
      libgeos-dev \
      libharfbuzz-dev \
      libicu-dev \
      libjpeg-dev \
      liblzma-dev \
      libmariadb-dev \
      libpng-dev \
      libpoppler-cpp-dev \
      libpq-dev \
      libproj-dev \
      libqpdf-dev \
      libsqlite3-dev \
      libssl-dev \
      libtiff-dev \
      libudunits2-dev \
      libuv1-dev \
      libwebp-dev \
      libxml2-dev \
      libzmq3-dev \
      zlib1g-dev; \
    rm -rf /var/lib/apt/lists/*

ARG PACKAGE_SNAPSHOT_DATE=latest
COPY packages.txt /tmp/packages.txt

# Packages come from Posit's dated *source* snapshot (no `__linux__` segment,
# so Posit never substitutes a binary) when a date is passed, and from CRAN
# itself for `latest`. Posit stopped building bookworm binaries between its
# 2026-06-01 and 2026-08-01 snapshots, so everything compiles.
#
# Parallelism is bounded and runs in two phases of about nproc compiler
# processes each. duckdb goes first and alone, with Ncpus=1 and
# MAKEFLAGS=-j<nproc>: its ~300 template-heavy C++ files compile in one
# package, and single-job make left it compiling alone for over 90 minutes on a
# 12-core host (measured 2026-10-06). The rest then installs with Ncpus=nproc
# and MAKEFLAGS unset. The two cannot be merged by exporting both: with
# Ncpus > 1 R drives the parallel install through its own top-level make, whose
# jobserver overrides an exported MAKEFLAGS=-jN (measured the same day). A
# package's compile output is only logged when it finishes, so duckdb's lines
# appear all at once at the end of phase 1. The step ends by printing the
# cgroup's memory.peak.
#
# install.packages() only warns when a compile fails and exits zero; the
# separate Rscript that follows loads every listed package in a fresh process
# and exits non-zero naming the ones that did not load. -g0 and --strip keep
# debug symbols out of the library, which is pure size for its consumers.
# HOME and TMPDIR are scratch directories removed in this same RUN. The R code
# is single-quoted on purpose: `$x` there is R's list accessor, not a shell
# variable.
# hadolint ignore=SC2016
RUN set -eux; \
    printf '%s\n' "$PACKAGE_SNAPSHOT_DATE" | grep -Eq '^(latest|[0-9]{4}-[0-9]{2}-[0-9]{2})$' \
      || { echo "PACKAGE_SNAPSHOT_DATE must be 'latest' or a date such as 2026-10-05 (got: '${PACKAGE_SNAPSHOT_DATE}')" >&2; exit 1; }; \
    if [ "$PACKAGE_SNAPSHOT_DATE" = latest ]; then \
      r_repo=https://cloud.r-project.org; \
    else \
      r_repo="https://packagemanager.posit.co/cran/${PACKAGE_SNAPSHOT_DATE}"; \
    fi; \
    build_home="$(mktemp -d)"; \
    build_tmp="$(mktemp -d)"; \
    printf '%s\n' 'CFLAGS += -g0' 'CXXFLAGS += -g0' 'CXX11FLAGS += -g0' \
      'CXX14FLAGS += -g0' 'CXX17FLAGS += -g0' 'CXX20FLAGS += -g0' 'FFLAGS += -g0' \
      > "${build_tmp}/Makevars.site"; \
    unset MAKEFLAGS; \
    r_jobs="$(nproc)"; \
    export HOME="$build_home" TMPDIR="$build_tmp" R_MAKEVARS_SITE="${build_tmp}/Makevars.site" \
      R_REPO="$r_repo"; \
    MAKEFLAGS="-j${r_jobs}" Rscript -e 'options(repos = c(CRAN = Sys.getenv("R_REPO")), pkgType = "source"); install.packages("duckdb", lib = "/usr/local/lib/R/site-library", type = "source", dependencies = c("Depends", "Imports", "LinkingTo"), Ncpus = 1L, INSTALL_opts = "--strip")'; \
    R_NCPUS="$r_jobs" Rscript -e 'pkgs <- trimws(sub("#.*", "", readLines("/tmp/packages.txt"))); pkgs <- setdiff(pkgs[nzchar(pkgs)], "duckdb"); options(repos = c(CRAN = Sys.getenv("R_REPO")), pkgType = "source"); install.packages(pkgs, lib = "/usr/local/lib/R/site-library", type = "source", dependencies = c("Depends", "Imports", "LinkingTo"), Ncpus = as.integer(Sys.getenv("R_NCPUS")), INSTALL_opts = "--strip")'; \
    Rscript -e 'pkgs <- trimws(sub("#.*", "", readLines("/tmp/packages.txt"))); pkgs <- pkgs[nzchar(pkgs)]; if (!length(pkgs)) quit(status = 1); ok <- vapply(pkgs, function(p) tryCatch({ suppressPackageStartupMessages(library(p, character.only = TRUE)); TRUE }, error = function(e) { message(p, ": ", conditionMessage(e)); FALSE }), logical(1)); if (!all(ok)) { message("R packages that failed to build or load: ", paste(pkgs[!ok], collapse = " ")); quit(status = 1) }; con <- DBI::dbConnect(duckdb::duckdb()); stopifnot(DBI::dbGetQuery(con, "select 42 as x")$x == 42); DBI::dbDisconnect(con, shutdown = TRUE)'; \
    rm -rf "$build_home" "$build_tmp"; \
    chown -R root:root /usr/local/lib/R/site-library; \
    chmod -R u=rwX,go=rX /usr/local/lib/R/site-library; \
    chmod 0755 /usr/local/lib/R/site-library; \
    if [ -r /sys/fs/cgroup/memory.peak ]; then \
      echo "memory.peak: $(cat /sys/fs/cgroup/memory.peak) bytes"; \
    else \
      echo "memory.peak unavailable: /sys/fs/cgroup/memory.peak is not readable"; \
    fi

# The runtime manifest: every Debian package that owns a shared library one of
# the compiled objects links against directly, with the version it was linked
# against, as "<package> <version>" lines. ldd sees DT_NEEDED libraries only,
# not dlopen()ed ones, so this is a starting set for a consumer, not proof of
# completeness; a consumer should still load every package. dpkg records paths
# both under /lib and /usr/lib on a merged-/usr system, so both spellings are
# tried. A library ldd cannot resolve fails the build here.
# hadolint ignore=SC2016
RUN set -eux; \
    libs="$(find /usr/local/lib/R/site-library -name '*.so' -print0 \
      | xargs -0 ldd | awk '/=> not found/ { print "MISSING " $1; next } /=> \// { print $3 }' | sort -u)"; \
    if printf '%s\n' "$libs" | grep -q '^MISSING '; then \
      printf '%s\n' "$libs" | grep '^MISSING ' >&2; exit 1; \
    fi; \
    : > /runtime-debs.txt; \
    for lib in $libs; do \
      owner=""; \
      for path in "$lib" "$(readlink -f "$lib")" "/usr${lib}" "${lib#/usr}"; do \
        owner="$(dpkg -S "$path" 2>/dev/null | head -n1 | cut -d: -f1)" && [ -n "$owner" ] && break; \
      done; \
      [ -n "$owner" ] || { echo "no Debian package owns ${lib}" >&2; exit 1; }; \
      printf '%s %s\n' "$owner" "$(dpkg-query -W -f='${Version}' "$owner")" >> /runtime-debs.txt; \
    done; \
    sort -u -o /runtime-debs.txt /runtime-debs.txt; \
    test -s /runtime-debs.txt; \
    cat /runtime-debs.txt

FROM scratch

ARG R_VERSION=latest
ARG PACKAGE_SNAPSHOT_DATE=latest
ARG BASE_IMAGE=debian:bookworm-slim
ARG SOURCE_TREE=unknown
ARG SOURCE_REVISION=unknown
ARG PACKAGES_SHA256=unknown
ARG CREATED=unknown

COPY --from=build /usr/local/lib/R/site-library /usr/local/lib/R/site-library
COPY --from=build /runtime-debs.txt /runtime-debs.txt

LABEL org.opencontainers.image.title="debian-bookworm-r" \
      org.opencontainers.image.description="Precompiled R package library for Debian 12 (bookworm) with R from CRAN's bookworm-cran40 repository" \
      org.opencontainers.image.source="https://github.com/schellevis/debian-bookworm-r" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      io.github.schellevis.r-version="${R_VERSION}" \
      io.github.schellevis.package-snapshot="${PACKAGE_SNAPSHOT_DATE}" \
      io.github.schellevis.packages-sha256="${PACKAGES_SHA256}" \
      io.github.schellevis.source-tree="${SOURCE_TREE}" \
      io.github.schellevis.base-digest="${BASE_IMAGE}"
