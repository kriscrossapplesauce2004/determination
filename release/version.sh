#!/bin/sh
# Shared version metadata loader/renderer for release packaging scripts.

det_load_version() {
    DET_VERSION_FILE=$1
    [ -f "$DET_VERSION_FILE" ] || {
        echo "missing version metadata: $DET_VERSION_FILE" >&2
        return 1
    }

    DET_VERSION=$(sed -n 's/^version=//p' "$DET_VERSION_FILE")
    DET_VERSION_CODE=$(sed -n 's/^versionCode=//p' "$DET_VERSION_FILE")
    DET_CODENAME=$(sed -n 's/^codename=//p' "$DET_VERSION_FILE")
    DET_RELEASE_STATUS=$(sed -n 's/^status=//p' "$DET_VERSION_FILE")

    printf '%s\n' "$DET_VERSION" | grep -Eq \
        '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$' || {
        echo "invalid SemVer in $DET_VERSION_FILE: $DET_VERSION" >&2
        return 1
    }
    case "$DET_VERSION_CODE" in
        ''|*[!0-9]*) echo "invalid versionCode in $DET_VERSION_FILE: $DET_VERSION_CODE" >&2; return 1 ;;
    esac
    [ "$DET_VERSION_CODE" -gt 0 ] && [ "$DET_VERSION_CODE" -le 2100000000 ] || {
        echo "versionCode must be between 1 and 2100000000: $DET_VERSION_CODE" >&2
        return 1
    }
    case "$DET_CODENAME" in
        ''|*[!A-Za-z0-9_-]*) echo "invalid codename in $DET_VERSION_FILE: $DET_CODENAME" >&2; return 1 ;;
    esac
    case "$DET_RELEASE_STATUS" in
        development|ready|released) ;;
        *) echo "invalid release status in $DET_VERSION_FILE: $DET_RELEASE_STATUS" >&2; return 1 ;;
    esac
}

det_render_version_template() {
    DET_TEMPLATE=$1
    DET_OUTPUT=$2
    sed -e "s/@VERSION@/$DET_VERSION/g" \
        -e "s/@VERSION_CODE@/$DET_VERSION_CODE/g" \
        -e "s/@CODENAME@/$DET_CODENAME/g" \
        "$DET_TEMPLATE" > "$DET_OUTPUT"
}
