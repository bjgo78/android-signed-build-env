#!/bin/bash
#
# create-signed-env.sh - set up vendor/lineage-priv/keys for signed LineageOS builds
#
# Run from the root of the Android source tree (where build/envsetup.sh is).
#
#   ./create-signed-env.sh                  generate new keys (or repair keys.mk if keys exist)
#   ./create-signed-env.sh --subject SUBJ   same, without the subject prompts
#   ./create-signed-env.sh --backup [FILE]  pack vendor/lineage-priv/keys into a tarball
#   ./create-signed-env.sh --restore FILE   restore keys from a tarball made with --backup
#   ./create-signed-env.sh --check          verify keys, keys.mk and BUILD.bazel
#
# Based on the idea of 306bobby-android/crDroid-build-signed-script.

set -euo pipefail

KEYS_DIR="vendor/lineage-priv/keys"
KEYS_MK="$KEYS_DIR/keys.mk"
BUILD_BAZEL="$KEYS_DIR/BUILD.bazel"
MAKE_KEY="development/tools/make_key"

# Certificates the build expects (LineageOS 22.2 / 23.2)
CERTS=(bluetooth media networkstack nfc platform releasekey sdk_sandbox shared testkey verifiedboot)

# Lines keys.mk must contain. The Bluetooth line is needed on Android 16: without it
# Bluetooth's SELinux seinfo uses the test key while the app is signed with ours, and
# zygote kills com.android.bluetooth on every start.
KEYS_MK_LINES=(
    "PRODUCT_DEFAULT_DEV_CERTIFICATE := $KEYS_DIR/releasekey"
    "PRODUCT_MAINLINE_BLUETOOTH_SEPOLICY_DEV_CERTIFICATES := $KEYS_DIR/"
)

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ":: $*"; }

require_source_root() {
    [[ -f build/envsetup.sh ]] || die "run this from the root of the Android source tree"
}

# --- keys.mk / BUILD.bazel -------------------------------------------------

write_build_bazel() {
    cat > "$BUILD_BAZEL" <<'BAZEL'
filegroup(
    name = "android_certificate_directory",
    srcs = glob([
        "*.pk8",
        "*.pem",
    ]),
    visibility = ["//visibility:public"],
)
BAZEL
}

# Adds missing lines to keys.mk and creates BUILD.bazel if needed. Never touches keys.
repair_config() {
    touch "$KEYS_MK"
    local line
    for line in "${KEYS_MK_LINES[@]}"; do
        local var="${line%% :=*}"
        if grep -q "^${var}[[:space:]]*:=" "$KEYS_MK"; then
            if ! grep -qxF "$line" "$KEYS_MK"; then
                echo "WARNING: $KEYS_MK sets $var to something else:" >&2
                grep "^${var}[[:space:]]*:=" "$KEYS_MK" >&2
                echo "         expected: $line" >&2
            fi
        else
            echo "$line" >> "$KEYS_MK"
            info "added to keys.mk: $line"
        fi
    done
    [[ -f "$BUILD_BAZEL" ]] || { write_build_bazel; info "created BUILD.bazel"; }
}

# --- check -----------------------------------------------------------------

check() {
    local ok=1 cert line
    [[ -d "$KEYS_DIR" ]] || die "$KEYS_DIR does not exist"
    for cert in "${CERTS[@]}"; do
        if [[ ! -f "$KEYS_DIR/$cert.pk8" || ! -f "$KEYS_DIR/$cert.x509.pem" ]]; then
            echo "MISSING: $cert.pk8 / $cert.x509.pem"; ok=0
        elif ! openssl x509 -in "$KEYS_DIR/$cert.x509.pem" -noout 2>/dev/null; then
            echo "BROKEN:  $cert.x509.pem is not a valid certificate"; ok=0
        fi
    done
    for line in "${KEYS_MK_LINES[@]}"; do
        grep -qxF "$line" "$KEYS_MK" 2>/dev/null || { echo "keys.mk lacks: $line"; ok=0; }
    done
    [[ -f "$BUILD_BAZEL" ]] || { echo "MISSING: BUILD.bazel"; ok=0; }

    if (( ok )); then
        info "all ${#CERTS[@]} certificates present, keys.mk and BUILD.bazel OK"
        echo "releasekey SHA-256: $(openssl x509 -in "$KEYS_DIR/releasekey.x509.pem" -noout -fingerprint -sha256 | cut -d= -f2)"
        echo "subject:            $(openssl x509 -in "$KEYS_DIR/releasekey.x509.pem" -noout -subject | sed 's/^subject=//')"
    else
        echo "Run without arguments to repair keys.mk/BUILD.bazel, or --restore to bring back keys."
        return 1
    fi
}

# --- backup / restore ------------------------------------------------------

backup() {
    local out="${1:-$HOME/android-keys-$(date +%Y%m%d-%H%M%S).tar.gz}"
    [[ -d "$KEYS_DIR" ]] || die "$KEYS_DIR does not exist"
    [[ -e "$out" ]] && die "$out already exists"
    (umask 077; tar -czf "$out" -C vendor/lineage-priv keys)
    info "keys saved to $out (keep it somewhere safe, NOT in a public repo)"
}

restore() {
    local in="${1:-}"
    [[ -n "$in" && -f "$in" ]] || die "usage: $0 --restore <backup.tar.gz>"
    [[ -e "$KEYS_DIR" ]] && die "$KEYS_DIR already exists; move it away first if you really want to replace it"
    mkdir -p vendor/lineage-priv
    tar -xzf "$in" -C vendor/lineage-priv
    [[ -d "$KEYS_DIR" ]] || die "the tarball does not contain a keys/ directory"
    chmod 700 "$KEYS_DIR"; chmod 600 "$KEYS_DIR"/*.pk8
    repair_config
    check
}

# --- generate --------------------------------------------------------------

ask() {  # ask <prompt> <default> -> echoes answer
    local reply
    read -r -p "$1 [$2]: " reply
    echo "${reply:-$2}"
}

prompt_subject() {
    local c st l o ou cn email field
    c=$(ask "Country code (C)" "US")
    st=$(ask "State or province (ST)" "California")
    l=$(ask "Locality (L)" "Mountain View")
    o=$(ask "Organization (O)" "Android")
    ou=$(ask "Organizational unit (OU)" "Android")
    cn=$(ask "Common name (CN)" "Android")
    email=$(ask "Email address" "android@android.com")
    [[ "$c" =~ ^[A-Za-z]{2}$ ]] || die "country code must be exactly 2 letters"
    for field in "$st" "$l" "$o" "$ou" "$cn" "$email"; do
        [[ "$field" != */* ]] || die "fields cannot contain '/': $field"
    done
    SUBJECT="/C=${c^^}/ST=$st/L=$l/O=$o/OU=$ou/CN=$cn/emailAddress=$email"
}

generate() {
    [[ -x "$MAKE_KEY" ]] || die "$MAKE_KEY not found (did repo sync finish?)"
    command -v openssl >/dev/null || die "openssl is not installed"

    if [[ -z "${SUBJECT:-}" ]]; then
        prompt_subject
    fi
    echo
    echo "Subject: $SUBJECT"
    read -r -p "Is this correct? [Y/n]: " confirm
    [[ "${confirm:-Y}" =~ ^[Yy]$ ]] || { echo "Aborted, nothing changed."; exit 1; }

    local tmp cert
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    chmod 700 "$tmp"

    for cert in "${CERTS[@]}"; do
        info "generating $cert"
        # make_key asks for a password; an empty line means no password (signing
        # during the build cannot use passwords). make_key always exits 1 because of
        # its EXIT trap, so check the files instead of the exit code.
        echo | "$MAKE_KEY" "$tmp/$cert" "$SUBJECT" >/dev/null 2>&1 || true
        [[ -s "$tmp/$cert.pk8" && -s "$tmp/$cert.x509.pem" ]] || die "make_key failed for $cert"
        openssl x509 -in "$tmp/$cert.x509.pem" -noout || die "invalid certificate for $cert"
    done

    mkdir -p vendor/lineage-priv
    mv "$tmp" "$KEYS_DIR"
    trap - EXIT
    chmod 700 "$KEYS_DIR"; chmod 600 "$KEYS_DIR"/*.pk8

    : > "$KEYS_MK"
    repair_config
    check
    echo
    echo "Next: run '$0 --backup' and keep the tarball safe. Builds signed with"
    echo "different keys cannot be dirty-flashed over each other."
}

# --- main ------------------------------------------------------------------

require_source_root
case "${1:-}" in
    --check)   check ;;
    --backup)  backup "${2:-}" ;;
    --restore) restore "${2:-}" ;;
    --subject) [[ -n "${2:-}" ]] || die "--subject needs a value like /C=HU/ST=.../CN=..."
               SUBJECT="$2"
               [[ -e "$KEYS_DIR" ]] && die "$KEYS_DIR already exists; refusing to generate new keys"
               generate ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
    "")
        if [[ -d "$KEYS_DIR" ]]; then
            info "$KEYS_DIR exists, keeping the keys and only repairing keys.mk/BUILD.bazel"
            repair_config
            check
        else
            generate
        fi ;;
    *) die "unknown option: $1 (see --help)" ;;
esac
