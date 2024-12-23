#!/bin/bash

# SELF SERVICE LAPS REQUEST (SSLR?) -- API version
# This script masquerades as a Self Service item on macOS.
# When this item's "Request" button is clicked, the script leverages the Jamf Pro API to
# retrieve the current machine's LAPS password, and send it to a specified channel in
# Microsoft Teams for the ITS personnel to have ready prior to connecting remotely.

# !!!!!!! IMPORTANT !!!!!!!
# You MUST:
# a. Create an .env file (saved in the same directory as the script, or get the exact path to it)
# b. Ensure the ENV_FILE variable is defined correctly.

# Version 4.9a
# - Fixed the API authentication issue – was using /v1/auth instead of /v1/oauth. Derp.
# - Will need to correct the API endpoint in a future release.
# - Development on the basic-auth script continues and has the corrected endpoint.
# Version 4.8a
# - Split script into two: one that uses API credentials, and one that doesn't. For my sanity.
# Version 4.7a
# - You guessed it - more debugging.
# Version 4.6a
# - Removed extraneous shebang.
# Version 4.5a
# - Variable name fix.
# Version 4.4a
# - More debugging.
# Version 4.3a
# - Added more debugging.
# Version 4.2a
# - Fixed mistyped variables in get_jamf_token function.
# Version 4.1a
# - Prefixed CLIENT_ID and CLIENT_SECRET with "API_" (i.e., API_CLIENT_ID).
# Version 4.0a
# - Fashionably late: switched to OAuth2.
# Version 3.0a
# - FOR TESTING ONLY: Added an osascript line to produce a Push Notification to the user indicating that the password was copied to the clipboard.
# - MAY REMOVE IN FUTURE VERSION(S).
# Version 3.0
# - Code cleanup/condensing
# - Added automatic copying of the retrieved password to clipboard
# Version 2.0
# - No more plaintext credentials. Switched to using a private .env file.
# Version 1.0
# - Initial release.

# Variable declaration 2.0 – .env file, no more plain text!
ENV_FILE="self-service-laps-request.env"
if [[ -f "$ENV_FILE" ]]; then
  # Export variables from the .env file
  export $(grep -v '^#' "$ENV_FILE" | xargs)
else
  echo "Environment file $ENV_FILE not found. Please ensure it exists and contains the required variables."
  exit 1
fi

# .env variable validation
if [[ -z "$JAMF_PRO_URL" || -z "$API_CLIENT_ID" || -z "$API_CLIENT_SECRET" || -z "$TEAM_WEBHOOK_URL" || -z "$LAPS_ADMIN_ACCOUNT" ]]; then
  echo "One or more required environment variables are missing. Please ensure the following variables are set in $ENV_FILE or exported:"
  echo "  - JAMF_PRO_URL"
  echo "  - API_CLIENT_ID"
  echo "  - API_CLIENT_SECRET"
  echo "  - TEAM_WEBHOOK_URL"
  echo "  - LAPS_ADMIN_ACCOUNT"
  exit 1
fi

# Debugging: Print out the API client credentials to check if they're loaded
echo "API Client ID: $API_CLIENT_ID"
echo "API Client Secret: $API_CLIENT_SECRET"

# Function to get a Jamf Pro API token using OAuth2 (Client Credentials Grant)
get_jamf_token() {
  local response
  response=$(curl -s -X POST "$JAMF_PRO_URL/api/v1/oauth/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "client_id=$API_CLIENT_ID" \
    -d "client_secret=$API_CLIENT_SECRET" \
    -d 'grant_type=client_credentials')
  
  # DEBUGGING: Print raw response
  echo "Response from Jamf Pro API (Token Request): $response"
  
  # Extract the access token using jq
  token=$(echo "$response" | jq -r '.access_token')
  
  # DEBUGGING: Print the token if available
  if [[ -n "$token" ]]; then
    echo "Access token retrieved: $token"
  else
    echo "Failed to retrieve access token"
  fi
  
  echo "$token"
}

# Get the serial number of the current Mac
SERIAL_NUMBER=$(system_profiler SPHardwareDataType | awk '/Serial Number/{print $4}')

if [[ -z "$SERIAL_NUMBER" ]]; then
  echo "Failed to retrieve the serial number of the current Mac."
  exit 1
fi

# Get API token
TOKEN=$(get_jamf_token)
if [[ -z "$TOKEN" ]]; then
  echo "Failed to retrieve Jamf Pro API token."
  exit 1
fi

# DEBUGGING: Print token for verification
echo "Using API Token: $TOKEN"

# Retrieve the computer ID (Management ID) using the serial number
COMPUTER_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "$JAMF_PRO_URL/api/v1/computers-inventory?filter=serialNumber%20eq%20'$SERIAL_NUMBER'" | \
  jq -r '.data[0].id')  # Use jq to parse JSON response
  
# DEBUGGING: Print raw response for computer ID query
echo "Response from Jamf Pro for computer ID query: $COMPUTER_ID"

if [[ -z "$COMPUTER_ID" ]]; then
  echo "Failed to retrieve the Management ID for serial number $SERIAL_NUMBER."
  exit 1
fi

# Retrieve the LAPS password for the specified computer and admin account
PASSWORD=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "$JAMF_PRO_URL/api/v1/local-admin-password/$COMPUTER_ID" | \
  jq -r '.password')  # Use jq to extract the password

# DEBUGGING: Print raw response for password query
echo "Response from Jamf Pro for LAPS password query: $PASSWORD"

if [[ -z "$PASSWORD" ]]; then
  echo "Failed to retrieve the LAPS password for computer ID $COMPUTER_ID."
  exit 1
fi

# Automatically copy the LAPS password to the clipboard
echo -n "$PASSWORD" | pbcopy
echo "The LAPS password has been copied to the clipboard."

# Send a push notification to the user indicating the password was copied | TESTING ONLY
osascript -e 'display notification "The LAPS password has been copied to the clipboard." with title "Jamf Self Service"'

# Construct the Microsoft Teams webhook payload
TEAMS_PAYLOAD=$(cat <<EOF
{
  "text": "LAPS Password for account '$LAPS_ADMIN_ACCOUNT' on computer with serial '$SERIAL_NUMBER': $PASSWORD"
}
EOF
)

# Post the password to Microsoft Teams
curl -H "Content-Type: application/json" -d "$TEAMS_PAYLOAD" "$TEAM_WEBHOOK_URL"

# Cleanup: Invalidate the Jamf Pro token
curl -s -X POST -H "Authorization: Bearer $TOKEN" "$JAMF_PRO_URL/api/v1/auth/invalidate-token" > /dev/null

echo "LAPS password posted to Microsoft Teams successfully."
exit 0