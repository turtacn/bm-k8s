#!/bin/sh

set -x

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

##创建项目区分管理更好
#argocd proj create management


# Install Bare metal as a Service
argocd app sync tink-stack
until kubectl wait deployment -n tink-system tink-stack --for condition=Available=True --timeout=90s; do sleep 1; done



# Enable Cluster API
export TINKERBELL_IP="10.8.10.130"

mkdir -p ~/.cluster-api
cat > ~/.cluster-api/clusterctl.yaml <<EOF
providers:
  - name: "tinkerbell"
    url: "https://github.com/tinkerbell/cluster-api-provider-tinkerbell/releases/v0.4.0/infrastructure-components.yaml"
    type: "InfrastructureProvider"
EOF

export EXP_KUBEADM_BOOTSTRAP_FORMAT_IGNITION="true"
clusterctl init --infrastructure tinkerbell -v 5
until kubectl wait deployment -n capt-system capt-controller-manager --for condition=Available=True --timeout=90s; do sleep 1; done

# Hardware definitions
argocd app sync hardware
argocd app sync machine


# Deploying the workload cluster
# Now we are ready to initialize the Cluster API workflows that will end up creating the K8S Workload Cluster:

until argocd app sync workload-cluster;  do sleep 1; done
clusterctl get kubeconfig kub-poc -n tink-system > ~/kub-poc.kubeconfig

until kubectl --kubeconfig ~/kub-poc.kubeconfig get node -A; do sleep 1; done
until kubectl --kubeconfig ~/kub-poc.kubeconfig get node sut01-altra; do sleep 1; done
until kubectl --kubeconfig ~/kub-poc.kubeconfig get node sut02-altra; do sleep 1; done
until argocd app sync workload-cluster;  do sleep 1; done
clusterctl get kubeconfig kub-poc -n tink-system > ~/kub-poc.kubeconfig

until kubectl --kubeconfig ~/kub-poc.kubeconfig get node -A; do sleep 1; done
until kubectl --kubeconfig ~/kub-poc.kubeconfig get node sut01-altra; do sleep 1; done
until kubectl --kubeconfig ~/kub-poc.kubeconfig get node sut02-altra; do sleep 1; done

# Adding the workload cluster in ArgoCD
argocd cluster add kub-poc-admin@kub-poc \
   --kubeconfig ~/kub-poc.kubeconfig \
   --server localhost:8080 \
   --insecure --yes

argocd app create workload-cluster-apps \
    --repo git@github.com:turtacn/bm-k8s.git \
    --path applications/workload --dest-namespace argo-cd \
    --dest-server https://kubernetes.default.svc \
    --revision "dev" --sync-policy automated

argocd app sync bird
until kubectl get CiliumLoadBalancerIPPool --kubeconfig ~/kub-poc.kubeconfig || (argocd app sync cilium-manifests && argocd app sync cilium-kub-poc); do sleep 1; done

# Storage Configuration
kubectl --kubeconfig ~/kub-poc.kubeconfig patch node sut01-altra -p '{"spec":{"taints":[]}}' || true

argocd app sync rook-ceph-operator
until kubectl --kubeconfig ~/kub-poc.kubeconfig wait deployment -n rook-ceph rook-ceph-operator --for condition=Available=True --timeout=90s; do sleep 1; done

KUBECONFIG=~/kub-poc.kubeconfig kubectl node-shell sut01-altra -- sh -c 'export DISK="/dev/nvme1n1" && echo "w" | fdisk $DISK && sgdisk --zap-all $DISK && blkdiscard $DISK || sudo dd if=/dev/zero of="$DISK" bs=1M count=100 oflag=direct,dsync && partprobe $DISK && rm -rf /var/lib/rook'

KUBECONFIG=~/kub-poc.kubeconfig kubectl node-shell sut02-altra -- sh -c 'export DISK="/dev/nvme1n1" && echo "w" | fdisk $DISK && sgdisk --zap-all $DISK && blkdiscard $DISK || sudo dd if=/dev/zero of="$DISK" bs=1M count=100 oflag=direct,dsync && partprobe $DISK && rm -rf /var/lib/rook'

argocd app sync rook-ceph-cluster

until kubectl  --kubeconfig ~/kub-poc.kubeconfig -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status; do sleep 1; done