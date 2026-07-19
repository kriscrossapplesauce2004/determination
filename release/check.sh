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

DET_MOVING_INPUTS=$(rg -n --glob '!kernel/src/**' \
    'git clone.*(-b (master|main|feature/|group/)|libhybris\.git)' \
    guest hwc2-compat kernel 2>/dev/null || true)
if [ -n "$DET_MOVING_INPUTS" ]; then
    if [ "$DET_MODE" = ship ]; then
        fail "release-critical source clones are still moving"
    else
        warn "release-critical source clones are still moving"
    fi
    printf '%s\n' "$DET_MOVING_INPUTS" | sed 's/^/      /'
else
    ok "no known moving release-critical source clones"
fi

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
        "release/manifests/v$DET_VERSION.manifest"
    do
        [ -f "$DET_ARTIFACT" ] \
            && ok "artifact exists: $DET_ARTIFACT" \
            || fail "missing release artifact: $DET_ARTIFACT"
    done

    if [ -f dist/usb-payload/SHA256SUMS ]; then
        for DET_PAYLOAD_FILE in \
            "determination-magisk-v$DET_VERSION.zip" \
            "determination-companion-v$DET_VERSION.apk"
        do
            grep -Fq "$DET_PAYLOAD_FILE" dist/usb-payload/SHA256SUMS \
                && ok "USB payload contains $DET_PAYLOAD_FILE" \
                || fail "USB payload checksums do not reference $DET_PAYLOAD_FILE"
        done
    fi
fi

if [ "$DET_FAILURES" -ne 0 ]; then
    printf '\n%d release check(s) failed.\n' "$DET_FAILURES" >&2
    exit 1
fi

printf '\nDetermination %s "%s": %s checks passed.\n' \
    "$DET_VERSION" "$DET_CODENAME" "$DET_MODE"
