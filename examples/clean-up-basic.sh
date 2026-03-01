#!/bin/bash
# clean-up-basic.sh
#
# Removes all resources created by csm-demo-script-basic.sh

export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
export REGION="europe-north2"
export VPC_NAME="csm-vpc-basic"
export SUBNET_NAME="csm-subnet-basic"
export CLUSTER_NAME="csm-autopilot-cluster"
export NAMESPACE="csm-demo-basic"
export CA_POOL_NAME="csm-ca-pool-basic"
export MEMBERSHIP_NAME="${CLUSTER_NAME}-membership"
export SERVER_TLS_POLICY="server-mtls-policy"
export CLIENT_TLS_POLICY="client-mtls-policy"

echo "=========================================="
echo "🧹 Starting Full Cleanup of CSM Basic Demo"
echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "=========================================="

echo "[1/8] Deleting Kubernetes Namespace..."
if gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION" >/dev/null 2>&1; then
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
fi

echo "[2/8] Deleting Global Security Policies..."
gcloud network-services endpoint-policies delete greeter-endpoint-policy --location=global --quiet || true
gcloud network-security server-tls-policies delete "$SERVER_TLS_POLICY" --location=global --quiet || true
gcloud network-security client-tls-policies delete "$CLIENT_TLS_POLICY" --location=global --quiet || true

echo "[3/8] Unregistering Fleet Membership..."
gcloud container fleet memberships delete "$MEMBERSHIP_NAME" --location="$REGION" --quiet || true

echo "[4/8] Deleting GKE Cluster..."
gcloud container clusters delete "$CLUSTER_NAME" --region="$REGION" --quiet || true

echo "[5/8] Deleting Private CA Resources..."
# Roots must be disabled and deleted before the pool
ROOTS=$(gcloud privateca roots list --pool="$CA_POOL_NAME" --location="$REGION" --format="value(name)")
for full_root_path in $ROOTS; do
    # Extract just the CA name from the full path
    root=$(basename "$full_root_path")
    echo "Disabling and deleting CA: $root"
    gcloud privateca roots disable "$root" --pool="$CA_POOL_NAME" --location="$REGION" --quiet || true
    gcloud privateca roots delete "$root" --pool="$CA_POOL_NAME" --location="$REGION" --ignore-active-certificates --quiet || true
done
# Note: The pool cannot be deleted if there are CAs in the "soft deleted" state (which lasts 30 days).
echo "Attempting to delete CA pool (may fail if CAs are soft-deleted)..."
gcloud privateca pools delete "$CA_POOL_NAME" --location="$REGION" --quiet || true

echo "[6/8] Deleting Network Infrastructure..."
# Delete implicit firewall rules created by Gateway API controller
echo "Deleting auto-generated firewall rules on VPC $VPC_NAME..."
gcloud compute firewall-rules list --filter="network:$VPC_NAME" --format="value(name)" | xargs -r gcloud compute firewall-rules delete --quiet || true

gcloud compute networks subnets delete "$SUBNET_NAME" --region="$REGION" --quiet || true
gcloud compute networks delete "$VPC_NAME" --quiet || true

echo "[7/8] Removing IAM Policy Bindings..."
# GKE Service Agent bindings
gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
    --role="roles/privateca.certificateRequester" \
    --condition="None" >/dev/null 2>&1 || true

gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
    --role="roles/compute.securityAdmin" \
    --condition="None" >/dev/null 2>&1 || true

gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
    --role="roles/compute.networkAdmin" \
    --condition="None" >/dev/null 2>&1 || true

# CSM Service Agent bindings
gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com" \
    --role="roles/anthosservicemesh.serviceAgent" \
    --condition="None" >/dev/null 2>&1 || true

gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com" \
    --role="roles/meshcontrolplane.serviceAgent" \
    --condition="None" >/dev/null 2>&1 || true

gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com" \
    --role="roles/compute.securityAdmin" \
    --condition="None" >/dev/null 2>&1 || true

# Traffic Director bindings
gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="group:${PROJECT_ID}.svc.id.goog:/allAuthenticatedUsers/" \
    --role="roles/trafficdirector.client" \
    --condition="None" >/dev/null 2>&1 || true

echo "[8/8] Deleting local proto file..."
rm -f helloworld.proto

echo "=========================================="
echo "✅ Cleanup Complete!"
echo "=========================================="
