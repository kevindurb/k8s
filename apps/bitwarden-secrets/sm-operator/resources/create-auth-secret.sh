#!/bin/bash

# Script to create the Bitwarden authentication SealedSecret
# Usage: ./create-auth-secret.sh <MACHINE_ACCOUNT_TOKEN>

set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <MACHINE_ACCOUNT_TOKEN>"
    echo ""
    echo "This script creates a SealedSecret for the Bitwarden machine account token."
    echo "You need to provide the machine account token from your Bitwarden Secrets Manager."
    echo ""
    echo "Steps to get a machine account token:"
    echo "1. Go to your Bitwarden Secrets Manager organization"
    echo "2. Navigate to 'Machine Accounts'"
    echo "3. Create a new machine account or use an existing one"
    echo "4. Create an access token for the machine account"
    echo "5. Copy the token and use it with this script"
    exit 1
fi

MACHINE_ACCOUNT_TOKEN="$1"

echo "Creating SealedSecret for Bitwarden authentication..."

# Create the secret and seal it
kubectl create secret generic bitwarden-auth-token \
    --namespace=bitwarden-secrets \
    --from-literal=token="$MACHINE_ACCOUNT_TOKEN" \
    --dry-run=client -o yaml | \
    kubeseal -o yaml > auth-secret-sealed.yml

echo ""
echo "✅ SealedSecret created successfully!"
echo ""
echo "Next steps:"
echo "1. Review the generated auth-secret-sealed.yml file"
echo "2. Replace the content of auth-secret.yml with the new sealed secret"
echo "3. Delete the generated file: rm auth-secret-sealed.yml"
echo "4. Commit and push the changes"
echo ""
echo "⚠️  Make sure to delete the temporary file containing the sealed secret!"