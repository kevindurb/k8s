#! /bin/sh
DRV_ID="$1"
DISC_LABEL="$2"
OUTPUT_DIR="$3"
STATUS="$4"

case "$STATUS" in
    0)
        curl -d "The automatic disc ripper successfully ripped disc '$DISC_LABEL' (drive $DRV_ID)." http://ntfy-web-service.monitoring/makemkv
        ;;
    *)
        curl -d "The automatic disc ripper failed to rip disc '$DISC_LABEL' (drive $DRV_ID)." http://ntfy-web-service.monitoring/makemkv
        ;;
esac
