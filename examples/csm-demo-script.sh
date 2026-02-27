#!/bin/bash
# csm-demo-script.sh
#
# A complete setup for a Proxyless gRPC Cloud Service Mesh
# using the Gateway API (GAMMA initiative) with mTLS on GKE Autopilot.

set -e

# ==========================================
# 1. Configuration & Setup
# ==========================================
export PROJECT_ID=$(gcloud config get-value project)
export REGION="europe-north2"
export VPC_NAME="csm-demo-vpc"
export SUBNET_NAME="csm-demo-subnet"
export CLUSTER_NAME="csm-autopilot-cluster"
export MEMBERSHIP_NAME="csm-membership"
export CA_POOL_NAME="csm-ca-pool"
export NAMESPACE="csm-demo-ns"
export CURRENT_USER=$(gcloud config get-value account)
export PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

echo "=========================================="
echo "🚀 Starting Full CSM Gateway API (GAMMA) Setup"
echo "Project: $PROJECT_ID ($PROJECT_NUMBER)"
echo "Region: $REGION"
echo "=========================================="

echo "[Step 1] Enabling Google Cloud APIs..."
gcloud services enable \
    compute.googleapis.com \
    container.googleapis.com \
    trafficdirector.googleapis.com \
    networkservices.googleapis.com \
    networksecurity.googleapis.com \
    privateca.googleapis.com \
    gkehub.googleapis.com \
    certificatemanager.googleapis.com \
    mesh.googleapis.com

# ==========================================
# 2. IAM Permissions
# ==========================================
echo "[Step 2] Applying IAM Permissions..."

# Grant privateca.admin to current user
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="user:${CURRENT_USER}" \
    --role="roles/privateca.admin" \
    --condition="None" >/dev/null

# Create Service Identities
gcloud beta services identity create --service=meshconfig.googleapis.com --project="${PROJECT_ID}" >/dev/null 2>&1 || true
gcloud beta services identity create --service=trafficdirector.googleapis.com --project="${PROJECT_ID}" >/dev/null 2>&1 || true

# Grant Service Agent Roles
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com" \
    --role="roles/anthosservicemesh.serviceAgent" \
    --condition="None" >/dev/null

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com" \
    --role="roles/meshcontrolplane.serviceAgent" \
    --condition="None" >/dev/null

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
    --role="roles/container.serviceAgent" \
    --condition="None" >/dev/null

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-meshdataplane.iam.gserviceaccount.com" \
    --role="roles/meshconfig.admin" \
    --condition="None" >/dev/null

# ==========================================
# 3. Networking & Cluster Infrastructure
# ==========================================
echo "[Step 3] Creating VPC, Subnet, and GKE Cluster..."

if ! gcloud compute networks describe "$VPC_NAME" >/dev/null 2>&1; then
    gcloud compute networks create "$VPC_NAME" --subnet-mode=custom
fi

if ! gcloud compute networks subnets describe "$SUBNET_NAME" --region="$REGION" >/dev/null 2>&1; then
    gcloud compute networks subnets create "$SUBNET_NAME" \
        --network="$VPC_NAME" \
        --region="$REGION" \
        --range="10.20.0.0/20" \
        --enable-private-ip-google-access
fi

if ! gcloud container clusters describe "$CLUSTER_NAME" --region="$REGION" >/dev/null 2>&1; then
    gcloud container clusters create-auto "$CLUSTER_NAME" \
        --region="$REGION" \
        --network="$VPC_NAME" \
        --subnetwork="$SUBNET_NAME"
fi

echo "Fetching cluster credentials..."
gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION"

echo "Enabling Mesh Certificates on the cluster..."
gcloud container clusters update "$CLUSTER_NAME" \
    --region="$REGION" \
    --enable-mesh-certificates

echo "Enabling Gateway API on the cluster..."
gcloud container clusters update "$CLUSTER_NAME" \
    --region="$REGION" \
    --gateway-api=standard

# ==========================================
# 4. Fleet & Mesh Registration
# ==========================================
echo "[Step 4] Registering to Fleet and Enabling Mesh..."

if ! gcloud container fleet memberships describe "$MEMBERSHIP_NAME" --location="$REGION" >/dev/null 2>&1; then
    export CLUSTER_URI="https://container.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/clusters/${CLUSTER_NAME}"
    gcloud container fleet memberships register "$MEMBERSHIP_NAME" \
        --gke-uri="$CLUSTER_URI" \
        --enable-workload-identity
fi

gcloud container fleet mesh enable

echo "Configuring Fleet Mesh to use Gateway API..."
gcloud alpha container fleet mesh update \
    --config-api=gateway \
    --memberships="$MEMBERSHIP_NAME" \
    --location="$REGION"

echo "⏳ Waiting for Gateway API CRDs..."
until kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1; do
    echo "   ...waiting..."
    sleep 10
done

# ==========================================
# 5. Private CA Setup (for mTLS)
# ==========================================
echo "[Step 5] Configuring Private CA..."

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

gcloud privateca pools add-iam-policy-binding "$CA_POOL_NAME" \
    --location="$REGION" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-meshdataplane.iam.gserviceaccount.com" \
    --role="roles/privateca.certificateRequester" >/dev/null

# Fix PermissionDenied for TrustConfig Rendering
gcloud privateca pools add-iam-policy-binding "$CA_POOL_NAME" \
    --location="$REGION" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
    --role="roles/privateca.auditor" >/dev/null

gcloud privateca pools add-iam-policy-binding "$CA_POOL_NAME" \
    --location="$REGION" \
    --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-meshdataplane.iam.gserviceaccount.com" \
    --role="roles/privateca.auditor" >/dev/null

# ==========================================
# 6. Kubernetes Namespace & Workload Identity Setup
# ==========================================
echo "[Step 6] Setting up Namespace and Workload Identity..."

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl label namespace "$NAMESPACE" mesh.cloud.google.com/csm-injection="proxyless" mesh.cloud.google.com/managed-csm="true" --overwrite

kubectl create serviceaccount grpc-sa --namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Native Workload Identity bindings
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="group:${PROJECT_ID}.svc.id.goog:/allAuthenticatedUsers/" \
    --role="roles/trafficdirector.client" \
    --condition="None" >/dev/null 2>&1 || true

gcloud privateca pools add-iam-policy-binding "$CA_POOL_NAME" \
    --location="$REGION" \
    --role="roles/privateca.certificateRequester" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/grpc-sa]" >/dev/null 2>&1 || true

gcloud privateca pools add-iam-policy-binding "$CA_POOL_NAME" \
    --location="$REGION" \
    --role="roles/privateca.certificateManager" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/grpc-sa]" >/dev/null 2>&1 || true

# ==========================================
# 7. Mesh Certificates Configuration
# ==========================================
echo "[Step 7] Configuring Mesh Certificates..."
export TRUST_DOMAIN="${PROJECT_ID}.svc.id.goog"
export CA_POOL_PATH="projects/${PROJECT_ID}/locations/${REGION}/caPools/${CA_POOL_NAME}"

cat <<EOF | kubectl apply -f -
apiVersion: security.cloud.google.com/v1
kind: TrustConfig
metadata:
  name: default
  namespace: $NAMESPACE
spec:
  trustStores:
  - trustDomain: "${TRUST_DOMAIN}"
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

# Wait for TrustConfig to render
sleep 5

# ==========================================
# 8. Global Security Policies (Network Security API)
# ==========================================
echo "[Step 8] Defining Global Security Policies..."
export SERVER_TLS_POLICY="gamma-server-mtls-policy"
export CLIENT_TLS_POLICY="gamma-client-mtls-policy"

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

# ==========================================
# 9. Gateway API Routing (GAMMA pattern)
# ==========================================
echo "[Step 9] Applying Gateway API Routing..."
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
    appProtocol: grpc
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
  hostnames:
  - "greeter-service.${NAMESPACE}.svc.cluster.local"
  rules:
  - matches:
    - path: { type: PathPrefix, value: /helloworld.Greeter/ }
    backendRefs:
    - name: greeter-service
      port: 50051
EOF

# ==========================================
# 10. Workload Deployment
# ==========================================
echo "[Step 10] Deploying Workloads..."
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
      serviceAccountName: grpc-sa
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
  serviceAccountName: grpc-sa
  containers:
  - name: tester
    image: nicolaka/netshoot
    command: ["/bin/sh", "-c", "sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: unauthorized-tester
  namespace: $NAMESPACE
spec:
  containers:
  - name: tester
    image: nicolaka/netshoot
    command: ["/bin/sh", "-c", "sleep 3600"]
EOF

echo "⏳ Waiting for pods to become Ready..."
kubectl wait --for=condition=Ready pod -l app=greeter -n $NAMESPACE --timeout=600s
kubectl wait --for=condition=Ready pod/mesh-tester -n $NAMESPACE --timeout=600s

echo "⏳ Waiting for gRPC Server to listen for Traffic..."
export SERVER_POD=$(kubectl get pod -l app=greeter -n $NAMESPACE -o jsonpath='{.items[0].metadata.name}')

TIMEOUT=60
START_TIME=$(date +%s)
SERVER_STARTED=false

while [ $(($(date +%s) - START_TIME)) -lt $TIMEOUT ]; do
    if kubectl logs "$SERVER_POD" -n "$NAMESPACE" -c server | grep -q "Server started, listening on 50051"; then
        SERVER_STARTED=true
        break
    fi
    echo "   ...waiting for server start..."
    sleep 5
done

if [ "$SERVER_STARTED" = false ]; then
    echo "❌ Error: gRPC Server failed to start listening within 60 seconds."
    echo "--------------------------------------------------------"
    echo "🛠️  Troubleshooting Steps:"
    echo "1. Check the Traffic Director configuration in your Google Cloud project to ensure a mesh exists and has the required configurations for your 'greeter-server' application."
    echo "2. Verify that the 'greeter-server' application is correctly configured to use this mesh."
    echo "3. Ensure there are no network policies or missing permissions blocking communication to the Traffic Director control plane."
    echo "4. Ensure that the Kubernetes Service Account used by the 'greeter-server' pods has the 'roles/trafficdirector.client' IAM role."
    echo "--------------------------------------------------------"
    echo "Server Logs:"
    kubectl logs "$SERVER_POD" -n "$NAMESPACE" -c server --tail=20
    exit 1
fi

# ==========================================
# 11. Validation Phase
# ==========================================
echo "[Step 11] Validating Setup..."

#echo "Validating Mesh Route acceptance..."
#kubectl wait --for=condition=Accepted httproute/greeter-route -n $NAMESPACE --timeout=600s
sleep 120

echo "Verifying GRPC_XDS_BOOTSTRAP on Server:"
kubectl exec "$SERVER_POD" -n "$NAMESPACE" -c server -- printenv GRPC_XDS_BOOTSTRAP

echo "Generating and copying helloworld.proto..."
export PROTO_FILE="helloworld.proto"
cat <<EOF > "$PROTO_FILE"
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
kubectl cp "$PROTO_FILE" "${NAMESPACE}/mesh-tester:/tmp/${PROTO_FILE}"
kubectl cp "$PROTO_FILE" "${NAMESPACE}/unauthorized-tester:/tmp/${PROTO_FILE}"

echo "Verifying workload certificates on mesh-tester..."
kubectl exec mesh-tester -n "$NAMESPACE" -c tester -- ls -la /var/run/secrets/workload-spiffe-credentials

# Give Traffic Director a moment to sync configurations
echo "⏳ Waiting for xDS config to propagate (30s)..."
sleep 30

echo "Testing plaintext connection via xDS (Delegates mTLS to xDS)..."
set +e
RESULT=$(kubectl exec mesh-tester -n $NAMESPACE -c tester -- \
    grpcurl -v -max-time 15 --plaintext \
    -import-path /tmp -proto "/tmp/${PROTO_FILE}" \
    -authority "greeter-service.${NAMESPACE}.svc.cluster.local" \
    -d '{"name": "Plaintext-xDS-Test"}' \
    xds:///greeter-service.${NAMESPACE}.svc.cluster.local:50051 \
    helloworld.Greeter/SayHello 2>&1)

if [[ $RESULT == *"Hello Plaintext-xDS-Test"* ]]; then
    echo "✅ Success: Plaintext xDS routing working."
    echo "$RESULT"
else
    echo "❌ Failed: Plaintext xDS routing."
    echo "$RESULT"
fi

echo "Testing mTLS connection via xDS (Explicit certs)..."
MTLS_RESULT=$(kubectl exec mesh-tester -n $NAMESPACE -c tester -- \
    grpcurl -v -max-time 15 \
    -cert /var/run/secrets/workload-spiffe-credentials/certificates.pem \
    -key /var/run/secrets/workload-spiffe-credentials/private_key.pem \
    -cacert /var/run/secrets/workload-spiffe-credentials/ca_certificates.pem \
    -import-path /tmp -proto "/tmp/${PROTO_FILE}" \
    -authority "greeter-service.${NAMESPACE}.svc.cluster.local" \
    -d '{"name": "mTLS-Explicit-Test"}' \
    xds:///greeter-service.${NAMESPACE}.svc.cluster.local:50051 \
    helloworld.Greeter/SayHello 2>&1)

if [[ $MTLS_RESULT == *"Hello mTLS-Explicit-Test"* ]]; then
    echo "✅ Success: Explicit mTLS xDS routing working."
else
    echo "❌ Failed: Explicit mTLS xDS routing."
    echo "$MTLS_RESULT"
fi

echo "Testing connection from unauthorized client..."
UNAUTH_RESULT=$(kubectl exec unauthorized-tester -n $NAMESPACE -c tester -- \
    grpcurl -v -max-time 15 --plaintext \
    -import-path /tmp -proto "/tmp/${PROTO_FILE}" \
    -authority "greeter-service.${NAMESPACE}.svc.cluster.local" \
    -d '{"name": "Unauthorized-Test"}' \
    greeter-service.${NAMESPACE}.svc.cluster.local:50051 \
    helloworld.Greeter/SayHello 2>&1)

if [[ $UNAUTH_RESULT == *"Hello Unauthorized-Test"* ]]; then
    echo "❌ Unexpected Success: Unauthorized client connected."
    echo ""
    echo "--------------------------------------------------------"
    echo "⚠️ STRICT mTLS FAILURE EXPLANATION ⚠️"
    echo "The architecture successfully provisions workload identities"
    echo "and routes proxyless gRPC via the Gateway API (GAMMA)."
    echo "However, strict mTLS (allowOpen: false) is currently permissive."
    echo ""
    echo "When using the Gateway API to define mesh routes via an"
    echo "HTTPRoute attached to a Service, GKE auto-generates the"
    echo "internal BackendService and Network Endpoint Groups (NEGs)."
    echo "The legacy Network Security EndpointPolicy (which attempts to"
    echo "bind the ServerTlsPolicy to the pods via labels) currently"
    echo "fails to correctly attach to these auto-generated backends in"
    echo "a proxyless gRPC environment."
    echo ""
    echo "Because the server lacks the strict policy command from the"
    echo "control plane, it defaults to accepting plaintext traffic."
    echo "--------------------------------------------------------"
else
    echo "✅ Success: Unauthorized client rejected."
    echo "$UNAUTH_RESULT"
fi
set -e
