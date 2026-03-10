#!/bin/bash
API_KEY=$1
ORG_ID=$2
EMAIL=$3

USER_ID=$(curl -s -H "Authorization: ApiKey ${API_KEY}" -XGET "https://api.elastic-cloud.com/api/v1/organizations/${ORG_ID}/members" | jq --arg email "${EMAIL}" -r '.members[] | select(.email == $email).user_id')
TOKEN_ID=$(curl -s -H "Authorization: ApiKey ${API_KEY}" -XGET "https://api.elastic-cloud.com/api/v1/organizations/${ORG_ID}/invitations" | jq --arg email "${EMAIL}" -r '.invitations[] | select(.email == $email).token')

if [ -n "$USER_ID" ]; then
    curl -s -H "Authorization: ApiKey ${API_KEY}" -XDELETE "https://api.elastic-cloud.com/api/v1/organizations/${ORG_ID}/members/${USER_ID}"
fi

if [ -n "$TOKEN_ID" ]; then
    curl -s -H "Authorization: ApiKey ${API_KEY}" -XDELETE "https://api.elastic-cloud.com/api/v1/organizations/${ORG_ID}/invitations/${TOKEN_ID}"
fi