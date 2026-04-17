#! /bin/sh

set -u # `-e` omitted intentionally, but i can't remember why exactly :'(
set -o pipefail

source ./env.sh

# SOURCE_DATABASE allows restoring from a backup with a different database name
# Useful for migrations, e.g., restore "cosmos" backup to "coding" database
SOURCE_DATABASE="${SOURCE_DATABASE:-$POSTGRES_DATABASE}"
jobs="${JOBS:-$(nproc)}"

s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}"

if [ -n "$PASSPHRASE" ]; then
  new_suffix=".tar.zst.gpg"
  legacy_suffix=".dump.gpg"
else
  new_suffix=".tar.zst"
  legacy_suffix=".dump"
fi

if [ $# -eq 1 ]; then
  timestamp="$1"
  # Try new format first, fall back to legacy
  key_suffix="${SOURCE_DATABASE}_${timestamp}${new_suffix}"
  if ! aws $aws_args s3 ls "${s3_uri_base}/${key_suffix}" > /dev/null 2>&1; then
    key_suffix="${SOURCE_DATABASE}_${timestamp}${legacy_suffix}"
  fi
else
  echo "Finding latest backup for ${SOURCE_DATABASE}..."
  key_suffix=$(
    aws $aws_args s3 ls "${s3_uri_base}/${SOURCE_DATABASE}" \
      | sort \
      | tail -n 1 \
      | awk '{ print $4 }'
  )
fi

conn_opts="-h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -d $POSTGRES_DATABASE"

case "$key_suffix" in
  *.tar.zst.gpg|*.tar.zst)
    # New streaming format: tar + zstd [+ gpg]
    restore_dir="$(mktemp -d)"
    trap 'rm -rf "$restore_dir"' EXIT

    echo "Streaming and extracting ${key_suffix}..."
    if [ "${key_suffix##*.}" = "gpg" ]; then
      aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" - \
        | gpg --decrypt --batch --passphrase "$PASSPHRASE" \
        | zstd -d \
        | tar -xf - -C "$restore_dir"
    else
      aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" - \
        | zstd -d \
        | tar -xf - -C "$restore_dir"
    fi

    echo "Restoring ${SOURCE_DATABASE} backup to ${POSTGRES_DATABASE} ($jobs jobs)..."
    pg_restore $conn_opts --clean --if-exists --jobs="$jobs" "$restore_dir"
    ;;

  *.dump.gpg|*.dump)
    # Legacy single-file custom-format backup
    file_type="${legacy_suffix}"
    echo "Fetching legacy backup from S3..."
    aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" "db${file_type}"

    if [ -n "$PASSPHRASE" ]; then
      echo "Decrypting backup..."
      gpg --decrypt --batch --passphrase "$PASSPHRASE" db.dump.gpg > db.dump
      rm db.dump.gpg
    fi

    echo "Restoring ${SOURCE_DATABASE} backup to ${POSTGRES_DATABASE} ($jobs jobs)..."
    pg_restore $conn_opts --clean --if-exists --jobs="$jobs" db.dump
    rm db.dump
    ;;

  *)
    echo "Unrecognized backup format: $key_suffix"
    exit 1
    ;;
esac

echo "Restore complete."
