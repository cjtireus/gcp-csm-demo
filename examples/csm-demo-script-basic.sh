#!/bin/bash
# csm-demo-script-basic.sh
#
# Complete setup for a Proxyless gRPC Cloud Service Mesh (CSM)
# using Kubernetes Gateway API (GAMMA) on GKE Autopilot.

set -e

# ==========================================
# 1. Configuration
# ==========================================
export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
export REGION="europe-north2"
export VPC_NAME="csm-vpc-basic"
export SUBNET_NAME="csm-subnet-basic"
export CLUSTER_NAME="csm-autopilot-cluster"
export NAMESPACE="csm-demo-basic"
export CA_POOL_NAME="csm-ca-pool-basic"

echo "=========================================="
echo "🚀 Starting CSM Gateway API (GAMMA) Setup"
echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Namespace: $NAMESPACE"
echo "=========================================="

# ==========================================
# 2. Enable APIs
# ==========================================
echo "[Step 1] Enabling APIs..."
gcloud services enable \
    cloudresourcemanager.googleapis.com \
    compute.googleapis.com \
    container.googleapis.com \
    networkservices.googleapis.com \
    networksecurity.googleapis.com \
    certificatemanager.googleapis.com \
    privateca.googleapis.com \
    meshconfig.googleapis.com \
    gkehub.googleapis.com \
    trafficdirector.googleapis.com

# ==========================================
# 3. Service Identities & IAM Setup
# ==========================================
echo "[Step 2] Creating Service Identities and applying IAM bindings..."

# Create service identities
gcloud beta services identity create --service=meshconfig.googleapis.com --project="${PROJECT_ID}" >/dev/null 2>&1 || true
gcloud beta services identity create --service=trafficdirector.googleapis.com --project="${PROJECT_ID}" >/dev/null 2>&1 || true
gcloud beta services identity create --service=networkservices.googleapis.com --project="${PROJECT_ID}" >/dev/null 2>&1 || true
gcloud beta services identity create --service=networksecurity.googleapis.com --project="${PROJECT_ID}" >/dev/null 2>&1 || true

# GKE Service Agent bindings
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
    --role="roles/compute.securityAdmin" \
    --condition="None" >/dev/null

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
    --role="roles/compute.networkAdmin" \
    --condition="None" >/dev/null

# Cloud Service Mesh Service Agent bindings
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com" \
    --role="roles/anthosservicemesh.serviceAgent" \
    --condition="None" >/dev/null 2>&1 || true

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com" \
    --role="roles/meshcontrolplane.serviceAgent" \
    --condition="None" >/dev/null 2>&1 || true

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com" \
    --role="roles/compute.securityAdmin" \
    --condition="None" >/dev/null

# ==========================================
# 4. Networking
# ==========================================
echo "[Step 3] Creating VPC and Subnet..."
if ! gcloud compute networks describe "$VPC_NAME" >/dev/null 2>&1; then
    gcloud compute networks create "$VPC_NAME" --subnet-mode=custom
fi

if ! gcloud compute networks subnets describe "$SUBNET_NAME" --region="$REGION" >/dev/null 2>&1; then
    gcloud compute networks subnets create "$SUBNET_NAME" \
        --network="$VPC_NAME" \
        --region="$REGION" \
        --range="10.10.0.0/20" \
        --enable-private-ip-google-access
fi

# ==========================================
# 5. GKE Autopilot Cluster
# ==========================================
echo "[Step 4] Provisioning GKE Autopilot cluster..."
if ! gcloud container clusters describe "$CLUSTER_NAME" --region="$REGION" >/dev/null 2>&1; then
    gcloud container clusters create-auto "$CLUSTER_NAME" \
        --region="$REGION" \
        --network="$VPC_NAME" \
        --subnetwork="$SUBNET_NAME"
fi

gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION"

gcloud container clusters update "$CLUSTER_NAME" \
    --region="$REGION" \
    --enable-mesh-certificates

gcloud container clusters update "$CLUSTER_NAME" \
    --region="$REGION" \
    --gateway-api=standard

# ==========================================
# 6. Mesh Config & Fleet Registration
# ==========================================
echo "[Step 5] Registering to Fleet and enabling Mesh..."
MEMBERSHIP_NAME="${CLUSTER_NAME}-membership"
if ! gcloud container fleet memberships describe "$MEMBERSHIP_NAME" --location="$REGION" >/dev/null 2>&1; then
    gcloud container fleet memberships register "$MEMBERSHIP_NAME" \
        --gke-cluster="${REGION}/${CLUSTER_NAME}" \
        --enable-workload-identity
fi

gcloud container fleet mesh enable

gcloud alpha container fleet mesh update \
    --config-api=gateway \
    --memberships="$MEMBERSHIP_NAME" \
    --location="$REGION"

# ==========================================
# 7. Additional IAM Bindings
# ==========================================
echo "[Step 6] Applying additional IAM bindings for Workload Identity..."

# privateca.certificateRequester to GKE service agent
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
    --role="roles/privateca.certificateRequester" \
    --condition="None" >/dev/null

# trafficdirector.client to allAuthenticatedUsers
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="group:${PROJECT_ID}.svc.id.goog:/allAuthenticatedUsers/" \
    --role="roles/trafficdirector.client" \
    --condition="None" >/dev/null

# ==========================================
# 8. Private CA for mTLS
# ==========================================
echo "[Step 7] Configuring Private CA..."
if ! gcloud privateca pools describe "$CA_POOL_NAME" --location="$REGION" >/dev/null 2>&1; then
    gcloud privateca pools create "$CA_POOL_NAME" --location="$REGION" --tier="devops"
fi

if ! gcloud privateca roots list --pool="$CA_POOL_NAME" --location="$REGION" --format="value(name)" | grep -q "csm-root-ca"; then
    gcloud privateca roots create csm-root-ca \
        --pool="$CA_POOL_NAME" \
        --location="$REGION" \
        --subject="CN=csm-root, O=demo" \
        --auto-enable
fi

gcloud privateca pools add-iam-policy-binding "$CA_POOL_NAME" \
    --location="$REGION" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
    --role="roles/privateca.certificateRequester" >/dev/null

# ==========================================
# 9. Kubernetes Manifests
# ==========================================
echo "[Step 8] Applying Kubernetes manifests..."

# Install GRPCRoute CRD
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.1.0/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml

# Create Namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" \
    mesh.cloud.google.com/csm-injection=proxyless \
    mesh.cloud.google.com/managed-csm="true" --overwrite

# TrustConfig and WorkloadCertificateConfig
export CA_POOL_PATH="projects/${PROJECT_ID}/locations/${REGION}/caPools/${CA_POOL_NAME}"
cat <<EOF | kubectl apply -f -
apiVersion: security.cloud.google.com/v1
kind: TrustConfig
metadata:
  name: default
  namespace: $NAMESPACE
spec:
  trustStores:
  - trustDomain: "${PROJECT_ID}.svc.id.goog"
    trustAnchors:
    - certificateAuthorityServiceURI: "//privateca.googleapis.com/${CA_POOL_PATH}"
---
apiVersion: security.cloud.google.com/v1
kind: WorkloadCertificateConfig
metadata:
  name: default
  namespace: $NAMESPACE
spec:
  keyAlgorithm:
    rsa:
      modulusSize: 2048
  certificateAuthorityConfig:
    certificateAuthorityServiceConfig:
      endpointURI: //privateca.googleapis.com/${CA_POOL_PATH}
EOF

# Server and Client TLS Policies
export SERVER_TLS_POLICY="server-mtls-policy"
export CLIENT_TLS_POLICY="client-mtls-policy"

gcloud network-security server-tls-policies import "$SERVER_TLS_POLICY" \
    --location=global --source=- --quiet <<EOF
name: projects/${PROJECT_ID}/locations/global/serverTlsPolicies/${SERVER_TLS_POLICY}
mtlsPolicy:
  clientValidationCa:
  - certificateProviderInstance:
      pluginInstance: google_cloud_private_spiffe
serverCertificate:
  certificateProviderInstance:
    pluginInstance: google_cloud_private_spiffe
allowOpen: false
EOF

gcloud network-security client-tls-policies import "$CLIENT_TLS_POLICY" \
    --location=global --source=- --quiet <<EOF
name: projects/${PROJECT_ID}/locations/global/clientTlsPolicies/${CLIENT_TLS_POLICY}
clientCertificate:
  certificateProviderInstance:
    pluginInstance: google_cloud_private_spiffe
serverValidationCa:
- certificateProviderInstance:
    pluginInstance: google_cloud_private_spiffe
EOF

# Global Endpoint Policy
gcloud network-services endpoint-policies import greeter-endpoint-policy \
    --location=global --source=- --quiet <<EOF
name: projects/${PROJECT_ID}/locations/global/endpointPolicies/greeter-endpoint-policy
type: GRPC_SERVER
endpointMatcher:
  metadataLabelMatcher:
    metadataLabelMatchCriteria: MATCH_ALL
    metadataLabels:
      - labelName: app
        labelValue: greeter
serverTlsPolicy: projects/${PROJECT_ID}/locations/global/serverTlsPolicies/${SERVER_TLS_POLICY}
EOF

# Service and HTTPRoute (GAMMA)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: greeter-service
  namespace: $NAMESPACE
  labels:
    mesh.cloud.google.com/managed-csm: "true"
  annotations:
    networking.gke.io/server-tls-policy: projects/${PROJECT_ID}/locations/global/serverTlsPolicies/${SERVER_TLS_POLICY}
spec:
  selector:
    app: greeter
  ports:
  - name: grpc
    port: 50051
    targetPort: 50051
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: greeter-route
  namespace: $NAMESPACE
  annotations:
    networking.gke.io/client-tls-policy: projects/${PROJECT_ID}/locations/global/clientTlsPolicies/${CLIENT_TLS_POLICY}
spec:
  parentRefs:
  - name: greeter-service
    group: ""
    kind: Service
    port: 50051
  rules:
  - matches:
    - path: { type: PathPrefix, value: /helloworld.Greeter/ }
    backendRefs:
    - name: greeter-service
      port: 50051
EOF

# Workloads
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: greeter-server
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: greeter
  template:
    metadata:
      labels:
        app: greeter
      annotations:
        security.cloud.google.com/use-workload-certificates: ""
    spec:
      serviceAccountName: default
      containers:
      - name: server
        image: grpc/csm-o11y-example-java-server:v1.68.2
        ports:
        - containerPort: 50051
---
apiVersion: v1
kind: Pod
metadata:
  name: mesh-tester
  namespace: $NAMESPACE
  annotations:
    security.cloud.google.com/use-workload-certificates: ""
spec:
  serviceAccountName: default
  containers:
  - name: tester
    image: nicolaka/netshoot
    command: ["/bin/sh", "-c", "sleep 3600"]
EOF

echo "⏳ Waiting for Gateway CRDs and pods to be ready..."
# Wait for pods
kubectl wait --for=condition=Ready pod -l app=greeter -n $NAMESPACE --timeout=600s || echo "Timeout waiting for greeter server pod, maybe it failed to start..."
kubectl wait --for=condition=Ready pod/mesh-tester -n $NAMESPACE --timeout=600s || echo "Timeout waiting for mesh tester pod..."

# ==========================================
# 10. Validation
# ==========================================
echo "[Step 9] Validating connection..."

echo "⏳ Waiting for HTTPRoute to be accepted (max 60s)..."
kubectl wait --for=condition=Accepted httproute/greeter-route -n $NAMESPACE --timeout=60s || echo "Warning: HTTPRoute not accepted within timeout, proceeding anyway..."

SERVER_POD=$(kubectl get pod -l app=greeter -n $NAMESPACE -o jsonpath='{.items[0].metadata.name}')
echo "Verifying GRPC_XDS_BOOTSTRAP on Server ($SERVER_POD):"
kubectl exec "$SERVER_POD" -n "$NAMESPACE" -c server -- env | grep GRPC_XDS_BOOTSTRAP || true
echo "Printing td-grpc-bootstrap.json content:"
BOOTSTRAP_FILE=$(kubectl exec "$SERVER_POD" -n "$NAMESPACE" -c server -- printenv GRPC_XDS_BOOTSTRAP | tr -d '\r')
if [ -n "$BOOTSTRAP_FILE" ]; then
    kubectl exec "$SERVER_POD" -n "$NAMESPACE" -c server -- cat "$BOOTSTRAP_FILE" || true
else
    echo "GRPC_XDS_BOOTSTRAP not found."
fi

# Create proto file inside tester pod
cat <<EOF > helloworld.proto
syntax = "proto3";
package helloworld;
service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply) {}
}
message HelloRequest {
  string name = 1;
}
message HelloReply {
  string message = 1;
}
EOF
kubectl cp helloworld.proto "${NAMESPACE}/mesh-tester:/tmp/helloworld.proto"

echo "⏳ Waiting for xDS configuration to propagate (30s)..."
sleep 30

echo "Testing plaintext connection via xDS..."
# Note: --plaintext in grpcurl means 'no TLS in grpcurl itself', 
# but the gRPC library will use whatever xDS says (which might be TLS/mTLS).
set +e
PLAIN_RESULT=$(kubectl exec mesh-tester -n $NAMESPACE -c tester -- \
    grpcurl -v -max-time 15 --plaintext \
    -import-path /tmp -proto "/tmp/helloworld.proto" \
    -authority "greeter-service.${NAMESPACE}.svc.cluster.local" \
    -d '{"name": "xDS-Plaintext-Test"}' \
    xds:///greeter-service.${NAMESPACE}.svc.cluster.local:50051 \
    helloworld.Greeter/SayHello 2>&1)

if echo "$PLAIN_RESULT" | grep -q "Hello xDS-Plaintext-Test"; then
    echo "✅ Success: Plaintext xDS routing working."
else
    echo "❌ Failed: Plaintext xDS routing."
    echo "$PLAIN_RESULT"
fi

echo "Testing mTLS connection via xDS (Explicit certs)..."
MTLS_RESULT=$(kubectl exec mesh-tester -n $NAMESPACE -c tester -- \
    grpcurl -v -max-time 15 \
    -cert /var/run/secrets/workload-spiffe-credentials/certificates.pem \
    -key /var/run/secrets/workload-spiffe-credentials/private_key.pem \
    -cacert /var/run/secrets/workload-spiffe-credentials/ca_certificates.pem \
    -import-path /tmp -proto "/tmp/helloworld.proto" \
    -authority "greeter-service.${NAMESPACE}.svc.cluster.local" \
    -d '{"name": "xDS-mTLS-Test"}' \
    xds:///greeter-service.${NAMESPACE}.svc.cluster.local:50051 \
    helloworld.Greeter/SayHello 2>&1)

if echo "$MTLS_RESULT" | grep -q "Hello xDS-mTLS-Test"; then
    echo "✅ Success: Explicit mTLS xDS routing working."
else
    echo "❌ Failed: Explicit mTLS xDS routing."
    echo "$MTLS_RESULT"
fi
set -e

echo "✅ Setup complete!"
