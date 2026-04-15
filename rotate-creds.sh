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

step_ok()   { printf "  ${GREEN}${CHECK}${RESET} %s\n" "$1"; }
step_fail() { printf "  ${RED}${CROSS}${RESET} %s\n" "$1"; exit 1; }
step_info() { printf "  ${YELLOW}${ARROW}${RESET} %s\n" "$1"; }
header()    { printf "\n${CYAN}━━━ %s ━━━${RESET}\n\n" "$1"; }

header "Credential Rotation for Pluralsight Lab"

# ── Load .env ──
ENV_FILE="$(dirname "$0")/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  step_fail ".env file not found — update it with new credentials first"
fi
source "$ENV_FILE"

for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION; do
  if [[ -z "${!var:-}" ]]; then
    step_fail "Missing $var in .env"
  fi
done
step_ok "Credentials loaded from .env"
step_info "Access Key: ${AWS_ACCESS_KEY_ID:0:8}********"
step_info "Region: $AWS_DEFAULT_REGION"

# ── Update AWS CLI ──
header "AWS CLI"

aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
aws configure set default.region "$AWS_DEFAULT_REGION"
aws configure set default.output json

aws sts get-caller-identity &>/dev/null && \
  step_ok "CLI credentials validated" || \
  step_fail "CLI credentials invalid — check your .env"

# ── Update K8s Secret ──
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
step_ok "New secret created"

rm -f "$CREDS_FILE"
step_ok "Temp file cleaned"

# ── Purge old managed resources ──
header "Purging Stale Resources (old lab)"

step_info "Pausing ArgoCD auto-sync..."
kubectl patch application crossplane-resources -n argocd --type merge -p '{"spec":{"syncPolicy":null}}'
step_ok "Auto-sync paused"

RESOURCE_TYPES=(
  "lblisteners.elbv2.aws.upbound.io"
  "lbtargetgroupattachments.elbv2.aws.upbound.io"
  "lbtargetgroups.elbv2.aws.upbound.io"
  "lb.elbv2.aws.upbound.io"
  "instances.ec2.aws.upbound.io"
  "instanceprofiles.iam.aws.upbound.io"
  "rolepolicyattachments.iam.aws.upbound.io"
  "roles.iam.aws.upbound.io"
  "securitygrouprules.ec2.aws.upbound.io"
  "securitygroups.ec2.aws.upbound.io"
  "routes.ec2.aws.upbound.io"
  "routetableassociations.ec2.aws.upbound.io"
  "routetables.ec2.aws.upbound.io"
  "natgateways.ec2.aws.upbound.io"
  "eips.ec2.aws.upbound.io"
  "subnets.ec2.aws.upbound.io"
  "internetgateways.ec2.aws.upbound.io"
  "vpcs.ec2.aws.upbound.io"
  "buckets.s3.aws.upbound.io"
)

for rt in "${RESOURCE_TYPES[@]}"; do
  ITEMS=$(kubectl get "$rt" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
  if [[ -n "$ITEMS" ]]; then
    while IFS= read -r item; do
      kubectl patch "$rt" "$item" --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
      kubectl delete "$rt" "$item" --wait=false 2>/dev/null || true
      step_ok "Deleted $rt/$item"
    done <<< "$ITEMS"
  fi
done

step_info "Waiting for resources to be removed (30s)..."
sleep 30
step_ok "Purge complete"

# ── Restart provider pods ──
header "Restarting Provider Pods"

PODS=$(kubectl get pods -n crossplane-system --no-headers -o custom-columns=NAME:.metadata.name | grep -E "^provider-|^upbound-provider-")

if [[ -z "$PODS" ]]; then
  step_fail "No provider pods found"
fi

while IFS= read -r pod; do
  kubectl delete pod "$pod" -n crossplane-system
  step_ok "Restarted $pod"
done <<< "$PODS"

# ── Wait for pods to recover ──
step_info "Waiting for pods to become Ready (timeout: 90s)..."
SECONDS=0
until kubectl get pods -n crossplane-system --no-headers | grep -E "provider-|upbound-provider-" | grep -qv "Running"; do
  if (( SECONDS > 90 )); then
    step_fail "Pods did not recover within 90s"
  fi
  sleep 2
done 2>/dev/null

sleep 5
SECONDS=0
ALL_READY=false
until $ALL_READY; do
  if (( SECONDS > 90 )); then
    step_fail "Pods did not become Ready within 90s"
  fi
  ALL_READY=true
  while IFS= read -r line; do
    READY=$(echo "$line" | awk '{print $2}')
    STATUS=$(echo "$line" | awk '{print $3}')
    if [[ "$STATUS" != "Running" ]] || [[ "$READY" != *"/"* ]] || [[ "${READY%/*}" != "${READY#*/}" ]]; then
      ALL_READY=false
    fi
  done <<< "$(kubectl get pods -n crossplane-system --no-headers | grep -E 'provider-|upbound-provider-')"
  sleep 3
done
step_ok "All provider pods running"

# ── Validation ──
header "Validation"

kubectl get providers --no-headers | while read -r line; do
  step_info "  $line"
done

printf "\n${GREEN}━━━ Rotation complete! ━━━${RESET}\n\n"
step_info "New credentials active. ArgoCD will reconcile automatically."

# ── Re-enable ArgoCD auto-sync ──
header "Re-enabling ArgoCD"

kubectl patch application crossplane-resources -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
step_ok "Auto-sync re-enabled — ArgoCD will recreate all resources"

step_info "Monitor with: watch -n5 'kubectl get application crossplane-resources -n argocd -o jsonpath=\"{.status.health.status}\"'"