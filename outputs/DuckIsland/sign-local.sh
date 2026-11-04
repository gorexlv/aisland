#!/bin/zsh
# Local certificate identity keeps TCC authorization stable across recompiles.
# A dedicated keychain is used; the local certificate is trusted only for code signing.
set -euo pipefail
umask 077
signing_dir="$HOME/Library/Application Support/DuckIsland/Signing"
mkdir -p "$signing_dir"
keychain_path="$signing_dir/duck-island.keychain-db"
password_path="$signing_dir/keychain-password"
certificate_path="$signing_dir/certificate.pem"
if [[ ! -f "$certificate_path" || ! -f "$keychain_path" ]]; then
    /usr/bin/openssl rand -hex 24 > "$password_path"
    cat > "$signing_dir/certificate.conf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = Duck Island Local Development
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
    /usr/bin/openssl req -new -newkey rsa:2048 -x509 -days 3650 -nodes -config "$signing_dir/certificate.conf" -keyout "$signing_dir/private.pem" -out "$certificate_path" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$signing_dir/private.pem" -in "$certificate_path" -out "$signing_dir/identity.p12" -passout "file:$password_path"
    security create-keychain -p "$(cat "$password_path")" "$keychain_path"
    security unlock-keychain -p "$(cat "$password_path")" "$keychain_path"
    security import "$signing_dir/identity.p12" -k "$keychain_path" -P "$(cat "$password_path")" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$password_path")" "$keychain_path" >/dev/null
    security add-trusted-cert -r trustRoot -p codeSign -k "$keychain_path" "$certificate_path"
    rm "$signing_dir/private.pem" "$signing_dir/identity.p12"
fi
security unlock-keychain -p "$(cat "$password_path")" "$keychain_path"
certificate_sha=$(/usr/bin/openssl x509 -in "$certificate_path" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
python3 - "$keychain_path" "$certificate_sha" "$1" <<'PYTHON'
import subprocess, shlex, sys
keychain, fingerprint, app = sys.argv[1:]
original = shlex.split(subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))
try:
    subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *original, keychain], check=True)
    requirement = '=designated => identifier "local.rexlv.duckisland" and certificate leaf = H"' + fingerprint + '"'
    subprocess.run(['codesign', '--force', '--sign', fingerprint, '--keychain', keychain, '--requirements', requirement, app], check=True)
finally:
    subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *original], check=True)
PYTHON
codesign --verify --deep --strict "$1"
security lock-keychain "$keychain_path"
