#!/usr/bin/env bash
set -e

/config/hooks/send_email.sh "Automatic Disc Ripper: Rip $4" "Drive: $1\nLabel: $2\nOutput: $3"
