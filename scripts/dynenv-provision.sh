#!/bin/sh
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

printf "${GREEN}Monk Capsules - Provision on Existing Cluster${NC}\n"

# Validate required env vars
for var in ENVIRONMENT_NAME MONK_CAPSULE_TOKEN MONK_SUBSCRIPTION_API_BASE MONK_AUTH_SERVICE_URL MONK_ORG_SLUG MONK_PROJECT_SLUG TARGET_CLUSTER_ID; do
    eval val=\$$var
    if [ -z "$val" ]; then
        printf "${RED}Error: $var is required${NC}\n"
        exit 1
    fi
done

PEER_POOL_TAG="${PEER_POOL_TAG:-capsule-pool}"
AUTH_HEADER="Authorization: Bearer $MONK_CAPSULE_TOKEN"
BRANCH_NAME="${BRANCH_NAME:-$ENVIRONMENT_NAME}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_ENVIRONMENT="${GITHUB_ENVIRONMENT:-capsule-$ENVIRONMENT_NAME}"
NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Mint a short-lived JIT CLI token from the capsule master token
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

TARGET_CLUSTER_TOKEN="${TARGET_CLUSTER_TOKEN:-}"
if [ -n "$TARGET_CLUSTER_TOKEN" ]; then
    printf "${GREEN}Using service token for cluster authentication.${NC}\n"
    export MONK_SERVICE_TOKEN="$TARGET_CLUSTER_TOKEN"
else
    printf "${GREEN}Minting JIT CLI token...${NC}\n"
    CLI_PERMS="[\"manage:/projects/$MONK_PROJECT_SLUG/clusters/**\",\"manage:/projects/$MONK_PROJECT_SLUG/secrets/**\",\"manage:/projects/$MONK_PROJECT_SLUG/registry/**\"]"
    MONK_JIT_CLI_TOKEN=$(mint_jit_token "$CLI_PERMS" "provision-on-cluster-$ENVIRONMENT_NAME" 90)
    if [ -z "$MONK_JIT_CLI_TOKEN" ] || [ "$MONK_JIT_CLI_TOKEN" = "null" ]; then
        printf "${RED}Error: JIT CLI token mint returned empty${NC}\n"
        exit 1
    fi
    export MONK_SERVICE_TOKEN="$MONK_JIT_CLI_TOKEN"
fi
export MONK_CLI_NO_FANCY=true
export MONK_CLI_NO_COLOR=true
export MONK_NO_INTERACTIVE=true

# ============================================================================
# Step 1: Retrieve target cluster info from backend
# ============================================================================
printf "${GREEN}Fetching target cluster info...${NC}\n"
CLUSTER_HTTP_CODE=$(curl -s -o /tmp/cluster_response.json -w "%{http_code}" \
    "$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/clusters/$TARGET_CLUSTER_ID" \
    -H "$AUTH_HEADER")
if [ "$CLUSTER_HTTP_CODE" != "200" ]; then
    printf "${RED}Error: Failed to fetch target cluster (HTTP $CLUSTER_HTTP_CODE)${NC}\n"
    cat /tmp/cluster_response.json 2>/dev/null || true
    exit 1
fi
MONKCODE=$(jq -r '.monkcode // empty' /tmp/cluster_response.json)
CLUSTER_ID=$(jq -r '.clusterId // empty' /tmp/cluster_response.json)
CLUSTER_NAME=$(jq -r '.name // empty' /tmp/cluster_response.json)
if [ -z "$MONKCODE" ]; then
    printf "${RED}Error: Target cluster has no monkcode${NC}\n"
    exit 1
fi
printf "${GREEN}Target cluster: $CLUSTER_NAME (ID: $CLUSTER_ID)${NC}\n"

# ============================================================================
# Step 2: Connect to cluster and allocate peer from pool
# ============================================================================
export MONK_SOCKET="monkcode://$MONKCODE"

printf "${GREEN}Listing peers with pool tag '$PEER_POOL_TAG'...${NC}\n"
PEERS_JSON=$(monk --json cluster peers)
POOL_PEERS=$(echo "$PEERS_JSON" | jq -r --arg tag "$PEER_POOL_TAG" '[.[] | select(.tags != null and (.tags | index($tag)))]')
POOL_COUNT=$(echo "$POOL_PEERS" | jq 'length')

if [ "$POOL_COUNT" -eq 0 ]; then
    printf "${RED}Error: No peers found with pool tag '$PEER_POOL_TAG'${NC}\n"
    exit 1
fi
printf "${GREEN}Found $POOL_COUNT peer(s) in pool.${NC}\n"

# Pick a peer that doesn't already have the environment tag
SELECTED_PEER_ID=""
SELECTED_PEER_TAGS=""
for i in $(seq 0 $((POOL_COUNT - 1))); do
    PEER_ID=$(echo "$POOL_PEERS" | jq -r ".[$i].id")
    PEER_TAGS=$(echo "$POOL_PEERS" | jq -r ".[$i].tags | join(\",\")")
    HAS_ENV_TAG=$(echo "$POOL_PEERS" | jq -r --arg env "$ENVIRONMENT_NAME" ".[$i].tags | index(\$env) // \"no\"")
    if [ "$HAS_ENV_TAG" = "no" ] || [ "$HAS_ENV_TAG" = "null" ]; then
        SELECTED_PEER_ID="$PEER_ID"
        SELECTED_PEER_TAGS="$PEER_TAGS"
        break
    fi
done

if [ -z "$SELECTED_PEER_ID" ]; then
    printf "${RED}Error: All pool peers are already allocated. No available peers for capsule '$ENVIRONMENT_NAME'.${NC}\n"
    exit 1
fi
printf "${GREEN}Selected peer: $SELECTED_PEER_ID${NC}\n"

# Tag the selected peer with the capsule environment name
NEW_TAGS="$SELECTED_PEER_TAGS,$ENVIRONMENT_NAME"
printf "${GREEN}Tagging peer with '$ENVIRONMENT_NAME'...${NC}\n"
monk cluster peer-tags --id "$SELECTED_PEER_ID" --tag "$NEW_TAGS"

# ============================================================================
# Step 3: Seed scoped secrets for this environment
# ============================================================================
if [ -n "$WORKLOAD_SECRETS" ]; then
    printf "${GREEN}Seeding scoped secrets for environment '$ENVIRONMENT_NAME'...${NC}\n"
    for mapping in $WORKLOAD_SECRETS; do
        MONK_NAME=$(echo "$mapping" | cut -d: -f1)
        ENV_NAME=$(echo "$mapping" | cut -d: -f2)
        eval SECRET_VALUE=\$$ENV_NAME
        if [ -n "$SECRET_VALUE" ]; then
            monk secrets add --scope "$ENVIRONMENT_NAME" "$MONK_NAME=$SECRET_VALUE"
        else
            printf "${YELLOW}Warning: $ENV_NAME is empty, skipping $MONK_NAME${NC}\n"
        fi
    done
    printf "${GREEN}Scoped secrets configured.${NC}\n"
else
    printf "${YELLOW}No workload secrets to seed.${NC}\n"
fi

# ============================================================================
# Step 4: Create/update environment in backend
# ============================================================================
ENV_PATH="$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME"

printf "${GREEN}Checking if environment exists: $ENVIRONMENT_NAME...${NC}\n"
ENV_HTTP_CODE=$(curl -s -o /tmp/existing_env_response.json -w "%{http_code}" "$ENV_PATH" -H "$AUTH_HEADER")

CAPSULE_PAYLOAD=$(jq -n \
    --arg branch "$BRANCH_NAME" \
    --arg repo "$GITHUB_REPOSITORY" \
    --arg org "$MONK_ORG_SLUG" \
    --arg project "$MONK_PROJECT_SLUG" \
    --arg cluster "$CLUSTER_NAME" \
    --arg ghenv "$GITHUB_ENVIRONMENT" \
    --arg now "$NOW_UTC" \
    '{source:"dynenv",branch:$branch,repository:$repo,orgSlug:$org,projectSlug:$project,clusterName:$cluster,githubEnvironment:$ghenv,status:"provisioned",updatedAt:$now}')

if [ "$ENV_HTTP_CODE" = "200" ]; then
    printf "${GREEN}Environment exists, updating...${NC}\n"
    curl -sf -X PATCH "$ENV_PATH" \
        -H "$AUTH_HEADER" -H "Content-Type: application/json" \
        -d "{\"settings\":{\"capsule\":$CAPSULE_PAYLOAD}}" > /dev/null
else
    printf "${GREEN}Creating environment '$ENVIRONMENT_NAME'...${NC}\n"
    curl -sf -X POST "$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/environments" \
        -H "$AUTH_HEADER" -H "Content-Type: application/json" \
        -d "{\"name\":\"$ENVIRONMENT_NAME\",\"clusterId\":\"$CLUSTER_ID\",\"projectSlug\":\"$MONK_PROJECT_SLUG\",\"settings\":{\"capsule\":$CAPSULE_PAYLOAD}}" > /dev/null
fi

# Link cluster to environment (idempotent)
printf "${GREEN}Linking cluster to environment...${NC}\n"
curl -sf -X PUT "$ENV_PATH/cluster" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    -d "{\"clusterId\":\"$CLUSTER_ID\",\"force\":true}" > /dev/null 2>&1 || true

printf "${GREEN}Provisioning on existing cluster complete! Environment '$ENVIRONMENT_NAME' ready on cluster '$CLUSTER_NAME'.${NC}\n"
