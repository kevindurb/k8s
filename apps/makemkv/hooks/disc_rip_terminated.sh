#!/usr/bin/env bash
set -e

/config/hooks/send_email.sh "Automatic Disc Ripper: Rip $4" \
"Drive: $1
Label: $2
Output: $3"
