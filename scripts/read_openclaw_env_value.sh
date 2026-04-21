#!/bin/sh
set -eu

KEY="${1:?Usage: $0 KEY [FILE]}"
FILE="${2:-root/usr/bin/openclaw-env}"

if [ ! -f "$FILE" ]; then
	echo "Error: file not found: $FILE" >&2
	exit 1
fi

VALUE=$(awk -F'"' -v key="$KEY" '$1 == key "=" { print $2; exit }' "$FILE")

if [ -z "$VALUE" ]; then
	echo "Error: $KEY not found in $FILE" >&2
	exit 1
fi

printf '%s\n' "$VALUE"
