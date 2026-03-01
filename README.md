# Cloud Service Mesh (Proxyless gRPC) on GKE Autopilot with GAMMA & mTLS

This project demonstrates an advanced, bleeding-edge deployment of Google Cloud Service Mesh (CSM). It provisions a completely proxyless gRPC mesh (no Envoy sidecars) using the modern Kubernetes Gateway API for Mesh (GAMMA initiative).

## The "AI-First" Development Story
This repository wasn't built by manual documentation digging alone. It is the result of an experiment using the Google Developer Knowledge API and the MCP (Model Context Protocol) Server.

By connecting the Gemini CLI to Google’s live developer knowledge base, I was (for the most parts) able to bypass the "fragmentation trap" where documentation often mixes legacy Istio APIs with modern Gateway APIs.

The Experience: Watching the Gemini CLI reason through IAM dependencies and VPC configurations in real-time.

## The Workflow:
The scripts in this repo were largely generated and debugged by the AI—I simply reviewed the proposed gcloud commands and pressed '1' (Allow once) to execute them locally. Gemini will do a little bit of try and error so just follow along and "learn".

How to Generate the Scripts via AI
If you want to replicate the generation process or modify the architecture using the same AI-assisted method, follow these steps:

# 1. Configure the Developer Knowledge API (MCP)
```
# 1. Enable the API
gcloud services enable developerknowledge.googleapis.com

# 2. Create an API Key
gcloud services api-keys create --display-name="DK API Key"

# 3. Add the MCP server to your Gemini CLI
gemini mcp add -t http \
  -H "X-Goog-Api-Key: YOUR_API_KEY" \
  google-developer-knowledge \
  https://developerknowledge.googleapis.com/mcp \
  --scope user
```

More information on how to get started is here,
https://developers.google.com/knowledge/mcp#config-api


# 2. Run the Generation Prompt
Navigate to the root of this project and feed the provided prompt to the Gemini CLI. This will trigger the "Reasoning" phase where Gemini plans the infrastructure:
```
gemini "Using the Google Developer Knowledge MCP, follow the instructions in $(cat @prompt-basic.txt)"
```

### What to expect:

Gemini will identify the need for GKE Autopilot, Private CA, and Gateway API and It will propose a series of gcloud and kubectl commands. Just watch and follow and don't be afraid to update and enhance the promt with more details.

Important: When the CLI asks for permission to run a command on your machine, press '1' (Allow once) to proceed. Just follow the dialogue.


# Architecture & Core Technologies
Compute: GKE Autopilot (fully managed).

Service Mesh: Cloud Service Mesh (Managed control plane).

Traffic Management: Kubernetes Gateway API (HTTPRoute for east-west routing via GAMMA).

Data Plane: Proxyless gRPC (Applications act as direct xDS clients).


### Examples
You can find pre-generated reference scripts in the /examples folder. These serve as a baseline if you prefer to run the setup manually without the AI CLI. These files were originally created by the Gemini CLI.

# ⚠️ The "Bleeding Edge" Limitation
As of writing, while the Gateway API (GAMMA) successfully handles routing, there is a known limitation regarding Strict mTLS enforcement. Google is currently in partial conformance with Gateway API 1.3.0. In this specific proxyless gRPC setup, the ServerTlsPolicy fails to bind to the auto-generated BackendServices created by the Gateway controller. The result is permissive mTLS: the mesh is encrypted, but the server does not yet strictly reject plaintext traffic.

# Cleanup

```
/clean-up-basic.sh
```

# More Information
For deeper dives into the technologies used in this demo, check out the following resources:

*   **Cloud Service Mesh (CSM):** [Official Overview](https://cloud.google.com/service-mesh/docs/overview)
*   **Proxyless gRPC on GKE:** [Setup Guide](https://cloud.google.com/service-mesh/docs/setup-proxyless-grpc-gke)
*   **Gateway API for Mesh (GAMMA):** [Cloud Service Mesh Configuration](https://cloud.google.com/service-mesh/docs/gateway-api-mesh-overview)
*   **Kubernetes Gateway API (GAMMA) Initiative:** [Concepts & Specifications](https://gateway-api.sigs.k8s.io/concepts/gamma/)
*   **Google Developer Knowledge MCP:** [Getting Started with the MCP Server](https://developers.google.com/knowledge/mcp)