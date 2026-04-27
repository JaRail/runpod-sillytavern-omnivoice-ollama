#!/bin/bash
# Restore SillyTavern state from a RunPod S3-compatible network volume.
#
# Usage:
#   /app/restore.sh           # restores from "latest" snapshot
#   /app/restore.sh previous  # restores from the rotated "previous" snapshot
#
# Reads these env vars (all required except BACKUP_PREFIX):
#   BACKUP_S3_ENDPOINT    e.g. https://s3api-us-ks-2.runpod.io
#   BACKUP_S3_REGION      e.g. us-ks-2
#   BACKUP_S3_BUCKET      the network-volume ID acting as the bucket
#   BACKUP_S3_ACCESS_KEY  RunPod user API key
#   BACKUP_S3_SECRET_KEY  RunPod-generated S3 secret
#   BACKUP_PREFIX         optional, defaults to "sillytavern-backup"
#
# The restore extracts directly into /workspace, overwriting any conflicting
# files. Auto-restore from entrypoint.sh only runs when /workspace/st_data is
# empty, so it never clobbers a populated workspace; manual invocations DO
# overwrite, by design — that's how you'd revert to a known-good snapshot.

set -eo pipefail

SLOT="${1:-latest}"
if [ "$SLOT" != "latest" ] && [ "$SLOT" != "previous" ]; then
    echo "ERROR: snapshot slot must be 'latest' or 'previous' (got: $SLOT)" >&2
    exit 1
fi

# Validate required env vars upfront so we fail with a clear message rather
# than a confusing rclone auth error mid-stream.
missing=()
for var in BACKUP_S3_ENDPOINT BACKUP_S3_REGION BACKUP_S3_BUCKET \
           BACKUP_S3_ACCESS_KEY BACKUP_S3_SECRET_KEY; do
    if [ -z "${!var}" ]; then
        missing+=("$var")
    fi
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: restore.sh missing required env vars: ${missing[*]}" >&2
    exit 1
fi

PREFIX="${BACKUP_PREFIX:-sillytavern-backup}"
KEY="${PREFIX}/${SLOT}.tar.gz"

# Wire rclone's S3 backend via env vars rather than a config file. Naming the
# remote "rp" is arbitrary — RCLONE_CONFIG_RP_* groups its settings together.
# Provider=Other tells rclone "S3-compatible, not real AWS"; this disables a
# couple of S3-specific quirks (e.g. region-mapping heuristics) that would
# otherwise mis-handle the RunPod endpoint.
export RCLONE_CONFIG_RP_TYPE=s3
export RCLONE_CONFIG_RP_PROVIDER=Other
export RCLONE_CONFIG_RP_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY"
export RCLONE_CONFIG_RP_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_KEY"
export RCLONE_CONFIG_RP_ENDPOINT="$BACKUP_S3_ENDPOINT"
export RCLONE_CONFIG_RP_REGION="$BACKUP_S3_REGION"

REMOTE_PATH="rp:${BACKUP_S3_BUCKET}/${KEY}"

echo "Restoring from ${REMOTE_PATH}..."

# Verify the object exists before streaming so the user gets a clean "no
# backup found" message instead of tar choking on an empty stdin.
if ! rclone lsf --quiet "$REMOTE_PATH" >/dev/null 2>&1; then
    echo "ERROR: backup object not found at $REMOTE_PATH" >&2
    echo "  (Have you run /app/backup.sh at least once on a previous pod?)" >&2
    exit 2
fi

mkdir -p /workspace

# Stream the tarball straight into tar — avoids needing local disk for the
# full archive. The 'cat' acts as our download since rclone's 'cat' subcommand
# writes to stdout. Trapping pipefail (set at top) means a network failure
# in rclone surfaces as a nonzero exit even though tar succeeded on its
# partial input.
rclone cat "$REMOTE_PATH" | tar -xzf - -C /workspace

echo "Restore complete from ${SLOT} snapshot."
