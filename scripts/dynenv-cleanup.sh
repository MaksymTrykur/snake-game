#!/bin/sh
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

printf "${GREEN}Monk Capsules - Cleanup${NC}\n"

# Validate required env vars
for var in CLUSTER_NAME ENVIRONMENT_NAME MONK_SUBSCRIPTION_TOKEN MONK_CLI_TOKEN MONK_SUBSCRIPTION_API_BASE MONK_ORG_SLUG MONK_PROJECT_SLUG; do
    eval val=\$$var
    if [ -z "$val" ]; then
        printf "${RED}Error: $var is required${NC}\n"
        exit 1
    fi
done

AUTH_HEADER="Authorization: Bearer $MONK_SUBSCRIPTION_TOKEN"

# Configure Monk CLI for non-interactive CI usage
export MONK_CLI_NO_FANCY=true
export MONK_CLI_NO_COLOR=true
export MONK_NO_INTERACTIVE=true

printf "${GREEN}Cleaning up environment: $ENVIRONMENT_NAME (cluster: $CLUSTER_NAME)${NC}\n"

# ============================================================================
# Step 1: Retrieve environment metadata from backend
# ============================================================================
printf "${GREEN}Retrieving environment metadata...${NC}\n"
HTTP_CODE=$(curl -s -o /tmp/env_response.json -w "%{http_code}" \
    "$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME" \
    -H "$AUTH_HEADER")

if [ "$HTTP_CODE" = "404" ]; then
    printf "${YELLOW}Environment not found (already cleaned up). Exiting.${NC}\n"
    exit 0
fi

if [ "$HTTP_CODE" != "200" ]; then
    printf "${RED}Error: Failed to retrieve environment (HTTP $HTTP_CODE)${NC}\n"
    cat /tmp/env_response.json 2>/dev/null || true
    exit 1
fi

MONKCODE=$(jq -r '.cluster.monkcode // empty' /tmp/env_response.json)
CLUSTER_ID=$(jq -r '.cluster.clusterId // empty' /tmp/env_response.json)

if [ -z "$MONKCODE" ]; then
    printf "${YELLOW}No cluster linked to environment. Cleaning up backend records only.${NC}\n"
else
    # ============================================================================
    # Step 2: Start local monkd, join cluster, then nuke
    # ============================================================================
    # We must go through a local monkd so that nuke can properly tear down all
    # remote nodes. Connecting directly via monkcode:// would leave the node we
    # happen to talk to dangling.
    export MONK_SERVICE_TOKEN="$MONK_CLI_TOKEN"

    printf "${GREEN}Starting local Monk daemon...${NC}\n"
    monkd > /tmp/monkd.log 2>&1 &
    sleep 20

    printf "${GREEN}Joining cluster via monkcode...${NC}\n"
    monk cluster join --monkcode "$MONKCODE" --local-name "cleanup-runner-$$"

    printf "${GREEN}Nuking cluster: $CLUSTER_NAME...${NC}\n"
    monk cluster nuke --force --remove-volumes --remove-snapshots
    printf "${GREEN}Cluster nuked.${NC}\n"
fi

# ============================================================================
# Step 3: Clean up backend records (order: unlink -> delete env -> delete cluster)
# ============================================================================
printf "${GREEN}Cleaning up backend records...${NC}\n"

# 3a. Unlink cluster from environment
printf "  Unlinking cluster from environment...\n"
curl -sf -X DELETE \
    "$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME/cluster" \
    -H "$AUTH_HEADER" || printf "${YELLOW}  Warning: unlink failed (may already be unlinked)${NC}\n"

# 3b. Delete environment
printf "  Deleting environment...\n"
curl -sf -X DELETE \
    "$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME" \
    -H "$AUTH_HEADER" || printf "${YELLOW}  Warning: environment delete failed${NC}\n"

# 3c. Delete cluster record
if [ -n "$CLUSTER_ID" ]; then
    printf "  Deleting cluster record...\n"
    curl -sf -X DELETE \
        "$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/clusters/$CLUSTER_ID" \
        -H "$AUTH_HEADER" || printf "${YELLOW}  Warning: cluster record delete failed${NC}\n"
fi

printf "${GREEN}Cleanup completed successfully.${NC}\n"
