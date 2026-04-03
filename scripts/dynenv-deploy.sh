#!/bin/sh
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

printf "${GREEN}Monk Capsules - Deploy${NC}\n"

# Validate required env vars
# MONKCODE and MONK_SERVICE_TOKEN are set by the workflow job before invoking this script
for var in MONKCODE MONK_SERVICE_TOKEN MONK_WORKLOAD ENVIRONMENT_NAME; do
    eval val=\$$var
    if [ -z "$val" ]; then
        printf "${RED}Error: $var is required${NC}\n"
        exit 1
    fi
done

CAPSULE_MODE="${CAPSULE_MODE:-cloud}"
if [ "$CAPSULE_MODE" = "cluster" ]; then
    MONK_REPO="$ENVIRONMENT_NAME"
    MONK_TAG="${PEER_POOL_TAG:-capsule-pool}"
else
    MONK_REPO=""
    MONK_TAG="${BRANCH_TAG:-default}"
fi

# Configure Monk CLI for non-interactive CI usage
export MONK_SOCKET="monkcode://$MONKCODE"
export MONK_CLI_NO_FANCY=true
export MONK_CLI_NO_COLOR=true
export MONK_NO_INTERACTIVE=true

if [ ! -f "MANIFEST" ]; then
    printf "${RED}Error: MANIFEST file not found${NC}\n"
    exit 1
fi

# When MONK_REPO is set (shared cluster), load under a dedicated repo namespace.
if [ -n "$MONK_REPO" ]; then
    printf "${GREEN}Loading MANIFEST into repo '$MONK_REPO'...${NC}\n"
    monk load --repo "$MONK_REPO" MANIFEST

    printf "${GREEN}Deploying workload $MONK_REPO/$MONK_WORKLOAD to tag $MONK_TAG...${NC}\n"
    monk update -t "$MONK_TAG" --repo "$MONK_REPO" --secret-scope "$MONK_REPO" \
        -s environment="$ENVIRONMENT_NAME" "$MONK_REPO/$MONK_WORKLOAD"
else
    printf "${GREEN}Loading MANIFEST...${NC}\n"
    monk load MANIFEST

    printf "${GREEN}Deploying workload $MONK_WORKLOAD to tag $MONK_TAG...${NC}\n"
    monk update -t "$MONK_TAG" -s environment="$ENVIRONMENT_NAME" "$MONK_WORKLOAD"
fi

printf "${GREEN}Checking deployment status...${NC}\n"
monk ps

printf "${GREEN}Deployment completed successfully!${NC}\n"
