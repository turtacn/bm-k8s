#!/bin/sh

# step 0 adaptive for killercoda
cp /usr/local/bin/kubectl ./
rm -rf /usr/local/bin/helm

k3s-uninstall.sh
cp ./kubectl /usr/local/bin/

# Determining the architecture
ARCH=$(dpkg-architecture -q DEB_BUILD_ARCH)

# Grabbing k3d
wget https://github.com/k3d-io/k3d/releases/download/v5.5.1/k3d-linux-${ARCH} -O k3d
chmod a+x k3d
mv k3d /usr/local/bin/

# Helm, the package manager for K8s
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# ArgoCD for Continuous Delivery
wget https://github.com/argoproj/argo-cd/releases/download/v2.6.8/argocd-linux-${ARCH} -O argocd
chmod a+x argocd
mv argocd /usr/local/bin/

# Clusterctl for Cluster API
wget https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.4.2/clusterctl-linux-${ARCH} -O clusterctl
chmod a+x clusterctl
mv clusterctl /usr/local/bin/


# With k3d, we’ll set up our K8S Management Cluster. A few pointers:
# Tinkerbell’s Boots needs the load balancer off.
# We’ll need host networking (again, credit to Boots) and host pid mode.
k3d cluster create --network host --no-lb --k3s-arg "--disable=traefik,servicelb" \
--k3s-arg "--kube-apiserver-arg=feature-gates=MixedProtocolLBService=true" \
--host-pid-mode

mkdir -p ~/.kube/
k3d kubeconfig get -a >~/.kube/config
until kubectl wait --for=condition=Ready nodes --all --timeout=600s; do sleep 1; done

# Helm charts for various services
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add argo-cd https://argoproj.github.io/argo-helm
helm repo add kube-vip https://kube-vip.github.io/helm-charts/
helm repo update

# Additional helm commands for setting up services
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version 4.5.2 --namespace ingress-nginx \
  --create-namespace \
  -f config/management/ingress-nginx/values.yaml -v 6
until kubectl wait deployment -n ingress-nginx ingress-nginx-controller --for condition=Available=True --timeout=90s; do sleep 1; done

helm upgrade --install kube-vip kube-vip/kube-vip \
  --namespace kube-vip --create-namespace \
  -f config/management/ingress-nginx/kube-vip-values.yaml -v 6

helm upgrade --install argo-cd \
  --create-namespace --namespace argo-cd \
  -f config/management/argocd/values.yaml argo-cd/argo-cd
until kubectl wait deployment -n argo-cd argo-cd-argocd-server --for condition=Available=True --timeout=90s; do sleep 1; done
until kubectl wait deployment -n argo-cd argo-cd-argocd-applicationset-controller --for condition=Available=True --timeout=90s; do sleep 1; done
until kubectl wait deployment -n argo-cd argo-cd-argocd-repo-server --for condition=Available=True --timeout=90s; do sleep 1; done

kubectl port-forward service/argo-cd-argocd-server  8080:80 -n argo-cd &

pass=$(kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo $pass

argocd login localhost:8080 --username admin --password $pass --insecure

argocd repo add git@github.com:turtacn/bm-k8s.git --ssh-private-key-path ~/.ssh/id_rsa
argocd app create management-apps \
    --repo git@github.com:turtacn/bm-k8s.git \
    --path applications/management --dest-namespace argo-cd \
    --dest-server https://kubernetes.default.svc \
    --revision "dev" --sync-policy automated



argocd app sync management-apps
argocd app get management-apps --hard-refresh

argocd app sync tink-stack
until kubectl wait deployment -n tink-system tink-stack --for condition=Available=True --timeout=90s; do sleep 1; done
