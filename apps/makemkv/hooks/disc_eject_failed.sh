#!/usr/bin/env bash
set -e

/config/hooks/send_email.sh "Automatic Disc Ripper: Disc Eject Failed" "$1: $2"
