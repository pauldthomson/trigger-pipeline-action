#!/bin/bash

set -euo pipefail

function is_delete_event() {
  if [[ "$GITHUB_EVENT_NAME" == "delete" ]]; then
    return 0
  else
    return 1
fi

function get_delete_event_json() {
    DELETE_EVENT_REF=$(jq --raw-output .ref "$GITHUB_EVENT_PATH")
    DELETE_EVENT_JSON=$(
      jq -n \
        --arg DELETE_EVENT_REF "$DELETE_EVENT_REF" \
        '{
          DELETE_EVENT_REF: $DELETE_EVENT_REF,
        }'
    )
fi

function get_build_env_vars_json() {
    local BUILD_ENV_VARS_JSON=""
    if [[ "$1" ]] && [[ "$2" ]]; then
        BUILD_ENV_VARS=$(
          jq -s '.[0] * .[1]' \
              <(echo "$DELETE_EVENT_JSON") \
              <(echo "$BUILD_ENV_VARS")
        )
    elif [[ "$1" ]]; then
        BUILD_ENV_VARS=$1
    elif [[ "$2" ]]; then
        BUILD_ENV_VARS=$2
    fi
    
    echo "$BUILD_ENV_VARS"
}

if [[ -z "${BUILDKITE_API_ACCESS_TOKEN:-}" ]]; then
  echo "You must set the BUILDKITE_API_ACCESS_TOKEN environment variable (e.g. BUILDKITE_API_ACCESS_TOKEN = \"xyz\")"
  exit 1
fi

if [[ -z "${PIPELINE:-}" ]]; then
  echo "You must set the PIPELINE environment variable (e.g. PIPELINE = \"my-org/my-pipeline\")"
  exit 1
fi

ORG_SLUG=$(echo "${PIPELINE}" | cut -d'/' -f1)
PIPELINE_SLUG=$(echo "${PIPELINE}" | cut -d'/' -f2)

COMMIT="${COMMIT:-${GITHUB_SHA}}"
BRANCH="${BRANCH:-${GITHUB_REF#"refs/heads/"}}"
MESSAGE="${MESSAGE:-}"

NAME=$(jq -r ".pusher.name" "$GITHUB_EVENT_PATH")
EMAIL=$(jq -r ".pusher.email" "$GITHUB_EVENT_PATH")

BUILD_ENV_VARS="${BUILD_ENV_VARS:-}"
    
DELETE_EVENT_JSON=""
if is_delete_event; then
    DELETE_EVENT_JSON=get_delete_event_json
fi

BUILD_ENV_VARS_JSON=$(get_build_env_vars_json $DELETE_EVENT_JSON $BUILD_ENV_VARS)

# Use jq’s --arg properly escapes string values for us
JSON=$(
  jq -c -n \
    --arg COMMIT  "$COMMIT" \
    --arg BRANCH  "$BRANCH" \
    --arg MESSAGE "$MESSAGE" \
    --arg NAME    "$NAME" \
    --arg EMAIL   "$EMAIL" \
    '{
      "commit": $COMMIT,
      "branch": $BRANCH,
      "message": $MESSAGE,
      "author": {
        "name": $NAME,
        "email": $EMAIL
      }
    }'
)

# Merge in the build environment variables, if they specified any
if [[ "${BUILD_ENV_VARS:-}" ]]; then
  if ! JSON=$(echo "$JSON" | jq -c --argjson BUILD_ENV_VARS "$BUILD_ENV_VARS" '. + {env: $BUILD_ENV_VARS}'); then
    echo ""
    echo "Error: BUILD_ENV_VARS provided invalid JSON: $BUILD_ENV_VARS"
    exit 1
  fi

# Add additional env vars as a nested object
FINAL_JSON=""
if [[ "$BUILD_ENV_VARS_JSON" ]]; then
    FINAL_JSON=$(
      echo "$JSON" | jq --argjson env "$BUILD_ENV_VARS_JSON" '. + {env: $env}'
    )
else
    FINAL_JSON=$JSON
fi

RESPONSE=$(
  curl \
    --fail \
    --silent \
    -X POST \
    -H "Authorization: Bearer ${BUILDKITE_API_ACCESS_TOKEN}" \
    "https://api.buildkite.com/v2/organizations/${ORG_SLUG}/pipelines/${PIPELINE_SLUG}/builds" \
    -d "$FINAL_JSON"
)

echo ""
echo "Build created:"
echo "$RESPONSE" | jq --raw-output ".web_url"

# Save output for downstream actions
echo "${RESPONSE}" > "${HOME}/${GITHUB_ACTION}.json"

echo ""
echo "Saved build JSON to:"
echo "${HOME}/${GITHUB_ACTION}.json"
