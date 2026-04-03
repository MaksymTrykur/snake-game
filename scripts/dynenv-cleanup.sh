#!/bin/sh
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

printf "${GREEN}Monk Capsules - Cleanup on Existing Cluster${NC}\n"

# Validate required env vars
for var in ENVIRONMENT_NAME MONK_CAPSULE_TOKEN MONK_SUBSCRIPTION_API_BASE MONK_AUTH_SERVICE_URL MONK_ORG_SLUG MONK_PROJECT_SLUG; do
    eval val=\$$var
    if [ -z "$val" ]; then
        printf "${RED}Error: $var is required${NC}\n"
        exit 1
    fi
done

MONK_WORKLOAD="${MONK_WORKLOAD:-}"
AUTH_HEADER="Authorization: Bearer $MONK_CAPSULE_TOKEN"
CAPSULE_DELETE_RECORDS="${CAPSULE_DELETE_RECORDS:-false}"
ENV_PATH="$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME"

# Mint a short-lived JIT CLI token
mint_jit_token() {
    local perms="$1"
    local name="${2:-jit-$$}"
    local ttl="${3:-60}"
    if ! JIT_RESPONSE=$(curl -sf -X POST "$MONK_AUTH_SERVICE_URL/api-keys" \
        -H "Authorization: Bearer $MONK_CAPSULE_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$name\",\"permissions\":$perms,\"expires_in_minutes\":$ttl}"); then
        printf "${RED}Error: Failed to mint JIT token${NC}\n" >&2
        return 1
    fi
    JIT_TOKEN=$(echo "$JIT_RESPONSE" | jq -r '.jwt // empty')
    if [ -z "$JIT_TOKEN" ]; then
        printf "${RED}Error: JIT token response did not include jwt${NC}\n" >&2
        return 1
    fi
    echo "$JIT_TOKEN"
}

export MONK_CLI_NO_FANCY=true
export MONK_CLI_NO_COLOR=true
export MONK_NO_INTERACTIVE=true

printf "${GREEN}Cleaning up capsule: $ENVIRONMENT_NAME${NC}\n"

# ============================================================================
# Step 1: Retrieve environment metadata to find cluster monkcode
# ============================================================================
printf "${GREEN}Retrieving environment metadata...${NC}\n"
HTTP_CODE=$(curl -s -o /tmp/env_response.json -w "%{http_code}" "$ENV_PATH" -H "$AUTH_HEADER")
if [ "$HTTP_CODE" = "404" ]; then
    printf "${YELLOW}Environment not found (already cleaned up). Exiting.${NC}\n"
    exit 0
fi
if [ "$HTTP_CODE" != "200" ]; then
    printf "${RED}Error: Failed to retrieve environment (HTTP $HTTP_CODE)${NC}\n"
    exit 1
fi
MONKCODE=$(jq -r '.cluster.monkcode // empty' /tmp/env_response.json)
CLUSTER_ID=$(jq -r '.cluster.clusterId // empty' /tmp/env_response.json)

# Best-effort: mark capsule metadata as destroyed
NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
curl -sf -X PATCH "$ENV_PATH" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    -d "{\"settings\":{\"capsule\":{\"source\":\"dynenv\",\"status\":\"destroyed\",\"lastDestroyedAt\":\"$NOW_UTC\",\"updatedAt\":\"$NOW_UTC\"}}}" > /dev/null 2>&1 || true

if [ -z "$MONKCODE" ]; then
    printf "${YELLOW}No cluster linked. Cleaning up backend records only.${NC}\n"
else
    # ============================================================================
    # Step 2: Connect to cluster, stop workloads, clean up
    # ============================================================================
    TARGET_CLUSTER_TOKEN="${TARGET_CLUSTER_TOKEN:-}"
    if [ -n "$TARGET_CLUSTER_TOKEN" ]; then
        printf "${GREEN}Using service token for cluster authentication.${NC}\n"
        export MONK_SERVICE_TOKEN="$TARGET_CLUSTER_TOKEN"
    else
        printf "${GREEN}Minting JIT CLI token for cleanup...${NC}\n"
        CLI_PERMS="[\"manage:/projects/$MONK_PROJECT_SLUG/clusters/**\",\"manage:/projects/$MONK_PROJECT_SLUG/secrets/**\"]"
        MONK_JIT_CLI_TOKEN=$(mint_jit_token "$CLI_PERMS" "cleanup-$ENVIRONMENT_NAME" 60)
        if [ -z "$MONK_JIT_CLI_TOKEN" ] || [ "$MONK_JIT_CLI_TOKEN" = "null" ]; then
            printf "${RED}Error: JIT CLI token mint returned empty${NC}\n"
            exit 1
        fi
        export MONK_SERVICE_TOKEN="$MONK_JIT_CLI_TOKEN"
    fi
    export MONK_SOCKET="monkcode://$MONKCODE"

    # Delete workloads using --repo to target the correct templates
    if [ -n "$MONK_WORKLOAD" ]; then
        printf "${GREEN}Deleting workload '$MONK_WORKLOAD' (repo: $ENVIRONMENT_NAME)...${NC}\n"
        monk delete --repo "$ENVIRONMENT_NAME" "$MONK_WORKLOAD" || printf "${YELLOW}Warning: delete failed (may already be removed)${NC}\n"
        printf "${GREEN}Unloading workload templates...${NC}\n"
        monk unload --repo "$ENVIRONMENT_NAME" --no-confirm "$MONK_WORKLOAD" || printf "${YELLOW}Warning: unload failed${NC}\n"
    fi

    # Remove scoped secrets for this environment
    printf "${GREEN}Removing scoped secrets for '$ENVIRONMENT_NAME'...${NC}\n"
    monk secrets remove --scope "$ENVIRONMENT_NAME" --all 2>/dev/null || printf "${YELLOW}Warning: scoped secret removal failed${NC}\n"
fi

# ============================================================================
# Step 3: Clean up backend records (DO NOT delete cluster — it's shared)
# ============================================================================
printf "${GREEN}Cleaning up backend records...${NC}\n"

# Unlink cluster from environment
printf "  Unlinking cluster from environment...\n"
curl -sf -X DELETE "$ENV_PATH/cluster" -H "$AUTH_HEADER" || printf "${YELLOW}  Warning: unlink failed${NC}\n"

# Delete environment record if permanent cleanup
if [ "$CAPSULE_DELETE_RECORDS" = "true" ]; then
    printf "  Deleting environment record...\n"
    curl -sf -X DELETE "$ENV_PATH" -H "$AUTH_HEADER" || printf "${YELLOW}  Warning: environment delete failed${NC}\n"
else
    printf "  Keeping environment record for future reprovision.\n"
fi

printf "${GREEN}Cleanup completed successfully.${NC}\n"
