#!/usr/bin/env bash
# Generated from tar_repro/tar_repro_test.sh.tpl. The three pipeline blocks
# below are the same strings that private/hermetic_tar.bzl hands to
# erlang_build and erlang_erts_layer, so this test cannot pass while the rules
# drift away from it.
set -euo pipefail

%{BSDTAR_SETUP}

MTREE="$TEST_TMPDIR/release.mtree"

# macOS has no sha256sum on the action PATH, only shasum (probe, 2026-09-14).
hash256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

# Every mode is set by hand, so that the fixture itself does not move when the
# test re-runs under a different umask. The shapes copy the parts of an OTP
# release that made the old tar command non-deterministic: the bin/epmd
# symlink, a second name for one inode, an excluded source directory, and
# three distinct modes.
FIXTURE="$TEST_TMPDIR/fixture"
mkdir -p "$FIXTURE"/bin "$FIXTURE"/erts-1.0/bin \
         "$FIXTURE"/lib/app-1.0/ebin "$FIXTURE"/lib/app-1.0/src \
         "$FIXTURE"/releases/1
printf 'erl\n' > "$FIXTURE/bin/erl"
printf 'epmd\n' > "$FIXTURE/erts-1.0/bin/epmd"
printf 'beam\n' > "$FIXTURE/erts-1.0/bin/beam.smp"
printf 'm\n' > "$FIXTURE/lib/app-1.0/ebin/m.beam"
printf 'src\n' > "$FIXTURE/lib/app-1.0/src/m.erl"
printf 'boot\n' > "$FIXTURE/releases/1/start.boot"
ln -s ../erts-1.0/bin/epmd "$FIXTURE/bin/epmd"
ln "$FIXTURE/erts-1.0/bin/beam.smp" "$FIXTURE/erts-1.0/bin/beam2.smp"
chmod 755 "$FIXTURE/bin/erl" "$FIXTURE/erts-1.0/bin/epmd" \
          "$FIXTURE/erts-1.0/bin/beam.smp"
chmod 644 "$FIXTURE/lib/app-1.0/ebin/m.beam" "$FIXTURE/lib/app-1.0/src/m.erl"
chmod 444 "$FIXTURE/releases/1/start.boot"
find "$FIXTURE" -type d -exec chmod 755 {} +

archive() {
    cd "$FIXTURE"
%{MTREE_CMDS}
%{ARCHIVE_CMDS} | gzip -n
}

first="$(archive | hash256)"

# The three inputs a careless tar call leaks into a header, plus a clock that
# has moved. If any of them reaches the archive, the second hash differs.
umask 077
find "$FIXTURE" -exec touch -t 203012312359 {} +
second="$(TZ=Asia/Tokyo LC_ALL=C archive | hash256)"
umask 022

if [ "$first" != "$second" ]; then
    echo "FAIL: the archive is not reproducible: $first != $second"
    exit 1
fi

members="$(archive | gzip -dc | "$BSDTAR" -tvf -)"

if printf '%s\n' "$members" | grep -q 'app-1.0/src'; then
    echo "FAIL: the exclude pattern did not drop lib/*/src"
    printf '%s\n' "$members"
    exit 1
fi

# An 'h' in the first column is a hard link member. bsdtar writes one for the
# second name of a shared inode unless the manifest says nlink=1, which is
# what replaced GNU --hard-dereference.
if printf '%s\n' "$members" | grep -q '^h'; then
    echo "FAIL: the archive holds a hard link member"
    printf '%s\n' "$members"
    exit 1
fi

# bsdtar -tv prints mode, nlink, uid, gid, size, then the date. Every member
# has to read 0, 0 and 1970, or the builder's identity or clock got in.
bad="$(printf '%s\n' "$members" |
    awk '$3 != "0" || $4 != "0" || $6 != "Jan" || $7 != "1" || $8 != "1970"')"
if [ -n "$bad" ]; then
    echo "FAIL: a member carries an owner or a time that is not normalised"
    printf '%s\n' "$bad"
    exit 1
fi

# The property that lets Phase 3 keep a hash it already published: the mtree
# pipeline gives the same bytes as the GNU command it replaces. GNU tar is
# absent on a Mac, so this half only runs where it exists.
if tar --version 2>/dev/null | head -1 | grep -q 'GNU tar'; then
    gnu="$(cd "$FIXTURE" && tar --sort=name \
        --mtime=@0 \
        --owner=0 \
        --group=0 \
        --numeric-owner \
        --hard-dereference \
        --format=gnu \
        -chf - %{EXCLUDES} . | gzip -n | hash256)"
    if [ "$first" != "$gnu" ]; then
        echo "FAIL: bsdtar and GNU tar disagree: $first != $gnu"
        exit 1
    fi
    echo "PASS: $first (GNU tar agrees)"
else
    echo "PASS: $first (no GNU tar here, so the cross-check was skipped)"
fi
