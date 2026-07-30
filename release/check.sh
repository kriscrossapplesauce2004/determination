#!/bin/sh
# Audit central version metadata and, in `ship` mode, enforce the minimum
# conditions for tagging a project release. This does not publish anything.

set -eu
cd "$(dirname "$0")/.."

DET_MODE=${1:-check}
case "$DET_MODE" in
    check|ship) ;;
    *) echo "usage: release/check.sh [check|ship]" >&2; exit 2 ;;
esac

. release/version.sh
det_load_version version.properties

DET_FAILURES=0
DET_CHECK_TMP=$(mktemp -d)
trap 'rm -rf "$DET_CHECK_TMP"' EXIT

ok()   { printf 'ok:   %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; DET_FAILURES=$((DET_FAILURES + 1)); }

check_equal() {
    DET_LABEL=$1 DET_WANT=$2 DET_GOT=$3
    if [ "$DET_WANT" = "$DET_GOT" ]; then
        ok "$DET_LABEL = $DET_GOT"
    else
        fail "$DET_LABEL: wanted '$DET_WANT', got '$DET_GOT'"
    fi
}

ok "project version: $DET_VERSION"
ok "release train: $DET_CODENAME"
ok "versionCode: $DET_VERSION_CODE"
ok "status: $DET_RELEASE_STATUS"

DET_RELEASE_BASE=${DET_VERSION%%-*}
DET_MANIFEST="release/manifests/v$DET_VERSION.manifest"

[ "$DET_VERSION_CODE" -gt 11 ] \
    && ok "versionCode is above every legacy component code" \
    || fail "versionCode must remain above the legacy maximum of 11"

DET_TEMPLATE_INDEX=0
check_template() {
    DET_TEMPLATE_INDEX=$((DET_TEMPLATE_INDEX + 1))
    DET_TEMPLATE_PATH=$1
    DET_RENDERED="$DET_CHECK_TMP/$DET_TEMPLATE_INDEX-module.prop"
    det_render_version_template "$DET_TEMPLATE_PATH" "$DET_RENDERED"
    DET_RENDERED_VERSION=$(sed -n 's/^version=//p' "$DET_RENDERED")
    DET_RENDERED_CODE=$(sed -n 's/^versionCode=//p' "$DET_RENDERED")
    check_equal "$DET_TEMPLATE_PATH version" "v$DET_VERSION" "$DET_RENDERED_VERSION"
    check_equal "$DET_TEMPLATE_PATH versionCode" "$DET_VERSION_CODE" "$DET_RENDERED_CODE"
    grep -Fq "$DET_CODENAME" "$DET_RENDERED" \
        && ok "$DET_TEMPLATE_PATH contains $DET_CODENAME" \
        || fail "$DET_TEMPLATE_PATH does not expose $DET_CODENAME"
}

check_template magisk-module/module.prop.in
check_template usb-install/install/module.prop.in
check_template usb-install/restore/module.prop.in

grep -Fq 'rootProject.file("../version.properties")' companion/app/build.gradle.kts \
    && grep -Fq 'versionCode = determinationVersionCode' companion/app/build.gradle.kts \
    && grep -Fq 'versionName = determinationVersionName' companion/app/build.gradle.kts \
    && ok "companion consumes central version metadata" \
    || fail "companion does not consume central version metadata"

for DET_PACKAGER in \
    magisk-module/build-module.sh \
    usb-install/build-usb-payload.sh
do
    grep -Fq 'det_load_version' "$DET_PACKAGER" \
        && ok "$DET_PACKAGER consumes central version metadata" \
        || fail "$DET_PACKAGER does not consume central version metadata"
done

grep -Fq "$DET_RELEASE_BASE \"$DET_CODENAME\"" CHANGELOG.md \
    && ok "changelog entry exists" \
    || fail "missing changelog entry for $DET_RELEASE_BASE \"$DET_CODENAME\""
grep -Fq "## $DET_CODENAME: $DET_RELEASE_BASE" RELEASES.md \
    && ok "release plan contains $DET_RELEASE_BASE $DET_CODENAME" \
    || fail "release plan does not contain $DET_RELEASE_BASE $DET_CODENAME"

validate_manifest() {
    DET_MANIFEST_FILE=$1
    [ -f "$DET_MANIFEST_FILE" ] || { fail "missing release manifest: $DET_MANIFEST_FILE"; return; }
    if ! awk '
        /^[[:space:]]*(#|$)/ { next }
        !/^[A-Za-z0-9][A-Za-z0-9._-]*=/ { print "invalid line " NR; bad=1; next }
        { key=$0; sub(/=.*/, "", key); if (seen[key]++) { print "duplicate key " key; bad=1 } }
        END { exit bad }
    ' "$DET_MANIFEST_FILE" >"$DET_CHECK_TMP/manifest-errors"; then
        while IFS= read -r DET_ERROR; do fail "$DET_MANIFEST_FILE: $DET_ERROR"; done <"$DET_CHECK_TMP/manifest-errors"
        return
    fi
    for DET_REQUIRED in schema project.commit device.product device.rom \
        input.boot.pristine.sha256 input.kernel.config.sha256 \
        toolchain.android.ndk toolchain.gradle source.libhybris.url \
        source.libhybris.revision source.wlroots.url source.wlroots.revision \
        source.phoc.url source.phoc.revision source.mesa.revision \
        source.minigbm.revision source.lxc.revision input.hwc.google_archive.sha256 \
        input.companion.dependencies.sha256 input.guest.base.sha256 \
        input.local.patches.sha256 signing.companion.certificate.sha256
    do
        DET_VALUE=$(sed -n "s/^$DET_REQUIRED=//p" "$DET_MANIFEST_FILE")
        [ -n "$DET_VALUE" ] || { fail "$DET_MANIFEST_FILE: missing $DET_REQUIRED"; continue; }
        case "$DET_REQUIRED" in
            *.revision|project.commit)
                case "$DET_VALUE" in
                    UNRESOLVED) ;;
                    *) printf '%s' "$DET_VALUE" | grep -Eq '^[0-9a-f]{40}$' \
                        || fail "$DET_MANIFEST_FILE: $DET_REQUIRED is not a Git object ID" ;;
                esac ;;
            *.sha256)
                case "$DET_VALUE" in
                    UNRESOLVED) ;;
                    *) printf '%s' "$DET_VALUE" | grep -Eq '^[0-9a-f]{64}$' \
                        || fail "$DET_MANIFEST_FILE: $DET_REQUIRED is not a SHA-256 digest" ;;
                esac ;;
        esac
        if [ "$DET_VALUE" = UNRESOLVED ]; then
            if [ "$DET_MODE" = ship ]; then fail "$DET_MANIFEST_FILE: unresolved $DET_REQUIRED"
            else warn "$DET_MANIFEST_FILE: unresolved $DET_REQUIRED"; fi
        fi
    done
    ok "release manifest syntax: $DET_MANIFEST_FILE"
}

validate_manifest "$DET_MANIFEST"

manifest_value() { sed -n "s/^$1=//p" "$DET_MANIFEST"; }

validate_source_locks() {
    [ -f guest/sources.lock ] || { fail "missing guest/sources.lock"; return; }
    # shellcheck disable=SC1091
    . guest/sources.lock
    check_equal "guest libhybris pin" "$(manifest_value source.libhybris.revision)" "$LIBHYBRIS_COMMIT"
    check_equal "guest wlroots pin" "$(manifest_value source.wlroots.revision)" "$WLROOTS_COMMIT"
    check_equal "guest phoc pin" "$(manifest_value source.phoc.revision)" "$PHOC_COMMIT"
    DET_HWC_LIBHYBRIS=$(sed -n 's/^LIBHYBRIS_REV=//p' hwc2-compat/build.sh | head -n 1)
    [ -n "$DET_HWC_LIBHYBRIS" ] \
        && check_equal "HWC libhybris pin" "$LIBHYBRIS_COMMIT" "$DET_HWC_LIBHYBRIS" \
        || fail "HWC build does not declare a libhybris revision"
}

validate_source_locks

DET_HEAD=$(git rev-parse --short=12 HEAD)
if [ -n "$(git status --porcelain)" ]; then
    if [ "$DET_MODE" = ship ]; then fail "worktree is dirty at $DET_HEAD"
    else warn "worktree is dirty at $DET_HEAD (expected during development)"; fi
else
    ok "worktree is clean at $DET_HEAD"
fi

if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    DET_UPSTREAM=$(git rev-parse --abbrev-ref '@{upstream}')
    set -- $(git rev-list --left-right --count HEAD..."$DET_UPSTREAM")
    DET_AHEAD=$1 DET_BEHIND=$2
    if [ "$DET_BEHIND" -gt 0 ]; then
        if [ "$DET_MODE" = ship ]; then
            fail "HEAD is $DET_AHEAD ahead / $DET_BEHIND behind $DET_UPSTREAM"
        else
            warn "HEAD is $DET_AHEAD ahead / $DET_BEHIND behind $DET_UPSTREAM"
        fi
    else
        ok "HEAD contains $DET_UPSTREAM ($DET_AHEAD local commits)"
    fi
else
    warn "branch has no upstream; remote ancestry was not checked"
fi

ok "release-critical guest and HWC sources are validated against immutable pins"

DET_MODULE_ZIP="magisk-module/determination-magisk-v$DET_VERSION.zip"
if [ -f "$DET_MODULE_ZIP" ]; then
    DET_ZIP_VERSION=$(python3 -c "import zipfile; p=zipfile.ZipFile('$DET_MODULE_ZIP').read('module.prop').decode(); print(next(x[8:] for x in p.splitlines() if x.startswith('version=')))")
    DET_ZIP_CODE=$(python3 -c "import zipfile; p=zipfile.ZipFile('$DET_MODULE_ZIP').read('module.prop').decode(); print(next(x[12:] for x in p.splitlines() if x.startswith('versionCode=')))")
    check_equal "built Magisk module version" "v$DET_VERSION" "$DET_ZIP_VERSION"
    check_equal "built Magisk module versionCode" "$DET_VERSION_CODE" "$DET_ZIP_CODE"
else
    warn "current Magisk module has not been built"
fi

if [ -f companion/app/build/outputs/apk/release/app-release-unsigned.apk ] \
    && [ ! -f companion/app/build/outputs/apk/release/app-release.apk ]; then
    warn "companion release compiles but is unsigned; configure the Aqua signing identity before shipping"
fi

if [ "$DET_MODE" = ship ]; then
    [ "$DET_RELEASE_STATUS" = ready ] \
        && ok "release status is ready" \
        || fail "release status is '$DET_RELEASE_STATUS', not 'ready'"

    DET_TAG="v$DET_VERSION"
    if git rev-parse -q --verify "refs/tags/$DET_TAG" >/dev/null; then
        DET_TAG_HEAD=$(git rev-list -n1 "$DET_TAG")
        DET_FULL_HEAD=$(git rev-parse HEAD)
        [ "$DET_TAG_HEAD" = "$DET_FULL_HEAD" ] \
            && ok "$DET_TAG points at HEAD" \
            || fail "$DET_TAG already exists on another commit"
    else
        ok "$DET_TAG is available"
    fi

    for DET_ARTIFACT in \
        boot/determination-boot.img \
        "$DET_MODULE_ZIP" \
        companion/app/build/outputs/apk/release/app-release.apk \
        dist/usb-payload/SHA256SUMS \
        "$DET_MANIFEST"
    do
        [ -f "$DET_ARTIFACT" ] \
            && ok "artifact exists: $DET_ARTIFACT" \
            || fail "missing release artifact: $DET_ARTIFACT"
    done

    if [ -f dist/usb-payload/SHA256SUMS ]; then
        (cd dist/usb-payload && sha256sum -c SHA256SUMS) \
            && ok "USB payload checksums verify" \
            || fail "USB payload checksums do not verify"
        for DET_PAYLOAD_FILE in \
            "determination-magisk-v$DET_VERSION.zip" \
            "determination-companion-v$DET_VERSION.apk"
        do
            grep -Fq "$DET_PAYLOAD_FILE" dist/usb-payload/SHA256SUMS \
                && ok "USB payload contains $DET_PAYLOAD_FILE" \
                || fail "USB payload checksums do not reference $DET_PAYLOAD_FILE"
        done
    fi

    if [ -f companion/app/build/outputs/apk/release/app-release.apk ]; then
        if command -v apksigner >/dev/null 2>&1; then
            apksigner verify --verbose --print-certs \
                companion/app/build/outputs/apk/release/app-release.apk >/dev/null \
                && ok "companion APK signature verifies" \
                || fail "companion APK signature does not verify"
        else
            fail "apksigner is required to verify the companion release APK"
        fi
    fi
fi

if [ "$DET_FAILURES" -ne 0 ]; then
    printf '\n%d release check(s) failed.\n' "$DET_FAILURES" >&2
    exit 1
fi

printf '\nDetermination %s "%s": %s checks passed.\n' \
    "$DET_VERSION" "$DET_CODENAME" "$DET_MODE"
