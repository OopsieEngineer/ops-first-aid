# ssl

Helpers for creating and inspecting TLS material.

## self-signed-cert.sh

Generates a self-signed TLS certificate signed with SHA-256, including proper
X.509 v3 extensions and Subject Alternative Names. Suitable for lab, internal
and test environments — not for public-facing production services.

### Requirements

- `bash`
- `openssl` 1.1.1 or newer

### Usage

```bash
chmod +x self-signed-cert.sh
./self-signed-cert.sh --hostname HOST --days N [OPTIONS]
```

### Options

| Option | Description |
| --- | --- |
| `-h, --hostname HOST` | **Required.** Common Name and primary SAN entry. |
| `-d, --days N` | **Required.** Validity period in days (1–3650). |
| `--alt NAME` | Extra SAN entry (DNS name or IP address). Repeatable. |
| `--key-type TYPE` | `rsa` (default) or `ec`. |
| `--bits N` | RSA key size, default `2048`, minimum `2048`. |
| `--curve NAME` | EC curve, default `prime256v1` (P-256). |
| `--out-dir DIR` | Output directory, default current directory. |
| `--force` | Overwrite existing key/certificate files. |
| `--help` | Show usage. |

### Output

| File | Mode | Content |
| --- | --- | --- |
| `OUT_DIR/HOST.key` | `0600` | Unencrypted private key |
| `OUT_DIR/HOST.crt` | `0644` | Self-signed certificate |

### Examples

One-year certificate for a single hostname:

```bash
./self-signed-cert.sh --hostname app.internal.lan --days 365
```

90-day certificate with additional DNS and IP SAN entries:

```bash
./self-signed-cert.sh -h app.internal.lan -d 90 \
  --alt www.app.internal.lan \
  --alt 10.0.0.25
```

EC (P-256) key written to a dedicated directory:

```bash
./self-signed-cert.sh -h traefik.local -d 365 --key-type ec --out-dir ./certs
```

Stronger RSA key, overwriting previous files:

```bash
./self-signed-cert.sh -h minio.local -d 730 --bits 4096 --force
```

Wildcard certificate:

```bash
./self-signed-cert.sh -h '*.internal.lan' -d 365 --alt internal.lan
```

### Certificate properties

- Signature algorithm: `sha256WithRSAEncryption` or `ecdsa-with-SHA256`
- `basicConstraints = critical, CA:FALSE`
- `keyUsage = critical, digitalSignature, keyEncipherment`
- `extendedKeyUsage = serverAuth, clientAuth`
- `subjectKeyIdentifier = hash`
- `subjectAltName` built from `--hostname` plus every `--alt` value; values that
  look like IP addresses become `IP:` entries, everything else `DNS:`

### Verifying the result

```bash
openssl x509 -in app.internal.lan.crt -noout -text
openssl x509 -in app.internal.lan.crt -noout -subject -dates -ext subjectAltName
```

### Notes

- The private key is unencrypted so services can start without a passphrase.
  Keep it readable only by the owning service account.
- Clients will not trust the certificate until it is added to their trust store,
  for example `/usr/local/share/ca-certificates/` followed by
  `sudo update-ca-certificates` on Debian/Ubuntu.
- The script refuses to overwrite existing files unless `--force` is given.

## cert-expiry-check.sh

Reports the `notAfter` (expiry) date and remaining days for certificate files
on disk and/or live TLS endpoints. Read-only; it never modifies anything.

### Requirements

- `bash`, `openssl`
- `timeout` and GNU `date` (coreutils) for `--host` checks

### Usage

```bash
chmod +x cert-expiry-check.sh
./cert-expiry-check.sh [OPTIONS] [CERT_FILE...]
```

### Targets

| Target | Description |
| --- | --- |
| `CERT_FILE` | PEM or DER certificate file. Repeatable. |
| `--host HOST[:PORT]` | Live TLS endpoint, default port `443`. Repeatable. |
| `--dir DIR` | Every `*.crt` / `*.pem` file directly inside `DIR`. |

### Options

| Option | Description |
| --- | --- |
| `-w, --warn N` | Warning threshold in days, default `30`. |
| `-c, --crit N` | Critical threshold in days, default `7`. Must be ≤ `--warn`. |
| `-t, --timeout N` | TLS connection timeout in seconds, default `10`. |
| `-q, --quiet` | Print only WARN, CRITICAL and ERROR lines. |
| `--help` | Show usage. |

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | All certificates OK |
| `1` | At least one certificate inside the warning threshold |
| `2` | At least one certificate inside the critical threshold or expired |
| `3` | Usage or runtime error (unreadable file, failed handshake) |

### Examples

Single file:

```bash
./cert-expiry-check.sh /etc/ssl/certs/app.crt
```

Live endpoints, including a non-standard port:

```bash
./cert-expiry-check.sh --host example.com --host rabbitmq.local:5671
```

Whole directory with custom thresholds:

```bash
./cert-expiry-check.sh --dir /etc/ssl/certs --warn 45 --crit 14
```

Cron / monitoring use — output only when something needs attention:

```bash
./cert-expiry-check.sh --dir /etc/ssl/certs --quiet || echo "certificate attention required"
```

### Sample output

```text
OK       /etc/ssl/certs/app.crt                   notAfter=2027-10-01 16:40:48 EEST (365 days)
CRITICAL /etc/ssl/certs/legacy.crt                notAfter=2026-10-06 16:40:48 EEST (5 days)
```
