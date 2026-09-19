#!/usr/bin/env bash
# One-time Google authorization for the artemisa81.gtasks Omarchy shell plugin.
#
# Creates a dedicated gws CLI profile with the Google Tasks read/write scope,
# reusing an OAuth client secret from an existing gws profile when one exists.
set -euo pipefail

# The profile holds OAuth tokens and a client secret; keep them owner-only even
# under a permissive umask.
umask 077

PROFILE="${HOME}/.config/gws-omarchy-tasks"
SCOPE="https://www.googleapis.com/auth/tasks"
TASKS_API_URL="https://console.cloud.google.com/apis/library/tasks.googleapis.com"

if ! command -v gws >/dev/null 2>&1; then
  echo "error: the gws CLI was not found on PATH."
  echo "       Install it first (the Omarchy calendar plugin uses the same tool)."
  exit 1
fi

mkdir -p "$PROFILE"

if [[ ! -s "$PROFILE/client_secret.json" ]]; then
  for candidate in \
    "${HOME}/.config/gws-omarchy-calendar-rw/client_secret.json" \
    "${HOME}/.config/gws-omarchy-calendar/client_secret.json" \
    "${HOME}/.config/gws/client_secret.json"; do
    if [[ -s "$candidate" ]]; then
      echo "Reusing OAuth client secret from ${candidate}"
      cp "$candidate" "$PROFILE/client_secret.json"
      break
    fi
  done
fi

if [[ ! -s "$PROFILE/client_secret.json" ]]; then
  cat <<EOF
No OAuth client secret found for a fresh gws profile.

Either copy one from another machine/profile into:
  ${PROFILE}/client_secret.json

...or run \`gws auth setup\` to create a GCP project + OAuth client (needs gcloud).
EOF
  read -r -p "Press Enter once client_secret.json is in place (Ctrl+C to abort)... " _
  [[ -s "$PROFILE/client_secret.json" ]] || { echo "Still missing client_secret.json, aborting."; exit 1; }
fi

export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$PROFILE"

echo ""
echo "Opening your browser to authorize Google Tasks access..."
gws auth login --scopes "$SCOPE"

echo ""
if gws tasks tasklists list >/dev/null 2>&1; then
  echo "Google Tasks authorization OK. Profile: ${PROFILE}"
  echo "You can close this window and use the Tasks panel."
else
  rc=$?
  echo ""
  echo "Signed in, but the Tasks API check failed (exit ${rc})."
  if gws tasks tasklists list 2>&1 | grep -qi "403\|accessNotConfigured\|not been used"; then
    echo ""
    echo "The Google Tasks API is probably not enabled on this GCP project yet."
    echo "Enable it here, then reopen the panel:"
    echo "  ${TASKS_API_URL}"
  else
    echo "Run 'gws auth status' with GOOGLE_WORKSPACE_CLI_CONFIG_DIR=${PROFILE} for details."
  fi
  exit 1
fi
