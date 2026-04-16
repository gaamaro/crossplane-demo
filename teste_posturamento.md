# Testes de posturamento

**Teste 1 — Drift na AWS (Crossplane corrige):**
```bash
# Adiciona uma tag direto na AWS
aws ec2 create-tags --resources i-049c45231077a47b8 --tags Key=hacked,Value=true

# Espera ~1min e verifica se o Crossplane removeu
aws ec2 describe-tags --filters "Name=resource-id,Values=i-049c45231077a47b8" --no-cli-pager | grep -B1 -A4 hacked
```

**Teste 2 — Drift no cluster (ArgoCD corrige):**
```bash
# Muda a tag no recurso do cluster
kubectl patch instances.ec2.aws.upbound.io demo-instance-a --type merge -p '{"spec":{"forProvider":{"tags":{"Name":"HACKED"}}}}'

# Observa o ArgoCD reverter (~5s com selfHeal)
kubectl get instances.ec2.aws.upbound.io demo-instance-a -o jsonpath='{.spec.forProvider.tags.Name}' && echo
```

**Teste 3 — Deleta recurso na AWS (Crossplane recria):**
```bash
# Deleta o bucket direto na AWS
aws s3 rb s3://crossplane-demo-gaamaro

# Espera ~1min e verifica se recriou
aws s3 ls | grep crossplane-demo
```


