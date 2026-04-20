#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"
CHECK="✔"
CROSS="✗"
ARROW="→"

step_ok()   { printf "  ${GREEN}${CHECK}${RESET} %s\n" "$1"; }
step_fail() { printf "  ${RED}${CROSS}${RESET} %s\n" "$1"; }
step_info() { printf "  ${YELLOW}${ARROW}${RESET} %s\n" "$1"; }
header()    { printf "\n${CYAN}━━━ %s ━━━${RESET}\n\n" "$1"; }

header "Cleanup — Remove Resources, Keep Tools"

# ── Confirmation ──
printf "${RED}This will delete ALL Crossplane managed resources and ArgoCD applications.${RESET}\n"
printf "${RED}Tools (ArgoCD, Crossplane, Istio) will be preserved.${RESET}\n\n"
read -p "Type 'yes' to continue: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  step_fail "Aborted"
  exit 1
fi

# ── Disable ArgoCD auto-sync ──
header "ArgoCD Applications"

APPS=$(kubectl get applications -n argocd --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
if [[ -n "$APPS" ]]; then
  while IFS= read -r app; do
    step_info "Disabling auto-sync on $app"
    kubectl patch application "$app" -n argocd --type merge -p '{"spec":{"syncPolicy":null}}' 2>/dev/null || true
  done <<< "$APPS"
  step_ok "Auto-sync disabled"

  while IFS= read -r app; do
    kubectl delete application "$app" -n argocd --wait=false 2>/dev/null || true
    step_ok "Deleted application $app"
  done <<< "$APPS"
else
  step_info "No applications found"
fi

# ── Delete managed resources (order matters: dependents first) ──
header "Crossplane Managed Resources"

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
      kubectl delete "$rt" "$item" --wait=false 2>/dev/null || true
      step_ok "Deleted $rt/$item"
    done <<< "$ITEMS"
  fi
done

# ── Wait for AWS deletion ──
header "Waiting for AWS Resources to be Deleted"

step_info "This can take 2-5 minutes (NAT Gateway is slow)..."
SECONDS=0
TIMEOUT=300

while (( SECONDS < TIMEOUT )); do
  REMAINING=0
  for rt in "${RESOURCE_TYPES[@]}"; do
    COUNT=$(kubectl get "$rt" --no-headers 2>/dev/null | wc -l || echo 0)
    REMAINING=$((REMAINING + COUNT))
  done

  if (( REMAINING == 0 )); then
    break
  fi

  printf "\r  ${YELLOW}${ARROW}${RESET} %d resources remaining... (%ds)" "$REMAINING" "$SECONDS"
  sleep 5
done
printf "\r"

if (( REMAINING > 0 )); then
  step_info "$REMAINING resources still deleting — forcing finalizer removal"
  for rt in "${RESOURCE_TYPES[@]}"; do
    ITEMS=$(kubectl get "$rt" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
    if [[ -n "$ITEMS" ]]; then
      while IFS= read -r item; do
        kubectl patch "$rt" "$item" --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        kubectl delete "$rt" "$item" --wait=false 2>/dev/null || true
      done <<< "$ITEMS"
    fi
  done
  sleep 10
  step_ok "Forced cleanup complete"
else
  step_ok "All resources deleted from AWS (${SECONDS}s)"
fi

# ── Delete providers and secrets ──
header "Crossplane Providers"

kubectl delete providers --all --wait=false 2>/dev/null || true
step_ok "Providers marked for deletion"

kubectl delete providerconfigs --all --wait=false 2>/dev/null || true
step_ok "ProviderConfigs deleted"

kubectl delete secret aws-credentials -n crossplane-system 2>/dev/null && \
  step_ok "AWS credentials secret deleted" || \
  step_info "No credentials secret found"

kubectl delete deploymentruntimeconfigs --all 2>/dev/null || true
step_ok "RuntimeConfigs deleted"

# ── Wait for provider pods to terminate ──
step_info "Waiting for provider pods to terminate..."
SECONDS=0
while kubectl get pods -n crossplane-system --no-headers 2>/dev/null | grep -qE "provider-|upbound-provider-"; do
  if (( SECONDS > 120 )); then
    step_info "Some provider pods still running — they'll terminate eventually"
    break
  fi
  sleep 3
done
step_ok "Provider pods cleaned"

# ── Cleanup local files ──
header "Local Cleanup"

rm -rf istio-*/
step_ok "Removed Istio download folder"

rm -f awscliv2.zip
step_ok "Removed AWS CLI zip"

# ── Summary ──
header "Summary"

step_ok "All managed resources and applications removed"
step_info "Preserved: ArgoCD, Crossplane core, Istio"
step_info ""
step_info "To redeploy:"
step_info "  1. Update .env with new credentials"
step_info "  2. Run ./setup-aws.sh"
step_info "  3. kubectl apply -f infra/argocd/application.yaml"
