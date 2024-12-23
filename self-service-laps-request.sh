#!/bin/bash

# SELF SERVICE LAPS REQUEST (SSLR?)
# This script masquerades as a Self Service item on macOS.
# When this item's "Request" button is clicked, the script leverages the Jamf Pro API to
# retrieve the current machine's LAPS password, and send it to a specified channel in
# Microsoft Teams for the ITS personnel to have ready prior to connecting remotely.

# !!!!!!! IMPORTANT !!!!!!!
# You MUST:
# a. Create an .env file (saved in the same directory as the script, or get the exact path to it)
# b. Ensure the ENV_FILE variable is defined correctly.

# Version 2.0
# - No more plaintext credentials. Switched to using a private .env file.
# Version 1.0
# - Initial release.

#!/bin/bash

# Variable declaration 2.0 – .env file, no more plain text!
ENV_FILE="self-service-laps-request.env"
if [[ -f "$ENV_FILE" ]]; then
  # Export variables from the .env file
  export $(grep -v '^#' "$ENV_FILE" | xargs)
else
  echo "Environment file $ENV_FILE not found. Please ensure it exists and contains the required variables."
  exit 1
fi

# Variable validation
if [[ -z "$JAMF_PRO_URL" || -z "$JAMF_API_USER" || -z "$JAMF_API_PASS" || -z "$TEAM_WEBHOOK_URL" ]]; then
  echo "One or more required environment variables are missing in $ENV_FILE."
  exit 1
fi

# Check if LAPS_ADMIN_ACCOUNT is set as an environment variable
if [[ -z "$LAPS_ADMIN_ACCOUNT" ]]; then
  echo "The LAPS_ADMIN_ACCOUNT environment variable is not set. Please define it in $ENV_FILE or export it before running the script."
  exit 1
fi

# Function to get a Jamf Pro API token
get_jamf_token() {
  local response
  response=$(curl -s -u "$JAMF_API_USER:$JAMF_API_PASS" -X POST "$JAMF_PRO_URL/api/v1/auth/token")
  echo "$response" | grep -o '"token":"[^"]*' | cut -d'"' -f4
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

# Retrieve the computer ID (Management ID) using the serial number
COMPUTER_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "$JAMF_PRO_URL/api/v1/computers-inventory?filter=serialNumber%20eq%20'$SERIAL_NUMBER'" | \
  grep -o '"id":[0-9]*' | cut -d':' -f2)

if [[ -z "$COMPUTER_ID" ]]; then
  echo "Failed to retrieve the Management ID for serial number $SERIAL_NUMBER."
  exit 1
fi

# Retrieve the LAPS password for the specified computer and admin account
PASSWORD=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "$JAMF_PRO_URL/api/v1/local-admin-password/$COMPUTER_ID" | \
  grep -o '"password":"[^"]*' | cut -d'"' -f4)

if [[ -z "$PASSWORD" ]]; then
  echo "Failed to retrieve the LAPS password for computer ID $COMPUTER_ID."
  exit 1
fi

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
