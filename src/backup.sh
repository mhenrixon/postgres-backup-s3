#! /bin/sh

set -eu
set -o pipefail

source ./env.sh

jobs="${JOBS:-$(nproc)}"
zstd_level="${ZSTD_LEVEL:-3}"
dump_dir="$(mktemp -d)"
trap 'rm -rf "$dump_dir"' EXIT

echo "Creating parallel ($jobs jobs) backup of $POSTGRES_DATABASE database..."
pg_dump --format=directory \
        --jobs="$jobs" \
        --compress=0 \
        -h "$POSTGRES_HOST" \
        -p "$POSTGRES_PORT" \
        -U "$POSTGRES_USER" \
        -d "$POSTGRES_DATABASE" \
        -f "$dump_dir" \
        $PGDUMP_EXTRA_OPTS

timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.tar.zst"

if [ -n "$PASSPHRASE" ]; then
  s3_uri="${s3_uri_base}.gpg"
  echo "Streaming encrypted backup to $s3_uri..."
  tar -cf - -C "$dump_dir" . \
    | zstd -T0 "-${zstd_level}" \
    | gpg --symmetric --batch --passphrase "$PASSPHRASE" \
    | aws $aws_args s3 cp - "$s3_uri"
else
  s3_uri="$s3_uri_base"
  echo "Streaming backup to $s3_uri..."
  tar -cf - -C "$dump_dir" . \
    | zstd -T0 "-${zstd_level}" \
    | aws $aws_args s3 cp - "$s3_uri"
fi

echo "Backup complete."

if [ -n "$BACKUP_KEEP_DAYS" ]; then
  sec=$((86400*BACKUP_KEEP_DAYS))
  date_from_remove=$(date -d "@$(($(date +%s) - sec))" +%Y-%m-%d)
  backups_query="Contents[?LastModified<='${date_from_remove} 00:00:00'].{Key: Key}"

  echo "Removing old backups from $S3_BUCKET..."
  aws $aws_args s3api list-objects \
    --bucket "${S3_BUCKET}" \
    --prefix "${S3_PREFIX}" \
    --query "${backups_query}" \
    --output text \
    | xargs -n1 -t -I 'KEY' aws $aws_args s3 rm s3://"${S3_BUCKET}"/'KEY'
  echo "Removal complete."
fi
