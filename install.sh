#!/bin/bash

base=ttgcp1
env=production
user=$(gcloud config get-value account)
labels="env=$env,purpose=$base,user=${user%@*}"

## GCP projects
# Create projects for dns, kms and everything else
for ext in cluster dns kms; do \
  gcloud projects create "$base-$ext" --labels="$labels" \
    --name="Kubernetes $ext" --no-enable-cloud-apis; \
done

# Must have a valid billing account
billing=$(gcloud beta billing accounts list \
    --format='value(name)' --filter=open=true | head -n 1)

for ext in cluster dns kms; do \
  gcloud beta billing projects link "$base-$ext" --billing-account="$billing"; \
done

# Enable the necessary GCP APIs in each project
gcloud services enable --project="$base-cluster" {container,iamcredentials}.googleapis.com
gcloud services enable --project="$base-dns" dns.googleapis.com
gcloud services enable --project="$base-kms" cloudkms.googleapis.com

## Service accounts
# Name of the SA
node_sa_name="Kubernetes $base node"
gcloud iam service-accounts create "sa-node-$base" \
  --display-name="$node_sa_name" --project="$base-cluster"
node_sa_email=$(gcloud iam service-accounts list --project="$base-cluster" \
  --format='value(email)' --filter="displayName:$node_sa_name")
cert_sa_name="Kubernetes $base cert-mananger"
gcloud iam service-accounts create "sa-cert-$base" \
  --display-name="$cert_sa_name" --project="$base-cluster"
cert_sa_email=$(gcloud iam service-accounts list --project="$base-cluster" \
  --format='value(email)' --filter="displayName:$cert_sa_name")
edns_sa_name="Kubernetes $base external-dns"
gcloud iam service-accounts create "sa-edns-$base" \
  --display-name="$edns_sa_name" --project="$base-cluster"
edns_sa_email=$(gcloud iam service-accounts list --project="$base-cluster" \
  --format='value(email)' --filter="displayName:$edns_sa_name")

# Bind the needed IAM roles from the appropriate project to each service account.
# Bind the logging and metrics roles to the node service account.
for role in monitoring.metricWriter monitoring.viewer logging.logWriter; do \
  gcloud projects add-iam-policy-binding "$base-cluster" \
    --member="serviceAccount:$node_sa_email" --role="roles/$role"; \
done

# Bind the DNS admin role in the DNS project to the cert-manager and external-dns service accounts
for sa_email in "$cert_sa_email" "$edns_sa_email"; do \
  gcloud projects add-iam-policy-binding "$base-dns" \
    --member="serviceAccount:$sa_email" --role=roles/dns.admin; \
done

# Bind the cert-manager and external-dns GCP service accounts to their respective Kubernetes workload
gcloud iam service-accounts add-iam-policy-binding "$cert_sa_email" \
  --member="serviceAccount:$base-cluster.svc.id.goog[cert-manager/cert-manager]" \
  --role=roles/iam.workloadIdentityUser --project=$base-cluster
gcloud iam service-accounts add-iam-policy-binding "$edns_sa_email" \
  --member="serviceAccount:$base-cluster.svc.id.goog[external-dns/external-dns]" \
  --role=roles/iam.workloadIdentityUser --project=$base-cluster

## DNS
# Specify the domain name
domain=mxrty.com.
zon=${domain%.}; zone=${zon//./-}
gcloud dns managed-zones create "$zone" --dns-name="$domain" \
  --description="$base $domain DNS" --dnssec-state=on --visibility=public \
  --labels="$labels" --project="$base-dns"

# Get the nameservers for the domain.
#gcloud dns managed-zones describe "$zone" \
#  --format='value(nameServers)' --project="$base-dns"
#
#The command below will output the DS record, i.e., DNSSEC configuration, you can provide your registrar.
#
#ksk=$(gcloud dns dns-keys list --zone=$zone --project="$base-dns" \
#  --filter=type=keySigning --format='value(id)' | head -n 1)
#gcloud dns dns-keys describe "$ksk" --zone="$zone" \
#   --format='value(ds_record())' --project="$base-dns"

## KMS
# Use Google Cloud KMS to encrypt Kubernetes secrets in the Kubernetes etcd database.
# Create a key ring and the key encryption key in the KMS project.
region=europe-west
gcloud kms keyrings create "ring-$base" --location="$region" --project="$base-kms"
gcloud kms keys create "key-$base" --keyring="ring-$base" --purpose=encryption \
  --labels="$labels" --location="$region" --project="$base-kms"

# Give the GKE service account in the cluster project access to the newly created key.
project_id=$(gcloud projects describe "$base-cluster" --format='value(projectNumber)')
gke_sa=service-$project_id@container-engine-robot.iam.gserviceaccount.com
gcloud kms keys add-iam-policy-binding "key-$base" --keyring="ring-$base" \
  --member="serviceAccount:$gke_sa" --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --location="$region" --project="$base-kms"

## VPC
# Create a dedicated virtual private cloud (VPC) network for the Kubernetes cluster,
# isolating it from both the Internet and any other resources in the project
gcloud compute networks create "net-$base" \
  --description="Kubernetes network $base" \
  --subnet-mode=custom --project="$base-cluster"

# Create the subnet for our cluster nodes, pods, and services
gcloud compute networks subnets create "subnet-$base" \
  --network="net-$base" --range=10.0.0.0/22 \
  --description="Kubernetes subnet $base" \
  --enable-private-ip-google-access --purpose=PRIVATE \
  --region="$region" --project="$base-cluster" \
  --secondary-range="svc=10.0.16.0/20,pod=10.12.0.0/14"

# Create a NAT for subnet so workloads can access the Internet
gcloud compute routers create "router-$base" --network="net-$base" \
  --description="NAT router" --region="$region" --project="$base-cluster"

# Complete the VPC setup by creating the NAT.
gcloud compute routers nats create "nat-$base" --router="router-$base" \
  --auto-allocate-nat-external-ips --region="$region" \
  --nat-custom-subnet-ip-ranges="subnet-$base,subnet-$base:svc,subnet-$base:pod" \
  --project="$base-cluster"

## GKE Cluster
# If you will need to access the Kubernetes API, e.g., using kubectl, from other
# systems, you can add additional networks by adding additional, comma-delimited
# CIDR blocks to the --master-authorized-networks command-line option argument
key_id=projects/$base-kms/locations/$region/keyRings/ring-$base/cryptoKeys/key-$base
mcidr=172.19.13.32/28
gcloud beta container clusters create "gke-$base" \
  --enable-autorepair --enable-autoupgrade \
  --metadata disable-legacy-endpoints=true \
  --labels="$labels" --node-labels="$labels" \
  --tags="kubernetes-worker,$base,$env,${user%@*}" \
  --enable-autoscaling --service-account="$node_sa_email" \
  --workload-metadata-from-node=GKE_METADATA_SERVER \
  --shielded-integrity-monitoring --shielded-secure-boot \
  --addons=HorizontalPodAutoscaling,NetworkPolicy,NodeLocalDNS \
  --database-encryption-key="$key_id" --no-enable-basic-auth \
  --enable-ip-alias --no-enable-legacy-authorization \
  --enable-network-policy --enable-shielded-nodes \
  --enable-stackdriver-kubernetes \
  --identity-namespace="$base-cluster.svc.id.goog" \
  --image-type=COS_CONTAINERD --no-issue-client-certificate \
  --machine-type=e2-standard-2 --max-nodes=3 --min-nodes=1 \
  --network="net-$base" --subnetwork="subnet-$base" \
  --release-channel=regular --enable-master-authorized-networks \
  --master-authorized-networks="$(curl -s https://icanhazip.com/)/32" \
  --enable-private-nodes --master-ipv4-cidr="$mcidr" \
  --maintenance-window-start=2000-01-01T22:00:00Z \
  --maintenance-window-end=2000-01-02T05:00:00Z \
  --maintenance-window-recurrence='FREQ=WEEKLY;BYDAY=SA,SU' \
  --region="$region" --project="$base-cluster"

# Get the Kubernetes cluster credentials and configure your local clients,
# including kubectl, to use them
gcloud container clusters get-credentials "gke-$base" \
  --region="$region" --project="$base-cluster"

# By default, GCP will not give you administrative access to the cluster you just created.
# Run the following command to give your GCP user administrative access to the GKE cluster.
kubectl create clusterrolebinding "cluster-admin-${user%@*}" \
  --clusterrole=cluster-admin --user="$user"

## ingress-nginx
# Before deploying ingress-nginx, we will create a GCP external IP address.
# This will allow the ingress-nginx controller service’s load balancer, and hence
# our services, to have a stable IP address across upgrades, migrations, etc.
gcloud compute addresses create "ip-nginx-$base" \
  --description="ingress-nginx service load balancer IP" \
  --network-tier=PREMIUM --region="$region" --project="$base-cluster"
ip=$(gcloud compute addresses describe "ip-nginx-$base" \
  --format='value(address)' --region="$region" --project="$base-cluster")

# ingress-nginx includes a validating webhook endpoint. This webhook registers itself with
# the Kubernetes API to validate all ingress resource specifications before they are used
# to create or update an ingress. This endpoint listens on port 8443 and must be
# accessible from the Kubernetes API server. Since the default firewall rules do not allow
# access from the API server to the nodes on port 8443, we add a firewall rule allowing it.
gcloud compute firewall-rules create "fw-nginx-$base" \
  --allow=tcp:8443 --description="ingress-nginx webhook" \
  --direction=INGRESS --network="net-$base" --priority=1000 \
  --source-ranges="$mcidr" --target-service-accounts="$node_sa_email" \
  --project="$base-cluster"

# To create the ingress-nginx resources, we use its standard YAML specifications, with one
# modification: explicitly setting the IP address of the ingress-nginx-controller load
# balancer service to the address we created above. We’ll use the yq command-line utility
# and some awk to add the loadBalancerIP property and then use kubectl to create the resources.
in_yaml=ingress-nginx.yaml
curl -sLo "$in_yaml" https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v0.34.1/deploy/static/provider/cloud/deploy.yaml
yq w \
  -d$(awk '/^kind:/ { kind = $2; d++ } \
    /^  name: ingress-nginx-controller$/ { if (kind == "Service") { print d-1; exit } }' "$in_yaml") \
  "$in_yaml" 'spec.loadBalancerIP' "$ip" | kubectl apply -f -
rm "$in_yaml"

## cert-manager
# We can use the standard installation instructions for cert-manager, with one addition:
# adding the workload identity annotation to the cert-manager service account. This is
# final step in linking the Kubernetes service account cert-manager runs as with the GCP
# service account we bound to the DNS admin role in the DNS project above, i.e., linking
# the GCP service account and the Kubernetes service account in GKE.
cm_yaml=cert-manager.yaml
curl -sLo "$cm_yaml" \
  https://github.com/jetstack/cert-manager/releases/download/v0.16.1/cert-manager.yaml
yq w \
  -d$(awk '/^kind:/ { kind = $2; d++ } \
    /^  name: cert-manager$/ { if (kind == "ServiceAccount") { print d-1; exit } }' "$cm_yaml") \
  "$cm_yaml" 'metadata.annotations."iam.gke.io/gcp-service-account"' "$cert_sa_email" | \
  kubectl apply -f -
rm "$cm_yaml"

## external-dns
# Add an external-dns namespace, add the workload identity annotation to the service
# account, and update the container args with values for our GCP project and domain
curl -sL https://raw.githubusercontent.com/atomist-blogs/iac-gke/main/k8s/external-dns.yaml | \
  sed -e "/gcp-service-account:/s/:.*/: $edns_sa_email/" \
    -e "/domain-filter=/s/=.*/=${domain%.}/" \
    -e "/google-project=/s/=.*/=$base-dns/" \
    -e "/txt-owner-id=/s/=.*/=$base/" | kubectl apply -f -


