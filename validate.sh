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
step_fail() { printf "  ${RED}${CROSS}${RESET} %s\n" "$1"; ERRORS=$((ERRORS+1)); }
step_info() { printf "  ${YELLOW}${ARROW}${RESET} %s\n" "$1"; }
header()    { printf "\n${CYAN}━━━ %s ━━━${RESET}\n\n" "$1"; }

ERRORS=0
INFRA_DIR="$(dirname "$0")/infra"

header "YAML Lint"

if ! command -v yamllint &>/dev/null; then
  step_info "Installing yamllint..."
  pip install yamllint --break-system-packages -q
fi

YAMLLINT_CONFIG=$(mktemp)
cat > "$YAMLLINT_CONFIG" <<EOF
extends: default
rules:
  line-length:
    max: 200
  truthy:
    check-keys: false
  document-start: disable
  indentation:
    spaces: 2
EOF

LINT_FAIL=0
while IFS= read -r file; do
  if ! yamllint -c "$YAMLLINT_CONFIG" "$file" 2>/dev/null; then
    step_fail "Lint failed: $file"
    LINT_FAIL=1
  fi
done < <(find "$INFRA_DIR" -name '*.yaml' -type f)

if [[ $LINT_FAIL -eq 0 ]]; then
  step_ok "All YAML files passed lint"
fi
rm -f "$YAMLLINT_CONFIG"

header "Structure Validation"

REQUIRED_FIELDS=("apiVersion" "kind" "metadata" "spec")
while IFS= read -r file; do
  for field in "${REQUIRED_FIELDS[@]}"; do
    if ! grep -q "^${field}:" "$file" 2>/dev/null; then
      step_fail "Missing '$field' in $file"
    fi
  done
done < <(find "$INFRA_DIR/crossplane/resources" -name '*.yaml' -type f)
step_ok "All resource files have required fields"

header "Security Checks"

while IFS= read -r file; do
  if grep -q "0\.0\.0\.0/0" "$file" 2>/dev/null; then
    if grep -q "type: ingress" "$file" 2>/dev/null; then
      PORTS=$(grep -A2 "0\.0\.0\.0/0" "$file" | grep "toPort" | awk '{print $2}')
      if [[ "$PORTS" != "80" && "$PORTS" != "443" ]]; then
        step_fail "Open ingress on non-standard port in $file (port: $PORTS)"
      else
        step_info "Open ingress on port $PORTS detected in $file (ALB expected)"
      fi
    fi
  fi
done < <(find "$INFRA_DIR" -name '*.yaml' -type f)
step_ok "Security checks passed"

header "Naming Convention"

while IFS= read -r file; do
  NAMES=$(grep "^  name:" "$file" | awk '{print $2}')
  while IFS= read -r name; do
    if [[ -n "$name" && ! "$name" =~ ^demo- ]]; then
      step_fail "Resource name '$name' in $file doesn't follow 'demo-' prefix convention"
    fi
  done <<< "$NAMES"
done < <(find "$INFRA_DIR/crossplane/resources" -name '*.yaml' -type f)
step_ok "Naming convention check passed"

header "Dry-Run (requires cluster connection)"

if kubectl cluster-info &>/dev/null; then
  DRYRUN_FAIL=0
  while IFS= read -r file; do
    if ! kubectl apply --dry-run=server -f "$file" &>/dev/null; then
      step_fail "Dry-run failed: $file"
      kubectl apply --dry-run=server -f "$file" 2>&1 | tail -3
      DRYRUN_FAIL=1
    fi
  done < <(find "$INFRA_DIR/crossplane/resources" -name '*.yaml' -type f)

  if [[ $DRYRUN_FAIL -eq 0 ]]; then
    step_ok "All resources passed dry-run"
  fi
else
  step_info "No cluster connection — skipping dry-run"
fi

header "Results"

if [[ $ERRORS -gt 0 ]]; then
  step_fail "$ERRORS error(s) found — fix before pushing"
  exit 1
else
  step_ok "All checks passed!"
fi