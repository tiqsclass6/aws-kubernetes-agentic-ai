# MCP Architecture

AI Agent / Observer Agent
                        |
                        | client certificate
                        v
                +-----------------------------+
                | mcp-gateway namespace       |
                |                             |
                | ServiceAccount:             |
                | mcp-gateway-sa              |
                | automountToken: false       |
                |                             |
                | NGINX mTLS Gateway          |
                | - validates client cert     |
                | - terminates TLS            |
                | - forwards only approved    |
                |   requests                  |
                +-------------+---------------+
                              |
                              | verified traffic only
                              v
                +-----------------------------+
                | mcp namespace               |
                |                             |
                | MCP Server                  |
                | - exposes approved tools    |
                | - validates tool requests   |
                | - emits audit logs          |
                | - publishes MCP events      |
                +-------------+---------------+
                              |
                              v
                +-----------------------------+
                | Controlled Tool Targets     |
                |                             |
                | Kubernetes API              |
                | Pub/Sub                     |
                | Datadog / Grafana later     |
                | Jira later                  |
                +-----------------------------+
