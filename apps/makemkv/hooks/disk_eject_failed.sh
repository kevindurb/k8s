#!/usr/bin/env bash
set -e

/config/hooks/send_email.sh "Automatic Disk Ripper: Disk Eject Failed" "$1: $2"
