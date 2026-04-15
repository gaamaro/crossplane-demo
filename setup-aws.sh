#!/usr/bin/env bash
set -euo pipefail

# ── Colors & Symbols ──
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"
CHECK="✔"
CROSS="✗"
ARROW="→"
SPIN="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

spinner() {
  local pid=$1 msg=$2
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${CYAN}${SPIN:i%${#SPIN}:1}${RESET} %s" "$msg"
    sleep 0.1
    ((i++))
  done
  printf "\r"
}

step_ok()   { printf "  ${GREEN}${CHECK}${RESET} %s\n" "$1"; }
step_fail() { printf "  ${RED}${CROSS}${RESET} %s\n" "$1"; exit 1; }
step_info() { printf "  ${YELLOW}${ARROW}${RESET} %s\n" "$1"; }
header()    { printf "\n${CYAN}━━━ %s ━━━${RESET}\n\n" "$1"; }

# ── Load .env ──
header "AWS Credentials Setup for Crossplane"

ENV_FILE="$(dirname "$0")/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  step_fail ".env file not found at $ENV_FILE"
fi
step_ok "Found .env file"

source "$ENV_FILE"

for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION; do
  if [[ -z "${!var:-}" ]]; then
    step_fail "Missing $var in .env"
  fi
done
step_ok "All required variables loaded"
# ── Configure AWS CLI ──
header "AWS CLI Configuration"

aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
step_ok "Access Key configured"

aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
step_ok "Secret Key configured"

aws configure set default.region "$AWS_DEFAULT_REGION"
step_ok "Region set to $AWS_DEFAULT_REGION"

aws configure set default.output json
step_ok "Output format set to json"

aws sts get-caller-identity &>/dev/null && \
  step_ok "AWS credentials validated (sts get-caller-identity)" || \
  step_fail "AWS credentials invalid — check your .env"
  
step_info "Region: $AWS_DEFAULT_REGION"
step_info "Access Key: ${AWS_ACCESS_KEY_ID:0:8}********"

# ── Create K8s Secret ──
header "Kubernetes Secret"

CREDS_FILE=$(mktemp)
cat > "$CREDS_FILE" <<EOF
[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
EOF

kubectl delete secret aws-credentials -n crossplane-system 2>/dev/null && \
  step_info "Removed old secret" || true

kubectl create secret generic aws-credentials \
  -n crossplane-system \
  --from-file=credentials="$CREDS_FILE"
step_ok "Secret aws-credentials created"

rm -f "$CREDS_FILE"
step_ok "Temp credentials file cleaned up"

# ── Install AWS Provider ──
header "Crossplane AWS Provider"

kubectl apply -f "$(dirname "$0")/infra/crossplane/provider.yaml"
step_ok "Provider manifests applied"

PROVIDERS=("provider-aws-s3" "provider-aws-ec2" "provider-aws-iam" "provider-aws-elbv2" "upbound-provider-family-aws")
step_info "Waiting for ${#PROVIDERS[@]} providers to become healthy (timeout: 180s)..."
SECONDS=0
for provider in "${PROVIDERS[@]}"; do
  until kubectl get provider "$provider" -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null | grep -q "True"; do
    if (( SECONDS > 180 )); then
      step_fail "Provider $provider did not become healthy within 180s"
    fi
    printf "\r  ${CYAN}${SPIN:SECONDS%${#SPIN}:1}${RESET} Waiting for $provider... (%ds)" "$SECONDS"
    sleep 3
  done
  step_ok "$provider is healthy (${SECONDS}s)"
done

# ── Apply ProviderConfig ──
header "Provider Configuration"

kubectl apply -f "$(dirname "$0")/infra/crossplane/provider-config.yaml"
step_ok "ProviderConfig 'default' applied"

# ── Validation ──
header "Validation"

step_info "Checking crossplane-system pods..."
kubectl get pods -n crossplane-system --no-headers | while read -r line; do
  step_info "  $line"
done

step_info "Provider status:"
kubectl get providers --no-headers | while read -r line; do
  step_info "  $line"
done

printf "\n${GREEN}━━━ Setup complete! ━━━${RESET}\n\n"
step_info "Next: create resources in crossplane/resources/ and let ArgoCD sync them"