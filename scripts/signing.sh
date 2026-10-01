# Sourced by the build scripts. Code signing settings come from the environment or from
# scripts/local.env (gitignored; see scripts/local.env.example):
#   UCEDGE_SIGN_IDENTITY  a codesigning identity name from `security find-identity -v -p codesigning`,
#                         e.g. "Apple Development: Jane Doe (ABCDE12345)", or "-" for ad-hoc signing.
#   UCEDGE_EXPECTED_DR    optional: a requirement UCEdge.app must satisfy after signing. macOS keys
#                         the Accessibility / Input Monitoring / Local Network grants to the app's
#                         designated requirement; this guards against silently losing them.
# Ad-hoc signing works, but every rebuild then looks like a new app to macOS and the
# permissions have to be granted again.

UCEDGE_SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "$UCEDGE_SCRIPTS_DIR/local.env" ]]; then
    # Values already in the environment win over local.env.
    ucedge_env_identity=${UCEDGE_SIGN_IDENTITY:-}
    ucedge_env_dr=${UCEDGE_EXPECTED_DR:-}
    # shellcheck source=/dev/null
    source "$UCEDGE_SCRIPTS_DIR/local.env"
    [[ -z "$ucedge_env_identity" ]] || UCEDGE_SIGN_IDENTITY=$ucedge_env_identity
    [[ -z "$ucedge_env_dr" ]] || UCEDGE_EXPECTED_DR=$ucedge_env_dr
fi

# ucedge_signing_check: fail early (before building) when the identity is unset or unknown.
# Sets UCEDGE_SIGN_HASH ("-" for ad-hoc).
ucedge_signing_check() {
    if [[ -z "${UCEDGE_SIGN_IDENTITY:-}" ]]; then
        echo "error: no signing identity. Run: cp scripts/local.env.example scripts/local.env and set" >&2
        echo "       UCEDGE_SIGN_IDENTITY (security find-identity -v -p codesigning lists yours), or \"-\" for ad-hoc." >&2
        return 1
    fi
    if [[ "$UCEDGE_SIGN_IDENTITY" == "-" ]]; then
        UCEDGE_SIGN_HASH=-
        return 0
    fi
    UCEDGE_SIGN_HASH=$(security find-identity -v -p codesigning | awk -v name="\"$UCEDGE_SIGN_IDENTITY\"" \
        'index($0, name) { print $2; exit }')
    if [[ -z "$UCEDGE_SIGN_HASH" ]]; then
        echo "error: signing identity \"$UCEDGE_SIGN_IDENTITY\" not found (security find-identity -v -p codesigning)" >&2
        return 1
    fi
}

# ucedge_sign APP_PATH: sign a bundle with UCEDGE_SIGN_IDENTITY (hardened runtime).
ucedge_sign() {
    local app=$1
    [[ -n "${UCEDGE_SIGN_HASH:-}" ]] || ucedge_signing_check
    if [[ "$UCEDGE_SIGN_HASH" == "-" ]]; then
        echo "note: ad-hoc signing; macOS will ask for permissions again after every rebuild" >&2
    fi
    codesign --force --timestamp=none --options runtime --sign "$UCEDGE_SIGN_HASH" "$app"
    codesign -v "$app"
    echo "codesign -v: OK"
}
