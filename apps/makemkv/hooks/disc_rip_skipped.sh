#!/usr/bin/env bash
set -e

/config/hooks/send_email.sh "Automatic Disc Ripper: Rip Skipped" "Drive: $1\nLabel: $2\nReason: $3"
