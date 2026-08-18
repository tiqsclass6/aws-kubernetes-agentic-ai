# **API Gateway vs MCP Server**

## **Traditional API Gateway**

A traditional API Gateway sits between clients and backend services.

    Browser
         |
    Mobile App
         |
    CLI
         |
    ------------------------
     API Gateway
    ------------------------
         |
         +--> Authentication
         +--> Authorization
         +--> Rate Limiting
         +--> WAF
         +--> Logging
         +--> Routing
         |
    ------------------------
    Backend APIs
    ------------------------

The gateway's primary responsibility is to expose APIs securely.

## **MCP Server**

The MCP Server is similar, but instead of exposing REST APIs, it exposes tools that AI models can use.

    Claude
    Gemini
    OpenAI
    AI Agent
            |
            |
    ------------------------
        MCP Server
    ------------------------
            |
            +--> Tool Discovery
            +--> Tool Invocation
            +--> Parameter Validation
            +--> Audit Logging
            +--> Authorization
            |
    ------------------------
    Kubernetes
    GitHub
    Jira
    Filesystem
    Cloud APIs
    ------------------------

The MCP Server's primary responsibility is to expose tools securely.

## **API Gateway vs MCP**

| API Gateway       | MCP Server           |
| ----------------- | -------------------- |
| Clients           | AI Models            |
| REST APIs         | Tools                |
| HTTP Requests     | Tool Invocations     |
| Routes APIs       | Exposes Capabilities |
| API Documentation | Tool Metadata        |
| Backend Services  | Enterprise Systems   |

Notice:

The architecture is remarkably similar.

The payloads are different.

## **Kong API Gateway**

### **Traditional**

    Client
    ↓
    Kong Gateway
    ↓
    Microservices

### **versus AI**

    Claude
    ↓
    MCP Server
    ↓
    Enterprise Tools

Both provide:

    Authentication
    Authorization
    Logging
    Routing
    Governance

One routes HTTP requests.

The other routes AI tool requests.

## **Possible Kong Usage**

    Claude
    ↓
    Kong
    ↓
    mTLS
    ↓
    OPA
    ↓
    MCP Server
    ↓
    Kubernetes

Kong can sit at the internet edge. This lab does not deploy Kong. The live path is:

    Remediation Agent
    ↓
    nginx mTLS gateway (mcp-gateway)
    ↓
    MCP Server (mcp)
    ↓
    Kubernetes API in app01

OPA runs in the Governance Agent before remediation is allowed to call MCP. Kubernetes RBAC on `mcp-server-sa` is a final allowlist for `app01`.

## **Future Architecture**

    Internet
          |
          |
    +---------------------+
    | Kong API Gateway    |
    |                     |
    | TLS                 |
    | Rate Limiting       |
    | Authentication      |
    | IP Restrictions     |
    +----------+----------+
               |
               |
    +---------------------+
    | mTLS Gateway        |
    |                     |
    | Client Certificates |
    | Certificate Checks  |
    +----------+----------+
               |
               |
    +---------------------+
    | OPA                 |
    |                     |
    | Policy Decisions    |
    | Tool Authorization  |
    +----------+----------+
               |
               |
    +---------------------+
    | MCP Server          |
    |                     |
    | Tool Registry       |
    | Tool Invocation     |
    | Audit Logs          |
    +----------+----------+
               |
               |
    +---------------------+
    | Kubernetes          |
    | GitHub              |
    | Jira                |
    | Cloud APIs          |
    +---------------------+
