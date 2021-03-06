#!/bin/bash

set -euxo pipefail

GITDIR='/opt/git/github/K8S-playground'
WORKFOLDER='/opt/k8s_bootstrap'

if [ ! -d "$WORKFOLDER" ]
then
	mkdir -p "$WORKFOLDER"
fi

cd ${WORKFOLDER} ||\
echo "echo 'Can't change directory to bootstrap workfolder, exiting.'; kill -9 $$" | bash

#Generate management ssh key
if [ ! -d \""${WORKFOLDER}"/ssh\" ]
then
	mkdir -p "$WORKFOLDER"/ssh
	ssh-keygen -C root\@"${HOSTNAME}" -b 2048 -t rsa -f "${WORKFOLDER}"/ssh/k8s-management -q -N ""
	cp "${WORKFOLDER}"/ssh/k8s-management* ~/.ssh/ && chmod 0600 ~/.ssh/k8s-management*
fi

#The cfssl and cfssljson command line utilities will be used to provision a PKI Infrastructure and generate TLS certificates.
if [ ! -f /usr/local/bin/cfssl ];
then
	wget -q --timestamping \
  https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/linux/cfssl \
  https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/linux/cfssljson
	chmod +x cfssl cfssljson
	mv cfssl cfssljson /usr/local/bin/\
	&& echo "cfssl successfully installed"
else
	echo "cfssl already installed"
fi

#Setup DNS/SSH over cluster nodes
for NODE in $(awk -F ' ' '{print $2}' "${GITDIR}"/config/k8s_nodes);
do
	if [ ! "$(grep "${NODE}" /etc/hosts )" ];
	then
		ADDNODE=$(grep "${NODE}" "${GITDIR}"/config/k8s_nodes)
		echo "${ADDNODE}" >> /etc/hosts
	fi
	ssh-copy-id -o StrictHostKeyChecking=no -i ~/.ssh/k8s-management "root@${NODE}" > /dev/null 2>&1\
	&& scp "${GITDIR}"/config/k8s_nodes "${GITDIR}"/scripts/setup-dns.sh ${NODE}:/tmp > /dev/null 2>&1\
	&& ssh ${NODE} "bash /tmp/setup-dns.sh"
done

#Get kubectl
if [ ! -f "/usr/local/bin/kubectl" ]
then
	echo "Attempting to get kubectl."
	wget -q https://storage.googleapis.com/kubernetes-release/release/v1.15.3/bin/linux/amd64/kubectl
	chmod +x kubectl
	sudo mv kubectl /usr/local/bin/\
	&& echo "Ok"
else
	echo "Kubectl already installed"
fi

###Certs time!
#Certificate Authority
CERTS_DIR="$WORKFOLDER/certs"
mkdir -p ${CERTS_DIR}
cp -r ${GITDIR}/certs/* ${CERTS_DIR}/

cd ${CERTS_DIR}/CA\
&& cfssl gencert -initca ca-csr.json | cfssljson -bare ca

#Admin client certs
cd ${CERTS_DIR}/admin\
&& cfssl gencert \
  -ca=${CERTS_DIR}/CA/ca.pem \
  -ca-key=${CERTS_DIR}/CA/ca-key.pem \
  -config=${CERTS_DIR}/CA/ca-config.json \
  -profile=kubernetes \
  admin-csr.json | cfssljson -bare admin

#Kubelet client certificates
mkdir -p ${CERTS_DIR}/kubelet\
&& cd ${CERTS_DIR}/kubelet\
&& for NODE in $(awk -F ' ' '{print $2}' "$GITDIR"/config/k8s_nodes);
do
	cat > ${CERTS_DIR}/kubelet/${NODE}-csr.json <<EOF
{
  "CN": "system:node:${NODE}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "RU",
      "L": "Moscow",
      "O": "system:nodes",
      "OU": "Kubernetes",
      "ST": "Moscow"
    }
  ]
}
EOF

NODE_IPADDR=$(awk -F ' ' '/'${NODE}'/ {print $1}' "$GITDIR"/config/k8s_nodes)
cfssl gencert \
  -ca=${CERTS_DIR}/CA/ca.pem \
  -ca-key=${CERTS_DIR}/CA/ca-key.pem \
  -config=${CERTS_DIR}/CA/ca-config.json \
  -hostname=${NODE},${NODE_IPADDR} \
  -profile=kubernetes \
  ${NODE}-csr.json | cfssljson -bare ${NODE}
done

#Controller Manager Client Certificate
cd ${CERTS_DIR}/controller-manager\
&& cfssl gencert \
  -ca=${CERTS_DIR}/CA/ca.pem \
  -ca-key=${CERTS_DIR}/CA/ca-key.pem \
  -config=${CERTS_DIR}/CA/ca-config.json \
  -profile=kubernetes \
  kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager

#Kube scheduler certificate
cd ${CERTS_DIR}/kube-scheduler\
&& cfssl gencert \
  -ca=${CERTS_DIR}/CA/ca.pem \
  -ca-key=${CERTS_DIR}/CA/ca-key.pem \
  -config=${CERTS_DIR}/CA/ca-config.json \
  -profile=kubernetes \
  kube-scheduler-csr.json | cfssljson -bare kube-scheduler

#Kube proxy certificate
cd ${CERTS_DIR}/kube-proxy\
&& cfssl gencert \
  -ca=${CERTS_DIR}/CA/ca.pem \
  -ca-key=${CERTS_DIR}/CA/ca-key.pem \
  -config=${CERTS_DIR}/CA/ca-config.json \
  -profile=kubernetes \
  kube-proxy-csr.json | cfssljson -bare kube-proxy


#Kubernetes API server
cd ${CERTS_DIR}/kube-apiserver
KUBERNETES_PUBLIC_ADDRESS='10.245.0.1,10.33.0.1,10.200.0.1' #FIXME should be same for etcd
KUBERNETES_HOSTNAMES='kubernetes,vi7a.k8s.local,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,kubernetes.svc.cluster.local'

cfssl gencert \
  -ca=${CERTS_DIR}/CA/ca.pem \
  -ca-key=${CERTS_DIR}/CA/ca-key.pem \
  -config=${CERTS_DIR}/CA/ca-config.json \
  -hostname=${KUBERNETES_PUBLIC_ADDRESS},127.0.0.1,${KUBERNETES_HOSTNAMES} \
  -profile=kubernetes \
  kube-apiserver-csr.json | cfssljson -bare kubernetes

#Service accounts keypair
cd ${CERTS_DIR}/service-accounts

cfssl gencert \
  -ca=${CERTS_DIR}/CA/ca.pem \
  -ca-key=${CERTS_DIR}/CA/ca-key.pem \
  -config=${CERTS_DIR}/CA/ca-config.json \
  -profile=kubernetes \
  kube-service-accounts-csr.json | cfssljson -bare service-account

#Distribute keys across cluster (server/worker)
for NODE in $(awk -F ' ' '{print $2}' "${GITDIR}"/config/k8s_nodes);
do
	scp ${CERTS_DIR}/CA/ca.pem ${CERTS_DIR}/kubelet/${NODE}-key.pem ${CERTS_DIR}/kubelet/${NODE}.pem ${NODE}:~/
done

#Generate config for worker nodes
CONF_DIR="${WORKFOLDER}/conf"
mkdir -p ${CONF_DIR}

for NODE in $(awk -F ' ' '{print $2}' "$GITDIR"/config/k8s_nodes); do
  /usr/local/bin/kubectl config set-cluster vi7-kubernetes \
    --certificate-authority=${CERTS_DIR}/CA/ca.pem \
    --embed-certs=true \
    --server=https://10.245.0.1:6443 \
    --kubeconfig=${CONF_DIR}/${NODE}.kubeconfig

  /usr/local/bin/kubectl config set-credentials system:node:${NODE} \
    --client-certificate=${CERTS_DIR}/kubelet/${NODE}.pem \
    --client-key=${CERTS_DIR}/kubelet/${NODE}-key.pem \
    --embed-certs=true \
    --kubeconfig=${CONF_DIR}/${NODE}.kubeconfig

  /usr/local/bin/kubectl config set-context default \
    --cluster=vi7-kubernetes \
    --user=system:node:${NODE} \
    --kubeconfig=${CONF_DIR}/${NODE}.kubeconfig

  /usr/local/bin/kubectl config use-context default --kubeconfig=${CONF_DIR}/${NODE}.kubeconfig
done

#Generate kube-proxy config
/usr/local/bin/kubectl config set-cluster vi7-kubernetes \
  --certificate-authority=${CERTS_DIR}/CA/ca.pem \
  --embed-certs=true \
  --server=https://10.245.0.1:6443 \
  --kubeconfig=${CONF_DIR}/kube-proxy.kubeconfig

/usr/local/bin/kubectl config set-credentials system:kube-proxy \
  --client-certificate=${CERTS_DIR}/kube-proxy/kube-proxy.pem \
  --client-key=${CERTS_DIR}/kube-proxy/kube-proxy-key.pem \
  --embed-certs=true \
  --kubeconfig=${CONF_DIR}/kube-proxy.kubeconfig

/usr/local/bin/kubectl config set-context default \
  --cluster=vi7-kubernetes \
  --user=system:kube-proxy \
  --kubeconfig=${CONF_DIR}/kube-proxy.kubeconfig

/usr/local/bin/kubectl config use-context default --kubeconfig=${CONF_DIR}/kube-proxy.kubeconfig

#Generate config for kube-controller-manager
/usr/local/bin/kubectl config set-cluster vi7-kubernetes \
    --certificate-authority=${CERTS_DIR}/CA/ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=${CONF_DIR}/kube-controller-manager.kubeconfig

/usr/local/bin/kubectl config set-credentials system:kube-controller-manager \
    --client-certificate=${CERTS_DIR}/controller-manager/kube-controller-manager.pem \
    --client-key=${CERTS_DIR}/controller-manager/kube-controller-manager-key.pem \
    --embed-certs=true \
    --kubeconfig=${CONF_DIR}/kube-controller-manager.kubeconfig

/usr/local/bin/kubectl config set-context default \
    --cluster=vi7-kubernetes \
    --user=system:kube-controller-manager \
    --kubeconfig=${CONF_DIR}/kube-controller-manager.kubeconfig

/usr/local/bin/kubectl config use-context default --kubeconfig=${CONF_DIR}/kube-controller-manager.kubeconfig

#Generate kube-scheduler config
/usr/local/bin/kubectl config set-cluster vi7-kubernetes \
    --certificate-authority=${CERTS_DIR}/CA/ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=${CONF_DIR}/kube-scheduler.kubeconfig

/usr/local/bin/kubectl config set-credentials system:kube-scheduler \
    --client-certificate=${CERTS_DIR}/kube-scheduler/kube-scheduler.pem \
    --client-key=${CERTS_DIR}/kube-scheduler/kube-scheduler-key.pem \
    --embed-certs=true \
    --kubeconfig=${CONF_DIR}/kube-scheduler.kubeconfig

/usr/local/bin/kubectl config set-context default \
    --cluster=vi7-kubernetes \
    --user=system:kube-scheduler \
    --kubeconfig=${CONF_DIR}/kube-scheduler.kubeconfig

/usr/local/bin/kubectl config use-context default --kubeconfig=${CONF_DIR}/kube-scheduler.kubeconfig

#Generate kube-admin config
/usr/local/bin/kubectl config set-cluster vi7-kubernetes \
    --certificate-authority=${CERTS_DIR}/CA/ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=${CONF_DIR}/admin.kubeconfig

/usr/local/bin/kubectl config set-credentials admin \
    --client-certificate=${CERTS_DIR}/admin/admin.pem \
    --client-key=${CERTS_DIR}/admin/admin-key.pem \
    --embed-certs=true \
    --kubeconfig=${CONF_DIR}/admin.kubeconfig

/usr/local/bin/kubectl config set-context default \
    --cluster=vi7-kubernetes \
    --user=admin \
    --kubeconfig=${CONF_DIR}/admin.kubeconfig

/usr/local/bin/kubectl config use-context default --kubeconfig=${CONF_DIR}/admin.kubeconfig

#Distribute configs across cluster (server/worker)
for NODE in $(awk -F ' ' '{print $2}' "${GITDIR}"/config/k8s_nodes);
do
	scp ${CONF_DIR}/${NODE}.kubeconfig ${CONF_DIR}/kube-proxy.kubeconfig ${NODE}:~/
done

###Generate encryption key
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

cat > ${WORKFOLDER}/encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF

#Setup ETCD cluster on controller nodes (Just 1 controller at start)
KUBECONFDIR=${WORKFOLDER}/config
mkdir -p ${KUBECONFDIR}
cd ${WORKFOLDER}
cp -r ${GITDIR}/config/* ${KUBECONFDIR}/

ETCD_NAME=$(hostname -s)
CONTROLLER_IP='10.245.0.1' #In my case just 1 controller

wget -q --timestamping \
"https://github.com/etcd-io/etcd/releases/download/v3.4.0/etcd-v3.4.0-linux-amd64.tar.gz"
tar -xf etcd-v3.4.0-linux-amd64.tar.gz 2>&1 > /dev/null
mv etcd-v3.4.0-linux-amd64/etcd* /usr/local/bin/
mkdir -p /etc/etcd /var/lib/etcdz
cp ${CERTS_DIR}/CA/ca.pem ${CERTS_DIR}/kube-apiserver/kubernetes.pem ${CERTS_DIR}/kube-apiserver/kubernetes-key.pem /etc/etcd/
sed -ri 's#ETCD_NAME#'${ETCD_NAME}'#g' ${KUBECONFDIR}/etcd.systemd.unit
sed -ri 's#CONTROLLER_IP#'${CONTROLLER_IP}'#g' ${KUBECONFDIR}/etcd.systemd.unit
cp ${KUBECONFDIR}/etcd.systemd.unit /etc/systemd/system/etcd.service

systemctl daemon-reload
systemctl enable etcd
systemctl start etcd
sleep 10

cd ${WORKFOLDER}
###Setup control pane
mkdir -p /etc/kubernetes/config
#Get kubernetes binaries
wget -q --timestamping "https://dl.k8s.io/v1.21.2/kubernetes-server-linux-amd64.tar.gz"

tar -xvf kubernetes-server-linux-amd64.tar.gz
cp kubernetes/server/bin/kube-apiserver .
cp kubernetes/server/bin/kube-controller-manager .
cp kubernetes/server/bin/kube-scheduler .
cp kubernetes/server/bin/kubectl .

chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
cp kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/

#Distribute admin configs
cp ${CONF_DIR}/admin.kubeconfig ~/.kube/config
#kubectl insecure-skip-tls-verify

#Distribute controller certs
mkdir -p /var/lib/kubernetes/
cp ${CERTS_DIR}/CA/ca.pem ${CERTS_DIR}/CA/ca-key.pem ${CERTS_DIR}/kube-apiserver/kubernetes-key.pem ${CERTS_DIR}/kube-apiserver/kubernetes.pem \
	${CERTS_DIR}/service-accounts/service-account-key.pem ${CERTS_DIR}/service-accounts/service-account.pem \
  encryption-config.yaml /var/lib/kubernetes/

sed -ri 's#CONTROLLER_IP#'${CONTROLLER_IP}'#g' ${KUBECONFDIR}/kube-apiserver.systemd.unit
cp ${KUBECONFDIR}/kube-apiserver.systemd.unit /etc/systemd/system/kube-apiserver.service

#Setup controller manager
cp ${CONF_DIR}/kube-controller-manager.kubeconfig /var/lib/kubernetes/
cp ${KUBECONFDIR}/kube-controller-manager.systemd.unit /etc/systemd/system/kube-controller-manager.service

#Setup kubernetes scheduler
cp ${CONF_DIR}/kube-scheduler.kubeconfig /var/lib/kubernetes/
cp ${CONF_DIR}/kube-scheduler.kubeconfig /etc/kubernetes/config/kube-scheduler.kubeconfig
cp ${KUBECONFDIR}/kube-scheduler.yaml /etc/kubernetes/config/kube-scheduler.yaml
cp ${KUBECONFDIR}/kube-scheduler.systemd.unit /etc/systemd/system/kube-scheduler.service

#Start controller services
systemctl daemon-reload
systemctl enable kube-apiserver kube-controller-manager kube-scheduler
systemctl start kube-apiserver kube-controller-manager kube-scheduler

sleep 10

#Create kubelet/apiserver clusterroles
/usr/local/bin/kubectl apply -f ${KUBECONFDIR}/role/apiserver-to-kubelet.yaml

#Bootstrapping Worker nodes
for NODE in $(awk -F ' ' '{print $2}' "${GITDIR}"/config/k8s_nodes);
do
	scp ${GITDIR}/scripts/prepare-worker.sh\
			${KUBECONFDIR}/kubelet-config.yaml\
			${KUBECONFDIR}/cni*\
	    ${KUBECONFDIR}/kubelet-service.systemd.unit\
	    ${KUBECONFDIR}/kube-proxy-config.yaml\
	    ${KUBECONFDIR}/kube-proxy.systemd.unit\
	    ${CONF_DIR}/kube-proxy.kubeconfig\
	    ${KUBECONFDIR}/containerd.config.toml\
	    ${KUBECONFDIR}/containerd.systemd.unit\
	    ${NODE}:~/\
	 && ssh ${NODE} "bash ~/prepare-worker.sh"
done

CLUSTERCIDR=10.200.0.0/16 APISERVER=https://10.245.0.1:6443 sh -c \
'curl https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/generic-kuberouter-all-features.yaml -o - | sed -e "s;%APISERVER%;$APISERVER;g" -e "s;%CLUSTERCIDR%;$CLUSTERCIDR;g"' | kubectl apply -f -

###Deploy DNS
kubectl apply -f ${GITDIR}/addons/dns/coredns.yaml

###Deploy keycloak
kubectl apply -f ${GITDIR}/addons/keycloak/keycloak.yaml

###Deploy k8s-dashboard
kubectl apply -f ${GITDIR}/addons/k8s-dashboard

###Deploy oauth2-proxy
kubectl apply -f ${GITDIR}/addons/oauth2-proxy/oauth2-proxy.yaml