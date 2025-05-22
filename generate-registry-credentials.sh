#!/bin/bash
# filepath: /Users/robert/Code/citizen-infra/generate-registry-credentials.sh

# This script generates a Docker registry credentials file (registryCredentials.json)
# for authentication with Google Container Registry (eu.gcr.io) and GitHub Container Registry (ghcr.io)
#
# Special thanks to David Eriksson at Trollhättan stad for support with this script.
#
# Required files:
# - keyfile.json: Google Cloud service account key file
# - github-pat.txt: GitHub credentials file with the following format:
#   Line 1: GitHub username
#   Line 2: GitHub Personal Access Token (PAT)

# Path to keyfile and git PAT file
KEY_FILE_PATH="./keyfile.json"
PAT_FILE_PATH="./github-pat.txt"

# Check if files exist
if [ ! -f "$KEY_FILE_PATH" ]; then
    echo "Error: Key file not found at $KEY_FILE_PATH"
    exit 1
fi

if [ ! -f "$PAT_FILE_PATH" ]; then
    echo "Error: GitHub PAT file not found at $PAT_FILE_PATH"
    echo "Note: The PAT file should contain your GitHub username on the first line"
    echo "      and your GitHub Personal Access Token on the second line."
    exit 1
fi

# Read file contents
KEY_FILE_CONTENT=$(cat "$KEY_FILE_PATH")
GITHUB_USER=$(sed -n '1p' "$PAT_FILE_PATH")
GITHUB_TOKEN=$(sed -n '2p' "$PAT_FILE_PATH")

# Build auth strings
AUTH_STRING="_json_key:$KEY_FILE_CONTENT"
GHCR_AUTH_STRING="$GITHUB_USER:$GITHUB_TOKEN"

# Base64 encoding
ENCODED_AUTH=$(echo -n "$AUTH_STRING" | base64)
ENCODED_GHCR_AUTH=$(echo -n "$GHCR_AUTH_STRING" | base64)

# Create JSON structure
cat > registryCredentials.json << EOF
{
  "auths": {
    "eu.gcr.io": {
      "auth": "$ENCODED_AUTH"
    },
    "ghcr.io": {
      "auth": "$ENCODED_GHCR_AUTH"
    }
  }
}
EOF

echo "Registry credentials file created: registryCredentials.json"