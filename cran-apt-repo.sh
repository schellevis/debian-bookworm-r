#!/usr/bin/env bash
# Install R from CRAN's bookworm-cran40 repository through a verified local
# apt repository, so apt never reads CRAN's signature itself.
#
# Why: CRAN's Debian signing key (primary 95C0FAF38DB3CCAD0C080A7BDC78B2DDEABC47B7,
# signing subkey B8F25A8A73EACF41) expired on 2026-11-15, while the repository
# is still signed with it. apt treats a signature by an expired key as no
# signature at all ("EXPKEYSIG ... is not signed") and has no option to accept
# one, so `apt-get update` fails for every source once CRAN's is configured.
# The signature itself is intact: InRelease was signed on 2026-03-12, while
# the key was valid, and the key was never revoked. gpgv reports exactly that
# (EXPKEYSIG plus VALIDSIG, exit 0).
#
# So this script does what apt would do, with one rule changed: a signature
# by the pinned key is accepted when it was made before that key expired.
#
#   1. InRelease is verified with gpgv against the given keyring. Exactly one
#      signature, made by a non-revoked signing key whose primary fingerprint
#      is the given one, created before both that key and its primary expired
#      and not in the future. Anything else -- a bad signature, a second
#      signature, an unknown key, a revoked key -- is refused.
#   2. Packages is downloaded and must match the size and SHA-256 listed in
#      the verified InRelease.
#   3. The verified Packages becomes a local flat repository
#      (`deb [trusted=yes] file:<dir> ./`). trusted=yes is safe only because
#      nothing in that directory came from anywhere but steps 1-2 and 4, and
#      the directory is root-owned.
#   4. apt resolves the requested packages against it (simulation only), and
#      every resulting package that comes from CRAN is downloaded and must
#      match the size and SHA-256 in the verified Packages before it is put
#      where the local repository serves it. apt checks those hashes again
#      when it installs.
#
# What this does not protect against is the same as before: a replayed older
# InRelease (CRAN's carries no Valid-Until), and anything that compromised the
# key before it expired. The fingerprint pin proves integrity of the key we
# expect, not origin.
#
# Usage:
#   cran-apt-repo.sh fetch <keyring.gpg> <primary-fingerprint> <repo-dir> <package[=version]>...
#       Builds the local repository in <repo-dir>, writes
#       /etc/apt/sources.list.d/cran-local.list, runs apt-get update and
#       downloads every CRAN package the given specs resolve to. The caller
#       then runs `apt-get install` itself.
#   cran-apt-repo.sh keep <repo-dir> <package>...
#       Drops every package from the local repository except the named ones,
#       deleting their files, so the repository can stay in an image small.
set -Eeuo pipefail

work=''
readonly CRAN_BASE='https://cloud.r-project.org/bin/linux/debian'
readonly CRAN_SUITE='bookworm-cran40'
readonly SOURCES_LIST='/etc/apt/sources.list.d/cran-local.list'

die() {
  echo "cran-apt-repo: $*" >&2
  exit 1
}

usage() {
  sed -n '/^# Usage:$/,/^set -Eeuo pipefail$/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

# Prints "<size> <sha256>" for <file> in the SHA256 section of a Release file.
release_sha256() {
  local release="$1" file="$2"
  awk -v f="$file" '
    /^SHA256:/ { s = 1; next }
    /^[^ ]/ { s = 0 }
    s && NF == 3 && $3 == f { print $2, $1; n++ }
    END { exit n != 1 }
  ' "$release"
}

# An unsigned Release naming Packages and its hash: with it apt reads exactly
# that file instead of probing every compressed variant (each probe logs an
# "Err ... Method gave a blank filename" that reads like a failure).
write_release() {
  local repo="$1"
  {
    echo "Suite: ${CRAN_SUITE}-local"
    echo "Date: $(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S UTC")"
    echo 'SHA256:'
    printf ' %s %s Packages\n' "$(sha256sum "${repo}/Packages" | cut -d' ' -f1)" \
      "$(stat -c %s "${repo}/Packages")"
  } > "${repo}/Release"
  chmod 0644 "${repo}/Release"
}

check_file() {
  local path="$1" size="$2" sha256="$3" what="$4" have_size have_sha
  [[ "$size" =~ ^[0-9]+$ ]] || die "${what}: no valid size in the verified index"
  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || die "${what}: no valid SHA-256 in the verified index"
  have_size="$(stat -c %s "$path")"
  [[ "$have_size" == "$size" ]] \
    || die "${what}: size ${have_size} does not match the verified ${size}"
  have_sha="$(sha256sum "$path" | cut -d' ' -f1)"
  [[ "$have_sha" == "$sha256" ]] \
    || die "${what}: SHA-256 ${have_sha} does not match the verified ${sha256}"
}

verify_inrelease() {
  local keyring="$1" fpr="$2" inrelease="$3" release="$4" work="$5"
  local status="${work}/gpgv.status" sig_fpr sig_ts primary key_line now

  # gpgv exits 0 for a good signature by an expired key, so its exit code is
  # necessary but not sufficient; the status lines decide.
  if ! GNUPGHOME="${work}/gnupg" gpgv --status-fd 3 --keyring "$keyring" \
      --output "$release" "$inrelease" 3>"$status" 2>"${work}/gpgv.log"; then
    cat "${work}/gpgv.log" >&2
    die "gpgv rejected ${CRAN_SUITE}/InRelease"
  fi
  if grep -Eq '^\[GNUPG:\] (BADSIG|ERRSIG|REVKEYSIG|NO_PUBKEY|NODATA|FAILURE|ERROR) ' "$status"; then
    cat "$status" >&2
    die "gpgv reported a failure for ${CRAN_SUITE}/InRelease"
  fi
  [[ "$(grep -Ec '^\[GNUPG:\] (GOODSIG|EXPKEYSIG) ' "$status")" == 1 ]] \
    || { cat "$status" >&2; die "InRelease must carry exactly one good signature"; }
  [[ "$(grep -c '^\[GNUPG:\] VALIDSIG ' "$status")" == 1 ]] \
    || { cat "$status" >&2; die "InRelease must carry exactly one valid signature"; }

  read -r sig_fpr sig_ts primary < <(awk '$2 == "VALIDSIG" { print $3, $5, $12 }' "$status")
  [[ "$primary" == "$fpr" ]] \
    || die "InRelease is signed by primary key ${primary}, not ${fpr}"
  [[ "$sig_ts" =~ ^[0-9]+$ ]] || die "unreadable signature time '${sig_ts}'"
  now="$(date +%s)"
  (( sig_ts <= now + 600 )) || die "InRelease signature is dated in the future (${sig_ts})"

  # The signing key's own record, then the primary's: the signature must
  # predate both expiries, and neither may be revoked.
  GNUPGHOME="${work}/gnupg" gpg --batch --show-keys --with-colons "$keyring" \
    > "${work}/key.colons" 2>/dev/null
  for want in "$sig_fpr" "$fpr"; do
    key_line="$(awk -F: -v want="$want" '
      $1 == "pub" || $1 == "sub" { rec = $0; next }
      $1 == "fpr" && $10 == want && rec != "" { print rec; rec = "" }
    ' "${work}/key.colons")"
    [[ -n "$key_line" && "$key_line" != *$'\n'* ]] \
      || die "key ${want} is not exactly once in the keyring"
    [[ "$(cut -d: -f2 <<<"$key_line")" != r ]] || die "key ${want} is revoked"
    local expires
    expires="$(cut -d: -f7 <<<"$key_line")"
    if [[ -n "$expires" ]]; then
      [[ "$expires" =~ ^[0-9]+$ ]] || die "unreadable expiry '${expires}' for ${want}"
      (( sig_ts < expires )) \
        || die "InRelease was signed at ${sig_ts}, after key ${want} expired at ${expires}"
    fi
  done
  if [[ "$sig_fpr" != "$fpr" ]]; then
    [[ "$(awk -F: -v want="$sig_fpr" '
      $1 == "sub" { cap = $12; next }
      $1 == "fpr" && $10 == want { print cap }
    ' "${work}/key.colons")" == *s* ]] || die "subkey ${sig_fpr} is not a signing key"
  fi
  echo "cran-apt-repo: ${CRAN_SUITE}/InRelease signed $(date -u -d "@${sig_ts}" +%F) by ${sig_fpr} (primary ${fpr}), accepted" >&2
}

cmd_fetch() {
  (( $# >= 4 )) || usage
  local keyring="$1" fpr="$2" repo="$3"
  shift 3
  [[ "$keyring" == /* && -r "$keyring" ]] || die "keyring must be a readable absolute path"
  [[ "$fpr" =~ ^[0-9A-F]{40}$ ]] || die "fingerprint must be 40 upper-case hex characters"
  [[ "$repo" == /* ]] || die "repository directory must be an absolute path"
  local spec
  for spec in "$@"; do
    [[ "$spec" =~ ^[a-z0-9][a-z0-9+.-]+(=[A-Za-z0-9.+~:-]+)?$ ]] || die "invalid package spec '${spec}'"
  done

  local arch size sha
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  install -d -m 0700 "${work}/gnupg"
  arch="$(dpkg --print-architecture)"

  curl --retry 3 -fsSL "${CRAN_BASE}/${CRAN_SUITE}/InRelease" -o "${work}/InRelease"
  verify_inrelease "$keyring" "$fpr" "${work}/InRelease" "${work}/Release" "$work"

  read -r size sha < <(release_sha256 "${work}/Release" Packages) \
    || die "the verified InRelease lists no single SHA-256 for Packages"
  curl --retry 3 -fsSL "${CRAN_BASE}/${CRAN_SUITE}/Packages" -o "${work}/Packages"
  check_file "${work}/Packages" "$size" "$sha" Packages

  install -d -m 0755 "$repo"
  install -m 0644 "${work}/Packages" "${repo}/Packages"
  write_release "$repo"
  printf 'deb [trusted=yes] file:%s ./\n' "$repo" > "$SOURCES_LIST"
  chmod 0644 "$SOURCES_LIST"
  apt-get update

  # Every package the specs resolve to, as "<name> <version>"; those that the
  # verified Packages lists for this architecture are CRAN's and get fetched.
  local resolved name version entry filename dest
  resolved="$(apt-get install -s -y --no-install-recommends "$@" \
    | sed -nE 's/^Inst ([^ ]+) (\[[^]]*\] )?\(([^ ]+) .*/\1 \3/p')"
  [[ -n "$resolved" ]] || die "apt resolved nothing to install for: $*"
  while read -r name version; do
    entry="$(awk -v n="$name" -v v="$version" -v a="$arch" '
      BEGIN { RS = ""; FS = "\n" }
      {
        p = ""; ver = ""; ar = ""; fn = ""; sz = ""; sh = ""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^Package: /) p = substr($i, 10)
          else if ($i ~ /^Version: /) ver = substr($i, 10)
          else if ($i ~ /^Architecture: /) ar = substr($i, 15)
          else if ($i ~ /^Filename: /) fn = substr($i, 11)
          else if ($i ~ /^Size: /) sz = substr($i, 7)
          else if ($i ~ /^SHA256: /) sh = substr($i, 9)
        }
        if (p == n && ver == v && (ar == a || ar == "all")) { print fn, sz, sh; c++ }
      }
      END { exit (c > 1) }
    ' "${repo}/Packages")" || die "${name} ${version} is listed more than once in Packages"
    [[ -n "$entry" ]] || continue
    read -r filename size sha <<<"$entry"
    [[ "$filename" =~ ^${CRAN_SUITE}/[A-Za-z0-9.+~_-]+\.deb$ ]] \
      || die "unexpected Filename '${filename}' for ${name}"
    dest="${repo}/${filename}"
    install -d -m 0755 "$(dirname "$dest")"
    curl --retry 3 -fsSL "${CRAN_BASE}/${filename}" -o "${dest}.part"
    check_file "${dest}.part" "$size" "$sha" "$filename"
    chmod 0644 "${dest}.part"
    mv "${dest}.part" "$dest"
    echo "cran-apt-repo: verified ${filename}" >&2
  done <<<"$resolved"
}

cmd_keep() {
  (( $# >= 2 )) || usage
  local repo="$1"
  shift
  [[ -f "${repo}/Packages" ]] || die "${repo} holds no Packages file"
  local tmp name
  tmp="$(mktemp)"
  # Keep a stanza only when it names a wanted package and its file was
  # fetched (and so verified); every other stanza and file goes.
  awk -v keep=" $* " -v repo="$repo" 'BEGIN { RS = ""; FS = "\n"; ORS = "\n\n" }
    {
      p = ""; fn = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Package: /) p = substr($i, 10)
        else if ($i ~ /^Filename: /) fn = substr($i, 11)
      }
      if (index(keep, " " p " ") && fn != "" && (getline line < (repo "/" fn)) >= 0) {
        close(repo "/" fn); print
      }
    }' "${repo}/Packages" > "$tmp"
  install -m 0644 "$tmp" "${repo}/Packages"
  rm -f "$tmp"
  write_release "$repo"
  for name in "$@"; do
    grep -qxF "Package: ${name}" "${repo}/Packages" \
      || die "${name} was not fetched into ${repo}; nothing to keep"
  done
  local deb filename
  while IFS= read -r -d '' deb; do
    filename="${deb#"${repo}/"}"
    if ! grep -qxF "Filename: ${filename}" "${repo}/Packages"; then
      rm -f "$deb"
    fi
  done < <(find "$repo" -type f -name '*.deb' -print0)
}

case "${1:-}" in
  fetch) shift; cmd_fetch "$@" ;;
  keep) shift; cmd_keep "$@" ;;
  *) usage ;;
esac
