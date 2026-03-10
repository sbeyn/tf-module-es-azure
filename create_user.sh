#!/bin/bash
API_KEY=$1
ORG_ID=$2
EMAIL=$3

if ! command -v jq &> /dev/null; then
    echo "jq non trouvé. Installation en cours..."
    
    if command -v apt-get &> /dev/null; then
        apt-get update -y && apt-get install -y jq
    elif command -v apk &> /dev/null; then
        apk add jq
    else
        echo "Erreur : Gestionnaire de paquets non supporté (ni apt, ni apk)."
        exit 1
    fi
fi

curl -s -H "Authorization: ApiKey ${API_KEY}" --request POST "https://api.elastic-cloud.com/api/v1/organizations/${ORG_ID}/invitations" --header "Content-Type: application/json" --data "{\"emails\":[\"${EMAIL}\"],\"role_assignments\":{\"deployment\":[{\"role_id\":\"deployment-viewer\",\"organization_id\":\"${ORG_ID}\",\"all\":true}]}}"