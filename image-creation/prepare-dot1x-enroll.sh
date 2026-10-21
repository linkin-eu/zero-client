#!/usr/bin/env bash
# Collects what 802.1X enrollment needs for one plant into a directory: the SCEP settings from SSM, validated,
# and the pinned scepclient binary. Runs before the build so a missing value fails fast.
set -euo pipefail

PLANT="${1:?usage: prepare-dot1x-enroll.sh <plant> <output-dir>}"
OUTPUT_DIR="${2:?usage: prepare-dot1x-enroll.sh <plant> <output-dir>}"
# Shared with the Yocto RPi devices: same PacketFence, CA and RADIUS
SSM_PARAMETER="/yocto/$PLANT/scep"
AWS_REGION="eu-central-1"
# Thin clients get their own PacketFence PKI template, so they are told apart from the RPi devices
SCEP_TEMPLATE="zero-v4"
REQUIRED_KEYS=(SCEP_HOST SCEP_CHALLENGE CA_FINGERPRINT RADIUS_DOMAIN OCSP_HOST)
SCEPCLIENT_URL="https://github.com/micromdm/scep/releases/download/v2.3.0/scepclient-linux-amd64-v2.3.0.zip"
SCEPCLIENT_SHA256="47b20e1b44b5789d4dd8572b17b22fe7d7d5fa6c1fe1b61f24fe26a3a1826a30"

umask 077

if [[ ! "$PLANT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: plant must be digits, got '$PLANT'" >&2
  exit 1
fi

# The build runs under sudo, but the AWS credentials belong to the user who started it
scep_settings="$(sudo -H -u "${SUDO_USER:-root}" aws ssm get-parameter --region "$AWS_REGION" --with-decryption \
  --name "$SSM_PARAMETER" --query Parameter.Value --output text)"

# The device sources this file as root, so only the required keys with plain values are written
{
  echo "PLANT=\"$PLANT\""
  echo "SCEP_TEMPLATE=\"$SCEP_TEMPLATE\""
  missing_keys=()
  for key in "${REQUIRED_KEYS[@]}"; do
    line="$(grep -E '^'"$key"'="[^"$`\\]+"$' <<<"$scep_settings" | head -n1 || true)"
    if [ -z "$line" ]; then
      missing_keys+=("$key")
    fi
    echo "$line"
  done
  if [ ${#missing_keys[@]} -gt 0 ]; then
    echo "ERROR: $SSM_PARAMETER is missing ${missing_keys[*]} (every line must be KEY=\"value\" without \" \$ \` or \\)" >&2
    exit 1
  fi
} >"$OUTPUT_DIR/dot1x-enroll.conf"

wget -q -O "$OUTPUT_DIR/scepclient.zip" "$SCEPCLIENT_URL"
echo "$SCEPCLIENT_SHA256  $OUTPUT_DIR/scepclient.zip" | sha256sum -c --quiet
unzip -q -p "$OUTPUT_DIR/scepclient.zip" scepclient-linux-amd64 >"$OUTPUT_DIR/scepclient"
rm -f "$OUTPUT_DIR/scepclient.zip"

echo "==> 802.1X enrollment prepared for plant $PLANT from $SSM_PARAMETER"
