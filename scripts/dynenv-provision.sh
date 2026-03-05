#!/bin/sh
set -xe

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

printf "${GREEN}Monk Capsules - Provision${NC}\n"
printf "${GREEN}Creating cluster: $CLUSTER_NAME${NC}\n"

# Validate required env vars
for var in CLUSTER_NAME ENVIRONMENT_NAME MONK_CLI_TOKEN MONK_SUBSCRIPTION_TOKEN MONK_SUBSCRIPTION_API_BASE MONK_ORG_SLUG MONK_PROJECT_SLUG CLOUD_PROVIDER CLOUD_REGION CLOUD_INSTANCE_TYPE CLOUD_INSTANCE_COUNT; do
    eval val=\$$var
    if [ -z "$val" ]; then
        printf "${RED}Error: $var is required${NC}\n"
        exit 1
    fi
done

AUTH_HEADER="Authorization: Bearer $MONK_SUBSCRIPTION_TOKEN"

# Configure Monk CLI for non-interactive CI usage
export MONK_SERVICE_TOKEN="$MONK_CLI_TOKEN"
export MONK_CLI_NO_FANCY=true
export MONK_CLI_NO_COLOR=true
export MONK_NO_INTERACTIVE=true

# Start the Monk daemon in background (not running by default in CI container)
printf "${GREEN}Starting Monk daemon...${NC}\n"
monkd > /tmp/monkd.log 2>&1 &
printf "${GREEN}Waiting for daemon to initialize...${NC}\n"
sleep 20
printf "${GREEN}Daemon ready.${NC}\n"

CREATED_CLUSTER=false

cleanup_on_failure() {
    if [ "$CREATED_CLUSTER" = "true" ]; then
        printf "${YELLOW}Provisioning failed, attempting cleanup of newly created cluster...${NC}\n"
        monk cluster nuke --force --remove-volumes --remove-snapshots 2>/dev/null || true
        printf "${YELLOW}Cleanup attempted.${NC}\n"
    else
        printf "${YELLOW}Provisioning failed. Skipping destructive cleanup because no new cluster was created.${NC}\n"
    fi
}
trap cleanup_on_failure ERR

# ============================================================================
# I.A -- Reconcile environment and cluster (idempotent)
# ============================================================================
BRANCH_NAME="${BRANCH_NAME:-$ENVIRONMENT_NAME}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_ENVIRONMENT="${GITHUB_ENVIRONMENT:-capsule-$ENVIRONMENT_NAME}"
NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
ENV_PATH="$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/projects/$MONK_PROJECT_SLUG/environments/$ENVIRONMENT_NAME"

ENV_EXISTS=false
USE_EXISTING_CLUSTER=false
ENV_CLUSTER_ID=""
CLUSTER_ID=""
MONKCODE=""

printf "${GREEN}Checking if environment exists: $ENVIRONMENT_NAME...${NC}\n"
ENV_HTTP_CODE=$(curl -s -o /tmp/existing_env_response.json -w "%{http_code}" "$ENV_PATH" \
    -H "$AUTH_HEADER")
if [ "$ENV_HTTP_CODE" = "200" ]; then
    ENV_EXISTS=true
    ENV_CLUSTER_ID=$(jq -r '.cluster.clusterId // .clusterExternalId // empty' /tmp/existing_env_response.json)
    MONKCODE=$(jq -r '.cluster.monkcode // empty' /tmp/existing_env_response.json)
    if [ -n "$ENV_CLUSTER_ID" ] && [ -n "$MONKCODE" ]; then
        CLUSTER_ID="$ENV_CLUSTER_ID"
        USE_EXISTING_CLUSTER=true
        printf "${GREEN}Found existing environment linked to cluster $CLUSTER_ID. Reusing.${NC}\n"
    else
        printf "${YELLOW}Environment exists but has no usable cluster link. Will provision and relink.${NC}\n"
    fi
elif [ "$ENV_HTTP_CODE" = "404" ]; then
    printf "${GREEN}Environment does not exist yet. Will create it.${NC}\n"
else
    printf "${RED}Error: Failed to query environment (HTTP $ENV_HTTP_CODE)${NC}\n"
    cat /tmp/existing_env_response.json 2>/dev/null || true
    exit 1
fi

if [ "$USE_EXISTING_CLUSTER" != "true" ] && [ "$ENV_EXISTS" != "true" ]; then
    printf "${GREEN}Checking for an existing cluster record named $CLUSTER_NAME...${NC}\n"
    CLUSTERS_HTTP_CODE=$(curl -s -o /tmp/existing_clusters_response.json -w "%{http_code}" \
        "$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/clusters" \
        -H "$AUTH_HEADER")
    if [ "$CLUSTERS_HTTP_CODE" -ge 200 ] && [ "$CLUSTERS_HTTP_CODE" -lt 300 ]; then
        CANDIDATE_CLUSTER_ID=$(jq -r --arg name "$CLUSTER_NAME" '[.[] | select((.name // "") == $name)][0].clusterId // empty' /tmp/existing_clusters_response.json)
        CANDIDATE_MONKCODE=$(jq -r --arg name "$CLUSTER_NAME" '[.[] | select((.name // "") == $name)][0].monkcode // empty' /tmp/existing_clusters_response.json)
        if [ -n "$CANDIDATE_CLUSTER_ID" ] && [ -n "$CANDIDATE_MONKCODE" ]; then
            CLUSTER_ID="$CANDIDATE_CLUSTER_ID"
            MONKCODE="$CANDIDATE_MONKCODE"
            USE_EXISTING_CLUSTER=true
            printf "${GREEN}Found existing cluster record $CLUSTER_ID by name. Reusing.${NC}\n"
        fi
    else
        printf "${YELLOW}Warning: Could not list org clusters (HTTP $CLUSTERS_HTTP_CODE). Continuing with fresh provisioning.${NC}\n"
    fi
fi

if [ "$USE_EXISTING_CLUSTER" = "true" ]; then
    printf "${GREEN}Connecting to existing cluster...${NC}\n"
    if monk cluster join --force --purge=false --monkcode "$MONKCODE" --local-name "provision-runner-$$"; then
        printf "${GREEN}Connected to existing cluster.${NC}\n"
    else
        printf "${YELLOW}Warning: Failed to join existing cluster. Falling back to fresh provisioning.${NC}\n"
        USE_EXISTING_CLUSTER=false
        CLUSTER_ID=""
        MONKCODE=""
    fi
fi

if [ "$USE_EXISTING_CLUSTER" != "true" ]; then
    # A.2 Create new cluster
    printf "${GREEN}Creating new cluster: $CLUSTER_NAME...${NC}\n"
    monk cluster new -n "$CLUSTER_NAME"
    CREATED_CLUSTER=true

    # A.3 Inject cloud provider credentials
    printf "${GREEN}Adding cloud provider: $CLOUD_PROVIDER...${NC}\n"
monk cluster provider add --provider digitalocean --digitalocean-token "$DO_API_TOKEN"

    # A.4 Grow cluster (provision instances)
    printf "${GREEN}Growing cluster ($CLOUD_INSTANCE_COUNT x $CLOUD_INSTANCE_TYPE in $CLOUD_REGION)...${NC}\n"
    monk cluster grow \
        --name "$CLUSTER_NAME" \
        --tag "$BRANCH_TAG" \
        --provider "$CLOUD_PROVIDER" \
        --region "$CLOUD_REGION" \
        --instance-type "$CLOUD_INSTANCE_TYPE" \
        --num-instances "$CLOUD_INSTANCE_COUNT" \
        --generate-domain \
        --generate-ssl-cert

    # A.5 Extract cluster info
    printf "${GREEN}Extracting cluster information...${NC}\n"
    CLUSTER_INFO=$(monk --json cluster info 2>&1 | tail -n 1)
    MONKCODE=$(echo "$CLUSTER_INFO" | jq -r '.data.monkcode')
    CLUSTER_ID=$(echo "$CLUSTER_INFO" | jq -r '.data.id')

    if [ -z "$MONKCODE" ] || [ "$MONKCODE" = "null" ]; then
        printf "${RED}Error: Failed to extract monkcode from cluster info${NC}\n"
        exit 1
    fi
    printf "${GREEN}Cluster ready. ID: $CLUSTER_ID${NC}\n"

    # A.5.1 Enable ingress plugin
    printf "${GREEN}Enabling ingress plugin...${NC}\n"
    monk plugins enable ingress || printf "${YELLOW}Warning: Failed to enable ingress plugin (non-blocking)${NC}\n"

    # A.6 Set up per-cluster container registry
    printf "${GREEN}Setting up container registry...${NC}\n"

    # A.6.1 Ensure a peer has the "system" tag (registry runs on the system-tagged peer)
    printf "${GREEN}Ensuring system tag on a cluster peer...${NC}\n"
    PEERS_JSON=$(monk --json cluster peers)
    SYSTEM_PEER_ID=$(echo "$PEERS_JSON" | jq -r '[.[] | select(.tags != null and (.tags | contains(["system"])))][0].id // empty')
    if [ -z "$SYSTEM_PEER_ID" ]; then
        SYSTEM_PEER_ID=$(echo "$PEERS_JSON" | jq -r '[.[] | select(.name != "local")][0].id // empty')
        if [ -z "$SYSTEM_PEER_ID" ]; then
            printf "${RED}Error: No suitable peer found for system tag${NC}\n"
            exit 1
        fi
        EXISTING_TAGS=$(echo "$PEERS_JSON" | jq -r --arg id "$SYSTEM_PEER_ID" '[.[] | select(.id == $id)][0].tags // [] | join(",")')
        if [ -n "$EXISTING_TAGS" ]; then
            SYSTEM_TAGS="system,$EXISTING_TAGS"
        else
            SYSTEM_TAGS="system"
        fi
        monk cluster peer-tags --id "$SYSTEM_PEER_ID" --tag "$SYSTEM_TAGS"
        printf "${GREEN}Tagged peer $SYSTEM_PEER_ID with system tag.${NC}\n"
    else
        printf "${GREEN}System-tagged peer already exists: $SYSTEM_PEER_ID${NC}\n"
    fi

    SYSTEM_PEER_DOMAIN=$(echo "$PEERS_JSON" | jq -r --arg id "$SYSTEM_PEER_ID" '[.[] | select(.id == $id)][0].domain // empty')
    if [ -z "$SYSTEM_PEER_DOMAIN" ]; then
        printf "${RED}Error: No domain found for system peer. Ensure --generate-domain was used during grow.${NC}\n"
        exit 1
    fi

    # A.6.2 Write registry template and load it
    cat > /tmp/registry-template.yaml << 'REGISTRY_TEMPLATE_EOF'
namespace: /system
registry:
  defines: runnable
  variables:
    listen-port:
      type: string
      value: 5000
  services:
    registry:
      port: <- $listen-port
      host-port: <- $listen-port
      container: registry
      protocol: tcp
  containers:
    registry:
      image: docker.io/registry:2
      environment:
        - "REGISTRY_STORAGE_DELETE_ENABLED=true"
        - "REGISTRY_HTTP_RELATIVEURLS=true"
nginx:
  defines: runnable
  containers:
    nginx:
      image: docker.io/bitnamilegacy/nginx
      image-tag: latest
  services:
    nginx:
      port: <- $listen-port
      host-port: <- $listen-port
      container: nginx
      protocol: tcp
      publish: true
  connections:
    registry:
      runnable: system/registry
      service: registry
  variables:
    listen-port:
      type: int
      value: 7080
    registry-host:
      type: string
      value: <- get-hostname("system/registry", "registry")
    registry-port:
      value: 5000
      type: int
    resolver-ip:
      value: <- get-resolver-ip
      type: string
    ssl-certificate:
      type: string
      value: <- ssl-certificate
    ssl-private-key:
      type: string
      value: <- ssl-private-key
    domain:
      type: string
      value: <- domain-name
  files:
    defines: files
    htpasswd-def:
      mode: 511
      container: nginx
      path: /etc/nginx/conf.d/nginx.htpasswd
      contents: <- secret("htpasswd")
    ssl-cert-file:
      mode: 511
      container: nginx
      path: /etc/nginx/ssl/registry.crt
      contents: <- ssl-certificate
    ssl-key-file:
      mode: 511
      container: nginx
      path: /etc/nginx/ssl/registry.key
      contents: <- ssl-private-key
    server-def:
      mode: 511
      container: nginx
      path: /opt/bitnami/nginx/conf/server_blocks/reverse_proxy.conf
      contents: |
        ## Set a variable to help us decide if we need to add the
        ## 'Docker-Distribution-Api-Version' header.
        ## The registry always sets this header.
        ## In the case of nginx performing auth, the header is unset
        ## since nginx is auth-ing before proxying.
        map $upstream_http_docker_distribution_api_version $docker_distribution_api_version {
          '' 'registry/2.0';
        }
        
        server {
          listen 0.0.0.0:{{ v "listen-port" }} ssl default_server;
          
          # SSL Configuration
          ssl_certificate /etc/nginx/ssl/registry.crt;
          ssl_certificate_key /etc/nginx/ssl/registry.key;
          server_name {{ v "domain" }};
          
          # SSL Security Settings
          ssl_protocols TLSv1.2 TLSv1.3;
          ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
          ssl_prefer_server_ciphers off;
          ssl_session_cache shared:SSL:10m;
          ssl_session_timeout 1d;

          resolver {{ v "resolver-ip" }} valid=30s;
        
          proxy_pass_request_headers on;
          proxy_http_version 1.1;
          proxy_set_header X-Forwarded-Host $host;
          proxy_set_header X-Forwarded-Server $host;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header Host $host;
        
          # disable any limits to avoid HTTP 413 for large image uploads
          client_max_body_size 0;
        
          # required to avoid HTTP 411: see Issue #1486 (https://github.com/moby/moby/issues/1486)
          chunked_transfer_encoding on;
        
          # Add basic authentication
          auth_basic "System realm";
          auth_basic_user_file /etc/nginx/conf.d/nginx.htpasswd;
        
          {{ if v "registry-host" }}
          set $registry_upstream http://{{ v "registry-host" }}:{{ v "registry-port" }};
          location /v2/ {
            # Do not allow connections from docker 1.5 and earlier
            # docker pre-1.6.0 did not properly set the user agent on ping, catch "Go *" user agents
            if ($http_user_agent ~ "^(docker/1.(3|4|5(?!.[0-9]-dev))|Go ).*$" ) {
              return 404;
            }
        
            ## If $docker_distribution_api_version is empty, the header is not added.
            ## See the map directive above where this variable is defined.
            add_header 'Docker-Distribution-Api-Version' $docker_distribution_api_version always;
        
            # Ensure proper headers for Docker registry protocol
            proxy_set_header Host {{ v "domain" }}:{{ v "listen-port" }};
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Host {{ v "domain" }};
            proxy_set_header X-Forwarded-Port {{ v "listen-port" }};
            
            # Important: Don't buffer uploads for large image layers
            proxy_request_buffering off;
            proxy_buffering off;
            
            proxy_pass $registry_upstream;
            proxy_read_timeout 900;
          }
          {{ end }}
        }
REGISTRY_TEMPLATE_EOF
    monk load /tmp/registry-template.yaml
    rm -f /tmp/registry-template.yaml

    # A.6.3 Generate registry credentials and htpasswd
    REGISTRY_USERNAME="monk"
    REGISTRY_PASSWORD=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
    # Generate bcrypt hash compatible with nginx (htpasswd installed via workflow step)
    HTPASSWD=$(htpasswd -nbBC 10 "$REGISTRY_USERNAME" "$REGISTRY_PASSWORD")
    # Ensure nginx-compatible $2y$ prefix
    HTPASSWD=$(echo "$HTPASSWD" | sed 's/\$2b\$/\$2y\$/;s/\$2a\$/\$2y\$/')
    monk secrets add -r system/nginx "htpasswd=$HTPASSWD"

    # A.6.4 Run registry and nginx services on system-tagged peer
    printf "${GREEN}Starting registry service...${NC}\n"
    monk run -t system system/registry
    printf "${GREEN}Starting nginx proxy...${NC}\n"
    monk run -t system system/nginx

    # A.6.5 Determine registry address and configure docker login
    REGISTRY_PORT=7080
    REGISTRY_ADDRESS="${SYSTEM_PEER_DOMAIN}:${REGISTRY_PORT}"
    printf "${GREEN}Registry available at: $REGISTRY_ADDRESS${NC}\n"

    # Wait for registry to be ready and configure docker login
    RETRIES=0
    REGISTRY_READY=false
    while [ "$RETRIES" -lt 5 ]; do
        RETRIES=$((RETRIES + 1))
        printf "  Waiting for registry to be ready (attempt $RETRIES/5)...\n"
        sleep 10
        if monk registry --server "$REGISTRY_ADDRESS" -u "$REGISTRY_USERNAME" -p "$REGISTRY_PASSWORD" -a registry.local 2>/dev/null; then
            REGISTRY_READY=true
            break
        fi
    done
    if [ "$REGISTRY_READY" != "true" ]; then
        printf "${RED}Error: Registry did not become ready in time${NC}\n"
        exit 1
    fi
    printf "${GREEN}Docker login configured for registry.${NC}\n"

    # A.6.6 Store registry credentials as a cluster secret for later retrieval
    REGISTRY_CREDS_JSON=$(printf '{"username":"%s","password":"%s","address":"%s","domain":"%s","source":"auto","tlsVerify":true}' \
        "$REGISTRY_USERNAME" "$REGISTRY_PASSWORD" "$REGISTRY_ADDRESS" "$SYSTEM_PEER_DOMAIN")
    monk secrets add -r system/registry "registry-auth=$REGISTRY_CREDS_JSON"
    printf "${GREEN}Registry credentials stored as cluster secret.${NC}\n"
fi

# A.7 Inject workload secrets

printf "${GREEN}Seeding workload secrets into cluster...${NC}\n"
    monk secrets add -g "default-vercel-token=$DEFAULT_VERCEL_TOKEN"
printf "${GREEN}Workload secrets configured.${NC}\n"


# ============================================================================
# I.B -- Create and populate environment in backend
# ============================================================================
printf "${GREEN}Syncing with subscription service...${NC}\n"

# B.1 Upsert cluster record
printf "${GREEN}Registering cluster in backend...${NC}\n"
HTTP_CODE=$(curl -s -o /tmp/cluster_response.json -w "%{http_code}" -X POST "$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/clusters" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "{\"clusterId\":\"$CLUSTER_ID\",\"name\":\"$CLUSTER_NAME\",\"monkcode\":\"$MONKCODE\"}")
if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    printf "${RED}Error: Failed to register cluster in backend (HTTP $HTTP_CODE)${NC}\n"
    cat /tmp/cluster_response.json 2>/dev/null || true
    exit 1
fi
printf "${GREEN}Cluster registered.${NC}\n"

# B.2 Ensure environment exists and is linked to the resolved cluster
CAPSULE_SETTINGS_PAYLOAD=$(jq -n \
    --arg branch "$BRANCH_NAME" \
    --arg repository "$GITHUB_REPOSITORY" \
    --arg githubEnvironment "$GITHUB_ENVIRONMENT" \
    --arg status "provisioning" \
    --arg now "$NOW_UTC" \
    '{
      settings: {
        capsule: {
          source: "dynenv",
          branch: $branch,
          repository: $repository,
          githubEnvironment: $githubEnvironment,
          status: $status,
          updatedAt: $now
        }
      }
    }')

if [ "$ENV_EXISTS" = "true" ]; then
    printf "${GREEN}Environment exists. Reconciling link and metadata...${NC}\n"
    if [ -z "$ENV_CLUSTER_ID" ] || [ "$ENV_CLUSTER_ID" != "$CLUSTER_ID" ]; then
        LINK_HTTP_CODE=$(curl -s -o /tmp/env_link_response.json -w "%{http_code}" -X PUT "$ENV_PATH/cluster" \
            -H "$AUTH_HEADER" \
            -H "Content-Type: application/json" \
            -d "{\"clusterId\":\"$CLUSTER_ID\",\"force\":true}")
        if [ "$LINK_HTTP_CODE" -lt 200 ] || [ "$LINK_HTTP_CODE" -ge 300 ]; then
            printf "${RED}Error: Failed to link environment to cluster (HTTP $LINK_HTTP_CODE)${NC}\n"
            cat /tmp/env_link_response.json 2>/dev/null || true
            exit 1
        fi
        ENV_CLUSTER_ID="$CLUSTER_ID"
        printf "${GREEN}Environment linked to cluster $CLUSTER_ID.${NC}\n"
    else
        printf "${GREEN}Environment already linked to cluster $CLUSTER_ID.${NC}\n"
    fi

    PATCH_HTTP_CODE=$(curl -s -o /tmp/env_patch_response.json -w "%{http_code}" -X PATCH "$ENV_PATH" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$CAPSULE_SETTINGS_PAYLOAD")
    if [ "$PATCH_HTTP_CODE" -lt 200 ] || [ "$PATCH_HTTP_CODE" -ge 300 ]; then
        printf "${RED}Error: Failed to update capsule metadata (HTTP $PATCH_HTTP_CODE)${NC}\n"
        cat /tmp/env_patch_response.json 2>/dev/null || true
        exit 1
    fi
    printf "${GREEN}Environment metadata updated.${NC}\n"
else
    printf "${GREEN}Creating environment: $ENVIRONMENT_NAME...${NC}\n"
    ENV_CREATE_PAYLOAD=$(jq -n \
        --arg name "$ENVIRONMENT_NAME" \
        --arg clusterId "$CLUSTER_ID" \
        --arg projectSlug "$MONK_PROJECT_SLUG" \
        --arg branch "$BRANCH_NAME" \
        --arg repository "$GITHUB_REPOSITORY" \
        --arg githubEnvironment "$GITHUB_ENVIRONMENT" \
        --arg status "provisioning" \
        --arg now "$NOW_UTC" \
        '{
          name: $name,
          clusterId: $clusterId,
          projectSlug: $projectSlug,
          settings: {
            capsule: {
              source: "dynenv",
              branch: $branch,
              repository: $repository,
              githubEnvironment: $githubEnvironment,
              status: $status,
              updatedAt: $now
            }
          }
        }')
    HTTP_CODE=$(curl -s -o /tmp/env_response.json -w "%{http_code}" -X POST "$MONK_SUBSCRIPTION_API_BASE/orgs/$MONK_ORG_SLUG/environments" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$ENV_CREATE_PAYLOAD")
    if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
        printf "${RED}Error: Failed to create environment in backend (HTTP $HTTP_CODE)${NC}\n"
        cat /tmp/env_response.json 2>/dev/null || true
        exit 1
    fi
    ENV_EXISTS=true
    ENV_CLUSTER_ID="$CLUSTER_ID"
    printf "${GREEN}Environment created and linked to cluster.${NC}\n"
fi

# B.3 Registry credentials are stored as cluster secrets (step A.6.6),
# and retrieved via monk secrets get in the fetch-metadata workflow job.

# ============================================================================
# I.C -- Exit cluster to avoid runner remaining as a connected peer
# ============================================================================
printf "${GREEN}Exiting cluster (local node disconnect)...${NC}\n"
monk cluster exit --force
printf "${GREEN}Disconnected from cluster.${NC}\n"

printf "${GREEN}Provisioning complete! Cluster $CLUSTER_NAME is ready.${NC}\n"
