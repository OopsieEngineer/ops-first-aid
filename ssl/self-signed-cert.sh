#!/usr/bin/env bash
#
# self-signed-cert.sh - Generate a self-signed TLS certificate
#
# Creates a modern self-signed certificate (SHA-256, 2048-bit RSA or
# EC P-256) with Subject Alternative Names for the given hostname.
#
# Usage:
#   ./self-signed-cert.sh --hostname example.local --days 365
#   ./self-signed-cert.sh -h example.local -d 90 --alt www.example.local --alt 10.0.0.5
#   ./self-signed-cert.sh -h example.local -d 365 --key-type ec --out-dir ./certs
#

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

HOSTNAME_ARG=""
DAYS=365
KEY_TYPE="rsa"
RSA_BITS=2048
EC_CURVE="prime256v1"
OUT_DIR="."
FORCE=0
ALT_NAMES=()

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME --hostname HOST --days N [OPTIONS]

Generate a self-signed TLS certificate signed with SHA-256.

Required:
  -h, --hostname HOST      Common Name / primary DNS SAN entry
  -d, --days N             Validity period in days (1-3650)

Options:
      --alt NAME           Additional SAN entry (DNS name or IP). Repeatable.
      --key-type TYPE      rsa (default) or ec
      --bits N             RSA key size, default $RSA_BITS (minimum 2048)
      --curve NAME         EC curve, default $EC_CURVE
      --out-dir DIR        Output directory, default current directory
      --force              Overwrite existing key/certificate files
      --help               Show this help

Output:
  OUT_DIR/HOST.key         Private key (mode 0600)
  OUT_DIR/HOST.crt         Self-signed certificate
EOF
}

die() {
    echo "$SCRIPT_NAME: $*" >&2
    exit 1
}

is_ip() {
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ "$1" =~ ^[0-9A-Fa-f:]+:[0-9A-Fa-f:]*$ ]]
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--hostname)
            [[ $# -ge 2 ]] || die "missing value for $1"
            HOSTNAME_ARG="$2"; shift 2 ;;
        -d|--days)
            [[ $# -ge 2 ]] || die "missing value for $1"
            DAYS="$2"; shift 2 ;;
        --alt)
            [[ $# -ge 2 ]] || die "missing value for $1"
            ALT_NAMES+=("$2"); shift 2 ;;
        --key-type)
            [[ $# -ge 2 ]] || die "missing value for $1"
            KEY_TYPE="$2"; shift 2 ;;
        --bits)
            [[ $# -ge 2 ]] || die "missing value for $1"
            RSA_BITS="$2"; shift 2 ;;
        --curve)
            [[ $# -ge 2 ]] || die "missing value for $1"
            EC_CURVE="$2"; shift 2 ;;
        --out-dir)
            [[ $# -ge 2 ]] || die "missing value for $1"
            OUT_DIR="$2"; shift 2 ;;
        --force)
            FORCE=1; shift ;;
        --help)
            usage; exit 0 ;;
        *)
            usage >&2
            die "unknown option: $1" ;;
    esac
done

command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

[[ -n "$HOSTNAME_ARG" ]] || { usage >&2; die "--hostname is required"; }
[[ "$HOSTNAME_ARG" =~ ^[A-Za-z0-9._*-]+$ ]] || die "invalid hostname: $HOSTNAME_ARG"
[[ "$DAYS" =~ ^[0-9]+$ ]] || die "--days must be a positive integer"
(( DAYS >= 1 && DAYS <= 3650 )) || die "--days must be between 1 and 3650"

case "$KEY_TYPE" in
    rsa)
        [[ "$RSA_BITS" =~ ^[0-9]+$ ]] || die "--bits must be an integer"
        (( RSA_BITS >= 2048 )) || die "--bits must be at least 2048"
        ;;
    ec)
        [[ "$EC_CURVE" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid curve: $EC_CURVE"
        ;;
    *)
        die "--key-type must be 'rsa' or 'ec'"
        ;;
esac

mkdir -p "$OUT_DIR"
KEY_FILE="${OUT_DIR%/}/${HOSTNAME_ARG}.key"
CRT_FILE="${OUT_DIR%/}/${HOSTNAME_ARG}.crt"

if (( FORCE == 0 )); then
    [[ -e "$KEY_FILE" ]] && die "$KEY_FILE already exists (use --force to overwrite)"
    [[ -e "$CRT_FILE" ]] && die "$CRT_FILE already exists (use --force to overwrite)"
fi

SAN_ENTRIES=()
if is_ip "$HOSTNAME_ARG"; then
    SAN_ENTRIES+=("IP:$HOSTNAME_ARG")
else
    SAN_ENTRIES+=("DNS:$HOSTNAME_ARG")
fi
for name in ${ALT_NAMES+"${ALT_NAMES[@]}"}; do
    if is_ip "$name"; then
        SAN_ENTRIES+=("IP:$name")
    else
        SAN_ENTRIES+=("DNS:$name")
    fi
done

SAN_LIST="$(IFS=,; echo "${SAN_ENTRIES[*]}")"

CONFIG_FILE="$(mktemp)"
trap 'rm -f "$CONFIG_FILE"' EXIT

cat >"$CONFIG_FILE" <<EOF
[req]
default_md         = sha256
prompt             = no
distinguished_name = dn
x509_extensions    = v3_ext

[dn]
CN = $HOSTNAME_ARG

[v3_ext]
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth, clientAuth
subjectKeyIdentifier   = hash
subjectAltName         = $SAN_LIST
EOF

if [[ "$KEY_TYPE" == "rsa" ]]; then
    KEY_SPEC=("-newkey" "rsa:${RSA_BITS}")
else
    KEY_SPEC=("-newkey" "ec" "-pkeyopt" "ec_paramgen_curve:${EC_CURVE}")
fi

OLD_UMASK="$(umask)"
umask 077
openssl req -x509 -nodes \
    "${KEY_SPEC[@]}" \
    -sha256 \
    -days "$DAYS" \
    -keyout "$KEY_FILE" \
    -out "$CRT_FILE" \
    -config "$CONFIG_FILE" \
    -extensions v3_ext
umask "$OLD_UMASK"

chmod 600 "$KEY_FILE"
chmod 644 "$CRT_FILE"

echo
echo "Private key : $KEY_FILE"
echo "Certificate : $CRT_FILE"
echo "Key type    : $([[ "$KEY_TYPE" == rsa ]] && echo "RSA ${RSA_BITS}-bit" || echo "EC ${EC_CURVE}")"
echo "Signature   : sha256"
echo "SANs        : $SAN_LIST"
openssl x509 -in "$CRT_FILE" -noout -subject -dates
