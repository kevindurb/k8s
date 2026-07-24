#!/usr/bin/env bash
set -e

SMTP_SERVER="smtp-relay-app-service.smtp-relay:25"
FROM_EMAIL="beavercloud@fastmail.com"
TO_EMAIL="kevindurb@fastmail.com"

SUBJECT="${1:-SUBJECT_MISSING}"
BODY="${2:-BODY_MISSING}"

echo "Sending email to ${TO_EMAIL}..."

curl --silent --show-error \
     --url "smtp://${SMTP_SERVER}" \
     --mail-from "${FROM_EMAIL}" \
     --mail-rcpt "${TO_EMAIL}" \
     --upload-file - <<EOF
From: ${FROM_EMAIL}
To: ${TO_EMAIL}
Subject: ${SUBJECT}

${BODY}
EOF

echo "Email sent successfully!"
