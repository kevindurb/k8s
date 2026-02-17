#! /bin/sh
DRV_ID="$1"
DISC_LABEL="$2"
OUTPUT_DIR="$3"

curl -d "The automatic disc ripper started ripping disc '$DISC_LABEL' (drive $DRV_ID) to '$OUTPUT_DIR'." http://ntfy-web-service.monitoring/makemkv
