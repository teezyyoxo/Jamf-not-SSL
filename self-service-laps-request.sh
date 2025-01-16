#!/bin/bash

# SELF SERVICE LAPS REQUEST (SSLR?) - BASIC
# This script masquerades as a Self Service item on macOS.
# When this item's "Request" button is clicked, the script leverages the Jamf Pro API to
# retrieve the current machine's LAPS password, and send it to a specified channel in
# Microsoft Teams for the ITS personnel to have ready prior to connecting remotely.

# !!!!!!! IMPORTANT !!!!!!!
# You MUST:
# a. Create an .env file (saved in the same directory as the script, or get the exact path to it)
# b. Ensure the ENV_FILE variable is defined correctly.


# Version 4.9.7a
# - Fixed: Added missing `get_jamf_token` function to properly retrieve the Jamf Pro API token.
# - Improved: Implemented debug logging for the API token retrieval process to aid in troubleshooting.
# - Error Handling: Enhanced error checking to ensure the script exits if the API token cannot be retrieved.
# Version 4.9.6a
# - Added missing function declaration for get_jamf_token. Derp.
# Version 4.9.5a
# - Now uses the correct API endpoint (/v2/local-admin-password/{client-management-id}/account/{username}/password)
# Version 4.9.4a
# - Fixed get_jamf_token function again to ensure the token value is non-empty.
# - Changed ".access_token" to "".token".
# Version 4.9.3a
# - Fixed COMPUTER_ID variable logic (sed is actually insane).
# Version 4.9.2a
# - Script now requires root because it includes "jamf recon" and checks for this immediately upon execution.
# Version 4.9.1a
# - Added RECON_OUTPUT variable to capture the (truncated) Jamf Pro Computer ID from "sudo jamf recon".
# Version 4.9a
# - Switched from using serial number to grabbing the Jamf Pro Computer ID from "jamf recon" and using that with the API.
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

# Check if the script is being run as root. If not, exit and ask to run with sudo.
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use 'sudo' to run this script."
  exit 1
fi

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
if [[ -z "$JAMF_PRO_URL" || -z "$JAMF_PRO_USERNAME" || -z "$JAMF_PRO_PASSWORD" || -z "$TEAM_WEBHOOK_URL" || -z "$LAPS_ADMIN_ACCOUNT" ]]; then
  echo "One or more required environment variables are missing. Please ensure the following variables are set in $ENV_FILE or exported:"
  echo "  - JAMF_PRO_URL"
  echo "  - JAMF_PRO_USERNAME"
  echo "  - JAMF_PRO_PASSWORD"
  echo "  - TEAM_WEBHOOK_URL"
  echo "  - LAPS_ADMIN_ACCOUNT"
  exit 1
fi

# Debugging: Print out the Jamf Pro credentials to check if they're loaded
echo "Jamf Pro Username: $JAMF_PRO_USERNAME"

# Function to get a Jamf Pro API token using Basic Authentication
# Now uses the CORRECT API endpoint/call lol (/v2/local-admin-password/{client-management-id}/account/{LAPSaccountName}/password)
get_laps_password() {
  local response
  local api_endpoint="$JAMF_PRO_URL/api/v2/local-admin-password/$CLIENT_MANAGEMENT_ID/account/$USERNAME/password"
  
  echo "Querying Jamf Pro API for LAPS password..."

  # Perform the API request
  response=$(curl -s -X 'GET' \
    "$api_endpoint" \
    -H 'accept: application/json' \
    -H "Authorization: Bearer $TOKEN")

  # DEBUG: Print the raw response for troubleshooting
  echo "Response from Jamf Pro for LAPS password query: $response"

  # Extract the password from the response
  laps_password=$(echo "$response" | jq -r '.password')

  # Check if the password was successfully retrieved
  if [[ -n "$laps_password" && "$laps_password" != "null" ]]; then
    echo "LAPS password retrieved: $laps_password"
  else
    echo "Failed to retrieve the LAPS password for client management ID $CLIENT_MANAGEMENT_ID and account $USERNAME."
    laps_password=""
  fi

  echo "$laps_password"
}

# Request password for sudo (will trigger sudo password prompt)
echo "Please enter your password to proceed with the Jamf recon process."
sudo echo "Sudo password accepted."

# Print message to wait for Jamf sync
echo "Please wait for Jamf to sync. This should take about 15 seconds."

# Run the jamf recon command and capture the output
RECON_OUTPUT=$(sudo jamf recon)

# Debugging: Print the full recon output
echo "Full recon output:"
echo "$RECON_OUTPUT"

# Extract the computer ID from the output using sed
COMPUTER_ID=$(echo "$RECON_OUTPUT" | sed -n -E 's/.*<computer_id>([0-9]+)<\/computer_id>.*/\1/p')

# Check if the computer ID was retrieved
if [[ -z "$COMPUTER_ID" ]]; then
  echo "Failed to retrieve the Jamf Pro Computer ID for this machine."
  exit 1
fi

# Function to get a Jamf Pro API token using Basic Authentication
get_jamf_token() {
  local response
  local api_endpoint="$JAMF_PRO_URL/api/v1/auth/token"

  echo "Requesting Jamf Pro API token..."

  # Perform the API request to get the token
  response=$(curl -s -X POST "$api_endpoint" \
    -u "$JAMF_PRO_USERNAME:$JAMF_PRO_PASSWORD" \
    -H "accept: application/json")

  # DEBUG: Print the raw response for troubleshooting
  echo "Response from Jamf Pro API token request: $response"

  # Extract the token from the response
  token=$(echo "$response" | jq -r '.token')

  # Check if the token was successfully retrieved
  if [[ -n "$token" && "$token" != "null" ]]; then
    echo "$token"
  else
    echo "Failed to retrieve Jamf Pro API token."
    exit 1
  fi
}

# DEBUGGING: Print token for verification
echo "Using API Token: $TOKEN"

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
  "text": "LAPS Password for account '$LAPS_ADMIN_ACCOUNT' on computer with ID '$COMPUTER_ID': $PASSWORD"
}
EOF
)

# Post the password to Microsoft Teams
curl -H "Content-Type: application/json" -d "$TEAMS_PAYLOAD" "$TEAM_WEBHOOK_URL"

# Cleanup: Invalidate the Jamf Pro token
curl -s -X POST -H "Authorization: Bearer $TOKEN" "$JAMF_PRO_URL/api/v1/auth/invalidate-token" > /dev/null

echo "LAPS password posted to Microsoft Teams successfully."
exit 0