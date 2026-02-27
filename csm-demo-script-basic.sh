#!/bin/bash
set -e

# Configuration Variables
PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format="value(projectNumber)")
REGION="europe-north2"
CLUSTER_NAME="csm-autopilot-cluster"
NETWORK_NAME="csm-vpc"
SUBNET_NAME="csm-subnet"
NAMESPACE="csm-demo-basic"
MEMBERSHIP_NAME="${CLUSTER_NAME}-membership"
SERVER_TLS_POLICY="basic-server-mtls-policy"
CLIENT_TLS_POLICY="basic-client-mtls-policy"
CA_POOL_NAME="basic-ca-pool"

echo "Using Project ID: ${PROJECT_ID}"
echo "Using Project Number: ${PROJECT_NUMBER}"

# STEP 1. Enable APIs
echo "1. Enabling required Google Cloud APIs..."
gcloud services enable \
    cloudresourcemanager.googleapis.com \
    compute.googleapis.com \
    container.googleapis.com \
    networkservices.googleapis.com \
    certificatemanager.googleapis.com \
    privateca.googleapis.com \
    meshconfig.googleapis.com \
    gkehub.googleapis.com \
    networksecurity.googleapis.com \
    trafficdirector.googleapis.com

# STEP 2. Create VPC and Subnet
echo "2. Creating VPC and Subnet..."
gcloud compute networks create ${NETWORK_NAME} --subnet-mode=custom || { echo "Network creation failed or already exists. Continuing..."; }
gcloud compute networks subnets create ${SUBNET_NAME} \
    --network=${NETWORK_NAME} \
    --region=${REGION} \
    --range=10.0.0.0/24 || { echo "Subnet creation failed or already exists. Continuing..."; }

# STEP 3. Provision GKE Autopilot cluster
echo "3. Provisioning GKE Autopilot cluster..."
gcloud container clusters create-auto ${CLUSTER_NAME} \
    --region=${REGION} \
    --network=${NETWORK_NAME} \
    --subnetwork=${SUBNET_NAME} || { echo "Cluster creation failed or already exists. Continuing..."; }

echo "Fetching cluster credentials..."
gcloud container clusters get-credentials ${CLUSTER_NAME} --region=${REGION}

# Enable Mesh Certificates and Gateway API Standard Channel
gcloud container clusters update ${CLUSTER_NAME} \
    --region=${REGION} \
    --enable-mesh-certificates \
    --gateway-api=standard || true

# STEP 4. Mesh Config
echo "4. Registering cluster to Fleet and enabling servicemesh..."
gcloud container fleet memberships register ${MEMBERSHIP_NAME} \
    --gke-cluster=${REGION}/${CLUSTER_NAME} \
    --enable-workload-identity || { echo "Membership registration failed or already exists. Continuing..."; }

echo "Enabling Service Mesh feature..."
gcloud container fleet mesh enable || { echo "Mesh enablement failed or already enabled. Continuing..."; }

echo "Updating membership with Gateway API config..."
gcloud container fleet mesh update \
    --memberships ${MEMBERSHIP_NAME} \
    --config-api gateway || { echo "Mesh update failed. Please check your gcloud version or IAM permissions. Continuing..."; }

# STEP 5. IAM configuration
echo "5. Configuring IAM..."
GKE_SA="service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com"
DATAPLANE_SA="service-${PROJECT_NUMBER}@gcp-sa-meshdataplane.iam.gserviceaccount.com"

# Bind trafficdirector.client to allAuthenticatedUsers
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="group:${PROJECT_ID}.svc.id.goog:/allAuthenticatedUsers/" \
    --role="roles/trafficdirector.client" >/dev/null

echo "5b. Creating CA Pool and granting Mesh IAM permissions..."
gcloud privateca pools create ${CA_POOL_NAME} --location=${REGION} --tier=devops || true
gcloud privateca roots create basic-root-ca --pool=${CA_POOL_NAME} --location=${REGION} --subject="CN=basic-root, O=demo" --auto-enable || true

# Grant permissions to CA
gcloud privateca pools add-iam-policy-binding ${CA_POOL_NAME} --location=${REGION} --member="serviceAccount:${GKE_SA}" --role="roles/privateca.certificateRequester" >/dev/null || true
gcloud privateca pools add-iam-policy-binding ${CA_POOL_NAME} --location=${REGION} --member="serviceAccount:${DATAPLANE_SA}" --role="roles/privateca.certificateRequester" >/dev/null || true
gcloud privateca pools add-iam-policy-binding ${CA_POOL_NAME} --location=${REGION} --member="serviceAccount:${GKE_SA}" --role="roles/privateca.auditor" >/dev/null || true
gcloud privateca pools add-iam-policy-binding ${CA_POOL_NAME} --location=${REGION} --member="serviceAccount:${DATAPLANE_SA}" --role="roles/privateca.auditor" >/dev/null || true

# STEP 6. Create TLS Policies
echo "6. Creating ServerTlsPolicy and ClientTlsPolicy..."

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

echo "6b. Creating Global Endpoint Policy..."
gcloud network-services endpoint-policies import greeter-policy \
    --location=global --source=- --quiet <<EOF
name: projects/${PROJECT_ID}/locations/global/endpointPolicies/greeter-policy
type: GRPC_SERVER
serverTlsPolicy: projects/${PROJECT_ID}/locations/global/serverTlsPolicies/${SERVER_TLS_POLICY}
endpointMatcher:
  metadataLabelMatcher:
    metadataLabelMatchCriteria: MATCH_ALL
    metadataLabels:
    - labelName: app
      labelValue: greeter
EOF

# STEP 7. Manifests
echo "7. Applying Kubernetes manifests..."
TRUST_DOMAIN="${PROJECT_ID}.svc.id.goog"
CA_POOL_PATH="projects/${PROJECT_ID}/locations/${REGION}/caPools/${CA_POOL_NAME}"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    mesh.cloud.google.com/csm-injection: proxyless
    mesh.cloud.google.com/managed-csm: "true"
---
apiVersion: security.cloud.google.com/v1
kind: TrustConfig
metadata:
  name: default
  namespace: ${NAMESPACE}
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
  namespace: ${NAMESPACE}
spec:
  keyAlgorithm:
    rsa:
      modulusSize: 2048
  certificateAuthorityConfig:
    certificateAuthorityServiceConfig:
      endpointURI: //privateca.googleapis.com/${CA_POOL_PATH}
---
apiVersion: v1
kind: Service
metadata:
  name: greeter
  namespace: ${NAMESPACE}
  labels:
    mesh.cloud.google.com/managed-csm: "true"
  annotations:
    networking.gke.io/app-protocols: '{"my-grpc-port":"HTTP2"}'
    networking.gke.io/server-tls-policy: projects/${PROJECT_ID}/locations/global/serverTlsPolicies/${SERVER_TLS_POLICY}
    cloud.google.com/neg: '{"exposed_ports": {"50051":{}}}'
spec:
  selector:
    app: greeter
  ports:
  - name: my-grpc-port
    port: 50051
    appProtocol: grpc
    targetPort: 50051
---
# GAMMA HTTPRoute
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: greeter-route
  namespace: ${NAMESPACE}
  annotations:
    networking.gke.io/client-tls-policy: projects/${PROJECT_ID}/locations/global/clientTlsPolicies/${CLIENT_TLS_POLICY}
spec:
  parentRefs:
  - kind: Service
    name: greeter
    group: ""
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /helloworld.Greeter/
    backendRefs:
    - name: greeter
      port: 50051
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: greeter-server
  namespace: ${NAMESPACE}
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
  namespace: ${NAMESPACE}
  annotations:
    security.cloud.google.com/use-workload-certificates: ""
spec:
  containers:
  - name: tester
    image: nicolaka/netshoot
    command: ["/bin/sh", "-c", "sleep 3600"]
EOF

# Force TrustConfig Sync
kubectl annotate trustconfig default -n ${NAMESPACE} refresh=$(date +%s) --overwrite

# Wait for Pods
echo "Waiting for greeter-server and mesh-tester pods to be ready..."
kubectl wait --for=condition=Ready pod -l app=greeter -n ${NAMESPACE} --timeout=300s
kubectl wait --for=condition=Ready pod/mesh-tester -n ${NAMESPACE} --timeout=300s

# STEP 7 & 8. Validation command
echo "=========================================================================="
echo "7. VALIDATION (PLAINTEXT)"
echo "Creating Proto File for Testing..."

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

kubectl cp helloworld.proto ${NAMESPACE}/mesh-tester:/tmp/helloworld.proto

echo "Running Native gRPC PLAINTEXT test against standard service..."
echo "Waiting for NEGs and xDS config to sync (approx 45s)..."
sleep 45

echo ""
echo "Output from plaintext grpcurl execution:"
for i in {1..5}; do
  echo "Attempt \$i..."
  if kubectl exec mesh-tester -n ${NAMESPACE} -- \
    grpcurl -v -max-time 15 --plaintext \
    -authority greeter.${NAMESPACE}.svc.cluster.local \
    -import-path /tmp -proto /tmp/helloworld.proto \
    -d '{"name":"World"}' \
    xds:///greeter.${NAMESPACE}.svc.cluster.local:50051 helloworld.Greeter/SayHello; then
      echo "✅ Plaintext Validation successful!"
      break
  else
      echo "⚠️ Plaintext Validation failed. Retrying in 30 seconds..."
      sleep 30
  fi
done

echo "=========================================================================="
echo "8. VALIDATION (mTLS)"
echo "Running Native gRPC mTLS test against Proxy-less Gateway API Route..."

echo ""
echo "Output from mTLS grpcurl execution:"
for i in {1..5}; do
  echo "Attempt \$i..."
  if kubectl exec mesh-tester -n ${NAMESPACE} -- \
    grpcurl -v -max-time 15 \
    -import-path /tmp -proto /tmp/helloworld.proto \
    -cert /var/run/secrets/workload-spiffe-credentials/certificates.pem \
    -key /var/run/secrets/workload-spiffe-credentials/private_key.pem \
    -cacert /var/run/secrets/workload-spiffe-credentials/ca_certificates.pem \
    -authority greeter.${NAMESPACE}.svc.cluster.local \
    -d '{"name":"World"}' \
    xds:///greeter.${NAMESPACE}.svc.cluster.local:50051 helloworld.Greeter/SayHello; then
      echo "✅ mTLS Validation successful!"
      break
  else
      echo "⚠️ mTLS Validation failed. xDS might still be syncing. Retrying in 30 seconds..."
      sleep 30
  fi
done
echo "=========================================================================="