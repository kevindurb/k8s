#!/usr/bin/env bash
set -e

/config/hooks/send_email.sh "Automatic Disk Ripper: Rip Started" "Drive: $1\nLabel: $2\nOutput: $3"
