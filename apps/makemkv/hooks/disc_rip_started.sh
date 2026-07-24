#!/usr/bin/env bash
set -e

/config/hooks/send_email.sh "Automatic Disc Ripper: Rip Started" \
"Drive: $1
Label: $2
Output: $3"
