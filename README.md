# Cloud Service Mesh (Proxyless gRPC) on GKE Autopilot with GAMMA & mTLS

## About
This project provides a reference implementation for an advanced, bleeding-edge deployment of **Google Cloud Service Mesh (CSM)**. It showcases a completely **proxyless gRPC mesh** (no Envoy sidecars) using the modern **Kubernetes Gateway API for Mesh (GAMMA initiative)** on GKE Autopilot.

By leveraging the Gemini CLI and the Google Developer Knowledge MCP, this repository demonstrates how to bridge the gap between fragmented developer documentation and production-ready infrastructure through "AI-First" engineering.

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

Gemini operates in a **Research -> Strategy -> Execution** lifecycle:

1.  **Research & Planning:** Gemini will use the MCP server to query live Google Cloud documentation. It identifies the exact sequence of `gcloud` and `kubectl` commands needed for GKE Autopilot, Private CA, and the Gateway API.
2.  **Proposed Strategy:** Before acting, it will present a summary of its plan.
3.  **Interactive Execution:** For every command that modifies your environment, Gemini will explain the intent and ask for permission. 
    *   Press `1` to **Allow Once**.
    *   Press `2` to **Deny**.
    *   Press `3` to **Modify** the command before running.
4.  **Self-Correction:** If a command fails (e.g., due to a propagation delay or missing IAM permission), Gemini will analyze the error message and automatically propose a fix or a retry strategy.

## Working with Gemini CLI
Gemini CLI is more than a simple chatbot; it is a collaborative engineer that lives in your terminal. Here are a few tips to get the most out of it:

*   **Contextual Awareness:** Use the `@` symbol to reference files in your project (e.g., `gemini "Explain what @csm-demo-script-basic.sh does"`). This allows Gemini to read the file content directly.
*   **Iteration over perfection:** Don't be afraid to give broad instructions. If the result isn't exactly what you wanted, just follow up with "Actually, change the region to us-central1" or "Add more logging to that script."
*   **Troubleshooting:** If you encounter an error during deployment, you can simply paste the error into the CLI. Gemini will investigate your local environment, check logs, and suggest corrections.
*   **Built-in Help:** You can always type `/help` within the interactive CLI to see a list of available commands and features.


# Architecture & Core Technologies
Compute: GKE Autopilot (fully managed).

Service Mesh: Cloud Service Mesh (Managed control plane).

Traffic Management: Kubernetes Gateway API (HTTPRoute for east-west routing via GAMMA).

Data Plane: Proxyless gRPC (Applications act as direct xDS clients).


### Examples
You can find pre-generated reference scripts in the /examples folder. These serve as a baseline if you prefer to run the setup manually without the AI CLI. These files were originally created by the Gemini CLI.

# 💰 Cost Warning
Running this demo provisions several paid Google Cloud resources, including:
* **GKE Autopilot Cluster:** Management fees and resource consumption.
* **Certificate Authority Service (Private CA):** DevOps tier CA pool and root CA.
* **Cloud Service Mesh:** Managed control plane usage.
* **Networking Resources:** VPC, subnets, and load balancing components.

**Important:** To avoid incurring unnecessary costs, ensure you run the cleanup script immediately after you are finished with the demo.

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