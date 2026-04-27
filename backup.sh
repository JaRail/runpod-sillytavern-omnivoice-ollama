#!/bin/bash
# Snapshot SillyTavern state to a RunPod S3-compatible network volume.
#
# Usage:
#   /app/backup.sh
#
# Reads the same BACKUP_S3_* env vars as restore.sh (see that file for the
# full list). Tars /workspace/st_data, /workspace/secrets.json, and
# /workspace/config.yaml and uploads them as a single gzipped archive.
#
# Rotation: before uploading, the existing 'latest.tar.gz' is server-side
# copied to 'previous.tar.gz'. So you always have at most two snapshots —
# the most recent successful backup and the one before it. That's enough to
# recover from "I just backed up a corrupted state and want to undo".
#
# Plugins (/workspace/st_plugins) are intentionally excluded — they're
# reinstalled via the SillyTavern UI on a fresh pod, and including them
# would bloat the archive without improving recoverability.

set -eo pipefail

# Validate required env vars upfront — otherwise rclone fails halfway through
# the tar pipe with a confusing auth error.
missing=()
for var in BACKUP_S3_ENDPOINT BACKUP_S3_REGION BACKUP_S3_BUCKET \
           BACKUP_S3_ACCESS_KEY BACKUP_S3_SECRET_KEY; do
    if [ -z "${!var}" ]; then
        missing+=("$var")
    fi
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: backup.sh missing required env vars: ${missing[*]}" >&2
    exit 1
fi

PREFIX="${BACKUP_PREFIX:-sillytavern-backup}"
LATEST_KEY="${PREFIX}/latest.tar.gz"
PREVIOUS_KEY="${PREFIX}/previous.tar.gz"

# Wire rclone via env vars — see restore.sh for why we use Provider=Other.
export RCLONE_CONFIG_RP_TYPE=s3
export RCLONE_CONFIG_RP_PROVIDER=Other
export RCLONE_CONFIG_RP_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY"
export RCLONE_CONFIG_RP_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_KEY"
export RCLONE_CONFIG_RP_ENDPOINT="$BACKUP_S3_ENDPOINT"
export RCLONE_CONFIG_RP_REGION="$BACKUP_S3_REGION"

LATEST_REMOTE="rp:${BACKUP_S3_BUCKET}/${LATEST_KEY}"
PREVIOUS_REMOTE="rp:${BACKUP_S3_BUCKET}/${PREVIOUS_KEY}"

# Sanity-check that there's something to back up before we go opening
# network connections. Missing st_data on a populated pod would mean the
# entrypoint's symlink step never ran — better to surface that than upload
# an empty archive.
if [ ! -d /workspace/st_data ]; then
    echo "ERROR: /workspace/st_data does not exist — nothing to back up." >&2
    echo "  (Has the entrypoint run? Are you running this from inside the pod?)" >&2
    exit 1
fi

# Rotate latest -> previous. Server-side copy avoids transferring the bytes
# back through us. If 'latest' doesn't exist yet (first-ever backup) the lsf
# probe returns nonzero and we skip rotation cleanly — `rclone copyto` on a
# missing source would otherwise log a noisy error.
if rclone lsf --quiet "$LATEST_REMOTE" >/dev/null 2>&1; then
    echo "Rotating previous snapshot..."
    rclone copyto "$LATEST_REMOTE" "$PREVIOUS_REMOTE"
else
    echo "No existing snapshot to rotate (first backup?)."
fi

# Build the archive in a temp file rather than streaming to rclone rcat. We
# have plenty of /workspace disk, and a temp file lets us know the exact
# size before upload (useful in logs) and lets rclone retry the upload on
# transient network failures without re-tarring. Streaming would force a
# single shot.
#
# The list of files to include is defensively gated — a fresh pod might not
# have config.yaml or secrets.json yet (entrypoint creates them lazily via
# symlink-on-first-write). tar would error on a missing file, so we build
# the include list dynamically.
TMPFILE=$(mktemp /workspace/st_backup.XXXXXX.tar.gz)
trap 'rm -f "$TMPFILE"' EXIT

INCLUDES=(st_data)
for f in secrets.json config.yaml; do
    if [ -f "/workspace/$f" ]; then
        INCLUDES+=("$f")
    fi
done

echo "Archiving: ${INCLUDES[*]}"
# --warning=no-file-changed: ST may rewrite settings.json during the tar
# pass if a UI action lands at exactly the wrong moment. tar exits 1 (not 2)
# on this — we don't want a benign concurrent-write to fail the backup.
tar --warning=no-file-changed -czf "$TMPFILE" -C /workspace "${INCLUDES[@]}"

SIZE=$(du -h "$TMPFILE" | cut -f1)
echo "Uploading ${SIZE} archive to ${LATEST_REMOTE}..."
rclone copyto "$TMPFILE" "$LATEST_REMOTE"

echo "Backup complete (${SIZE} -> ${LATEST_KEY})."
