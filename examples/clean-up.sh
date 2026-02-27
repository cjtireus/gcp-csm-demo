#!/bin/bash
# clean-up.sh
#
# Cleans up the Cloud Service Mesh infrastructure created by csm-demo-script.sh,
# leaving the Private CA intact to ensure idempotency for future runs.

export PROJECT_ID=$(gcloud config get-value project)
export REGION="europe-north2"
export VPC_NAME="csm-demo-vpc"
export SUBNET_NAME="csm-demo-subnet"
export CLUSTER_NAME="csm-autopilot-cluster"
export MEMBERSHIP_NAME="csm-membership"
export NAMESPACE="csm-demo-ns"
export SERVER_TLS_POLICY="gamma-server-mtls-policy"
export CLIENT_TLS_POLICY="gamma-client-mtls-policy"
export PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

echo "=========================================="
echo "🧹 Starting Cleanup of CSM Infrastructure"
echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "=========================================="

echo "[1/6] Deleting Kubernetes Resources..."
if gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION" >/dev/null 2>&1; then
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
else
    echo "Cluster not found or unreachable, skipping Kubernetes cleanup."
fi

echo "[2/6] Deleting Global Security Policies..."
gcloud network-services endpoint-policies delete greeter-endpoint-policy --location=global --quiet || true
gcloud network-security server-tls-policies delete "$SERVER_TLS_POLICY" --location=global --quiet || true
gcloud network-security client-tls-policies delete "$CLIENT_TLS_POLICY" --location=global --quiet || true

echo "[3/6] Unregistering Fleet Membership..."
gcloud container fleet memberships delete "$MEMBERSHIP_NAME" --location="$REGION" --quiet || true

echo "[4/6] Deleting GKE Cluster..."
gcloud container clusters delete "$CLUSTER_NAME" --region="$REGION" --quiet || true

echo "[5/6] Deleting Network Infrastructure..."
gcloud compute networks subnets delete "$SUBNET_NAME" --region="$REGION" --quiet || true
gcloud compute networks delete "$VPC_NAME" --quiet || true

echo "[6/6] Removing IAM Policy Bindings (Project and CA Pool)..."
export CURRENT_USER=$(gcloud config get-value account)

# 1. Project level bindings
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="user:${CURRENT_USER}" \
    --role="roles/privateca.admin" \
    --condition="None" >/dev/null 2>&1 || true

gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com" \
    --role="roles/anthosservicemesh.serviceAgent" \
    --condition="None" >/dev/null 2>&1 || true

gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com" \
    --role="roles/meshcontrolplane.serviceAgent" \
    --condition="None" >/dev/null 2>&1 || true

gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
    --role="roles/container.serviceAgent" \
    --condition="None" >/dev/null 2>&1 || true

gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-meshdataplane.iam.gserviceaccount.com" \
    --role="roles/meshconfig.admin" \
    --condition="None" >/dev/null 2>&1 || true

gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${NAMESPACE}/sa/grpc-sa" \
    --role="roles/trafficdirector.client" \
    --condition="None" >/dev/null 2>&1 || true

# 2. CA Pool level bindings
if gcloud privateca pools describe "$CA_POOL_NAME" --location="$REGION" >/dev/null 2>&1; then
    gcloud privateca pools remove-iam-policy-binding "$CA_POOL_NAME" \
        --location="$REGION" \
        --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
        --role="roles/privateca.certificateRequester" >/dev/null 2>&1 || true

    gcloud privateca pools remove-iam-policy-binding "$CA_POOL_NAME" \
        --location="$REGION" \
        --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-meshdataplane.iam.gserviceaccount.com" \
        --role="roles/privateca.certificateRequester" >/dev/null 2>&1 || true

    gcloud privateca pools remove-iam-policy-binding "$CA_POOL_NAME" \
        --location="$REGION" \
        --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
        --role="roles/privateca.auditor" >/dev/null 2>&1 || true

    gcloud privateca pools remove-iam-policy-binding "$CA_POOL_NAME" \
        --location="$REGION" \
        --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-meshdataplane.iam.gserviceaccount.com" \
        --role="roles/privateca.auditor" >/dev/null 2>&1 || true

    gcloud privateca pools remove-iam-policy-binding "$CA_POOL_NAME" \
        --location="$REGION" \
        --role="roles/privateca.certificateRequester" \
        --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${NAMESPACE}/sa/grpc-sa" >/dev/null 2>&1 || true

    gcloud privateca pools remove-iam-policy-binding "$CA_POOL_NAME" \
        --location="$REGION" \
        --role="roles/privateca.certificateManager" \
        --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${NAMESPACE}/sa/grpc-sa" >/dev/null 2>&1 || true
fi

echo "=========================================="
echo "✅ Cleanup Complete! (Private CA was kept)"
echo "=========================================="
