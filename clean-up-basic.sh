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

echo "Using Project ID: ${PROJECT_ID}"
echo "Using Project Number: ${PROJECT_NUMBER}"

echo "1. Removing Kubernetes resources..."
kubectl delete namespace ${NAMESPACE} --ignore-not-found || true

echo "2. Removing IAM bindings..."
GKE_SA="service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com"
DATAPLANE_SA="service-${PROJECT_NUMBER}@gcp-sa-meshdataplane.iam.gserviceaccount.com"

gcloud projects remove-iam-policy-binding ${PROJECT_ID} \
    --member="group:${PROJECT_ID}.svc.id.goog:/allAuthenticatedUsers/" \
    --role="roles/trafficdirector.client" || true

echo "3. Unregistering from Fleet and Disabling Mesh Management..."
gcloud container fleet mesh update \
    --management manual \
    --memberships ${MEMBERSHIP_NAME} || true

gcloud container fleet memberships unregister ${MEMBERSHIP_NAME} \
    --gke-cluster=${REGION}/${CLUSTER_NAME} || true

echo "4. Deleting GKE Autopilot cluster..."
gcloud container clusters delete ${CLUSTER_NAME} --region=${REGION} --quiet || true

echo "5. Deleting VPC and Subnet..."
gcloud compute networks subnets delete ${SUBNET_NAME} --region=${REGION} --quiet || true
gcloud compute networks delete ${NETWORK_NAME} --quiet || true

echo "5b. Deleting Endpoint Policy..."
gcloud network-services endpoint-policies delete greeter-policy --location=global --quiet || true

echo "6. Deleting CA Pool and TLS Policies..."
gcloud privateca roots delete basic-root-ca --pool=basic-ca-pool --location=${REGION} --ignore-active-certificates --quiet || true
gcloud privateca pools delete basic-ca-pool --location=${REGION} --quiet || true

gcloud network-security server-tls-policies delete basic-server-mtls-policy --location=global --quiet || true
gcloud network-security client-tls-policies delete basic-client-mtls-policy --location=global --quiet || true

echo "Clean-up complete."