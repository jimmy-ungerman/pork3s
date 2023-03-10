# Cluster Applications

## Bootstrapping Applications

To get the cluster to function as intended, we need to deploy some apps in a specific order:
1. External-Secrets
2. Cert-Manager
3. Traefik
4. ArgoCD

### Deploy External-Secrets
Begin by deploying the External-Secrets namepsace and the chart for the external-secrets application. Then we can deploy the onepassword connector to utilize OnePassword for all of our secrets

```bash
kustomize build --enable-alpha-plugins kubernetes/apps/kube-system/external-secrets | kubectl apply -f -
kustomize build --enable-alpha-plugins kubernetes/apps/kube-system/external-secrets/stores | kubectl apply -f -
```

### Deploy Cert-Manager
After external-secrets is successfully deployed, we can deploy the rest of our apps using the secrets we have stored in our 1password valut.

```bash
kustomize build --enable-alpha-plugins kubernetes/apps/cert-manager | kubectl apply -f -
```

### Deploy Ingress-Nginx

```bash
kustomize build --enable-alpha-plugins kubernetes/apps/networking/ingress | kubectl apply -f -
```

### Deploy Argocd

```bash
kustomize build --enable-alpha-plugins kubernetes/apps/networking/traefik | kubectl apply -f -
```

### Deploy Rook-Ceph
Deploy Rook Ceph Cluster to allow for storage

```bash
kustomize build --enable-alpha-plugins kubernetes/apps/rook-ceph/operator/ | kubectl apply -f -
kustomize build --enable-alpha-plugins kubernetes/apps/rook-ceph/cluster/ | kubectl apply -f -
```

### Import the existing apps back into ArgoCD

```bash
k apply -f kubernetes/apps/kube-system/external-secrets/app.yaml
k apply -f kubernetes/apps/cert-manager/app.yaml
k apply -f kubernetes/apps/argocd/app.yaml