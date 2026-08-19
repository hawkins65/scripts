#!/bin/bash

# Check if a vote account pubkey is provided
if [ -z "$1" ]; then
    echo "Error: Please provide a vote account pubkey or identity pubkey as an argument."
    echo "Usage: $0 <pubkey>"
    exit 1
fi

# Store and output the provided pubkey
PUBKEY="$1"
echo "Processing vote account pubkey: $PUBKEY"

# Define the API URL
API_URL="https://api.trillium.so/validator_rewards/$PUBKEY"

# Fetch JSON data using curl
RESPONSE=$(curl -s "$API_URL")

# Check if curl command was successful
if [ $? -ne 0 ]; then
    echo "Error: Failed to fetch data from $API_URL"
    exit 1
fi

# Check if response is empty
if [ -z "$RESPONSE" ]; then
    echo "Error: Empty response from $API_URL"
    exit 1
fi

# Parse JSON: Check for error response, otherwise extract required fields
RESULT=$(echo "$RESPONSE" | jq -r '
    # Check if response is an object with an "error" field
    if type == "object" and has("error") then
        "error: \(.error)"
    else
        # If input is an array, take the first element; if it is an object, use it directly
        (if type == "array" then .[0] else . end) | 
        {
            vote_account_pubkey: .vote_account_pubkey,
            identity_pubkey: .identity_pubkey,
            name: .name,
            website: .website
        } | to_entries | .[] | "\(.key): \(.value)"
    end
')

# Check if jq parsing was successful
if [ $? -ne 0 ]; then
    echo "Error: Failed to parse JSON response for pubkey $PUBKEY. The response may not be valid JSON."
    exit 1
fi

# Check if RESULT is empty (e.g., if the response is invalid)
if [ -z "$RESULT" ]; then
    echo "Error: No valid data or error message found for pubkey $PUBKEY"
    exit 1
fi

# Output the result
echo "$RESULT"
