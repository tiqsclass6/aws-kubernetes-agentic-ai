# Lab 1C — Introduction to the Model Context Protocol (MCP)

What is MCP?

Imagine you have a very intelligent AI assistant.

It can reason, write code, explain Kubernetes, and answer questions.

But there is one major limitation.

It only knows what you tell it.

It cannot automatically:

    inspect your Kubernetes cluster
    read your Jira tickets
    query your cloud environment
    retrieve files
    execute approved administrative tasks

unless something provides those capabilities.

This is where the Model Context Protocol (MCP) comes in. Think of MCP Like a USB Port

A laptop is useful by itself. But when you plug in:

    a keyboard
    a webcam
    an external drive

the laptop gains new capabilities.

MCP works similarly for AI.

It provides a standardized way for AI models to connect to external tools and services.

Instead of every AI vendor inventing a different API for every application, MCP defines a common protocol that allows AI systems to discover and use tools consistently.

Why Was MCP Created?

Before MCP:

    Claude ---- Custom API ---- Jira
    Claude ---- Different API ---- GitHub
    Claude ---- Another API ---- Kubernetes
    Claude ---- Yet Another API ---- AWS

Every integration was unique.

Every company wrote custom code.

Every security review was different.

With MCP:

    Claude
          |
          |
         MCP
          |
    ------------------------------------
    |        |         |         |
    GitHub  Jira     Kubernetes  AWS

Now AI systems communicate with external services using a common protocol.

This makes integrations easier to build, easier to secure, and easier to maintain.

What Problems Does MCP Solve?

Without MCP:

    Every tool requires a custom integration.
    AI developers repeatedly solve the same problem.
    Security policies are inconsistent.
    Authentication differs between applications.

With MCP:

    Standard communication protocol
    Standard tool discovery
    Standard request format
    Easier security controls
    Easier auditing

## What Does an MCP Server Actually Do?

Think of the MCP Server as a tool broker. It answers questions like:

    What tools are available? 
    What parameters does this tool require? 
    Is this user authorized?
    Execute this approved request.

The AI itself does not directly access Kubernetes or Jira.

Instead:

    AI
     |
     | Request
     |
     v
    MCP Server
    
     |
     | Authorized Tool
     |
     v
    Kubernetes

The MCP Server becomes the trusted intermediary.

Example

    A user asks: "How many pods are running in namespace app01?"

The AI does not know.

Instead:

    User
    ↓
    Claude
    ↓
    MCP Server
    ↓
    kubectl get pods -n app01
    ↓
    Results Returned
    ↓
    Claude Explains Results

The AI reasons about the output. The MCP Server performs the action.

## Why This Matters for Security

Imagine an AI connected directly to your Kubernetes cluster. That would be dangerous. Instead, the MCP Server provides security controls such as:

    Authentication
    Authorization
    Tool restrictions
    Logging
    Auditing
    Rate limiting

In our architecture we add even more protection:

    AI Agent
    ↓
    mTLS Gateway
    ↓
    MCP Server
    ↓
    OPA Policy Check
    ↓
    Approved Tool
    ↓
    Kubernetes

Notice that several security layers exist before any command reaches the cluster.

## MCP in Our Lab

Our implementation treats the MCP Server as a secure application gateway rather than simply a protocol endpoint.

The architecture includes:

        mTLS Gateway
        OPA/Gatekeeper policies
        Kubernetes RBAC
        Audit logging
        Certificate monitoring
        AI Guardian Agent
        Gateway Telemetry Agent

This approach demonstrates how MCP can be deployed in enterprise environments where security and governance are just as important as AI functionality.

## Why Employers Care

Many organizations are moving beyond simple chatbots. They want AI that can:

        investigate incidents
        retrieve logs
        summarize telemetry
        open Jira tickets
        inspect Kubernetes clusters
        assist cloud engineers

MCP provides one of the emerging standards for connecting AI systems to those enterprise tools.

Understanding MCP demonstrates that an engineer understands not only AI prompting, but also how AI integrates with production infrastructure.

## Key Takeaways

By the end of this lab, students should understand:

        An MCP Server is not an AI model.
        It is not a database.
        It is not Kubernetes.

Instead, it is a secure intermediary that allows AI systems to discover and invoke approved tools in a standardized way.

In our architecture, the MCP Server sits behind an mTLS gateway and a Deterministic Governance Core (DGC), ensuring that:

        AI provides reasoning and recommendations.
        Security policies determine what is permitted.
        Human operators retain control over sensitive actions.
