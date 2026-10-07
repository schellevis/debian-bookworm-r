# debian-bookworm-r

This repository publishes a **precompiled R package library** for Debian 12
(bookworm) with R from CRAN's own Debian repository
([`bookworm-cran40`](https://cloud.r-project.org/bin/linux/debian/)).

Most of these packages have compiled code. On Linux, CRAN serves them as
source. Posit Package Manager stopped publishing bookworm binaries in mid-2026,
so a bookworm image that wants them has to compile them, and for a set like
this one that takes a long time. This repository does the compiling once a
week and publishes the result as an image you can copy from.

```text
ghcr.io/schellevis/debian-bookworm-r:latest
ghcr.io/schellevis/debian-bookworm-r:<r-version>-<snapshot>-<recipe>
```

## What is in the image

The image is built `FROM scratch`. It contains no operating system and no R.

| Path | Contents |
| --- | --- |
| `/usr/local/lib/R/site-library/` | The packages in [`packages.txt`](packages.txt) and all their dependencies, compiled and stripped. |
| `/runtime-debs.txt` | `<package> <version>` lines: the Debian packages owning the shared libraries the compiled code links against, at the version it was built against. |

Labels:

| Label | Meaning |
| --- | --- |
| `io.github.schellevis.r-version` | Exact `r-base-core` version the library was built with, e.g. `4.5.3-1~bookwormcran.0`. |
| `io.github.schellevis.package-snapshot` | The [Posit Package Manager](https://packagemanager.posit.co/) dated CRAN source snapshot used. |
| `io.github.schellevis.packages-sha256` | sha256 of `packages.txt`. |
| `io.github.schellevis.source-tree` | Git tree hash of this repository at build time. |
| `io.github.schellevis.base-digest` | The `debian:bookworm-slim` image it was compiled on. |
| `org.opencontainers.image.created` / `.revision` | Build time and commit. |

## Using it

Install **the same `r-base-core` version** from `bookworm-cran40`. Install the
runtime packages in `/runtime-debs.txt`, at that version or newer within
bookworm. Then copy the library:

```dockerfile
FROM ghcr.io/schellevis/debian-bookworm-r@sha256:<digest> AS rlib

FROM debian:bookworm
# The r-version label of the image above.
ARG R_VERSION
COPY --from=rlib /runtime-debs.txt /tmp/runtime-debs.txt
# …add the bookworm-cran40 apt source and its key, then:
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      r-base-core="${R_VERSION}" \
      $(grep -v '^r-base-core ' /tmp/runtime-debs.txt | cut -d' ' -f1) \
 && rm -rf /var/lib/apt/lists/* /tmp/runtime-debs.txt
COPY --from=rlib /usr/local/lib/R/site-library /usr/local/lib/R/site-library
```

Read the labels from the exact digest you pin, not from a tag:

```bash
docker buildx imagetools inspect ghcr.io/schellevis/debian-bookworm-r:latest \
  --format '{{ .Manifest.Digest }}'
docker buildx imagetools inspect ghcr.io/schellevis/debian-bookworm-r@sha256:<digest> \
  --format '{{ json .Image.Config.Labels }}'
```

`/runtime-debs.txt` is derived from direct (`DT_NEEDED`) dependencies. It is a
starting set, not proof of completeness. After copying, load every package in
your image (`library(<pkg>)` for each name in `packages.txt`) and run `ldd` over
the `.so` files.

## Build cadence

- **Weekly**, Tuesday 02:47 UTC. The snapshot is the Monday before the most
  recent Tuesday, which is yesterday on the scheduled run.
- **On every push to `main`.**
- **On demand** via `workflow_dispatch`.

A run that finds the R version, snapshot, recipe and base image all unchanged
publishes nothing. A scheduled run that fails opens an issue here.

## Building it yourself

```bash
docker build \
  --build-arg R_VERSION=4.5.3-1~bookwormcran.0 \
  --build-arg PACKAGE_SNAPSHOT_DATE=2026-10-05 \
  -t debian-bookworm-r .
```

Both args default to `latest`: the newest R in `bookworm-cran40`, and current
CRAN instead of a dated snapshot. A cold build compiles about 130 packages and
needs several GB of memory.

## Licence

The build recipe is MIT-licensed (see [`LICENSE`](LICENSE)). The compiled
packages keep their own licences. Their sources are on CRAN and in the dated
snapshot named by the `package-snapshot` label.
