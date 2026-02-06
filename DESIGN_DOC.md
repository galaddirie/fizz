# Software Design Document
## AI-Native Full-Service Marketing Agency Platform
### Codename: Fizz

**Version:** 0.1 — Draft  
**Status:** Pre-Engineering / Architectural Design  
**Date:** February 2026  

---


## 1. Executive Summary

### 1.1 Purpose

This document defines the high-level software architecture for Fizz, an AI-native platform purpose-built for full-service marketing agencies. Fizz replaces the fragmented landscape of point solutions (CRM, project management, creative tools, media platforms, analytics dashboards) with a unified system where AI is the connective tissue between every agency function.

### 1.2 Problem Statement

Modern agencies operate across 15–40 disconnected software tools. AI is being adopted within these tools in silos — generative AI for copy here, predictive analytics there, automation in another place. This fragmentation means:

- Institutional knowledge is scattered and inaccessible
- AI tools lack cross-functional context, limiting their usefulness
- Human effort is spent on integration, translation, and context-switching rather than high-value creative and strategic work
- Agencies cannot compound their learning across clients, campaigns, or time

### 1.3 Solution Overview

Fizz is a platform built from nine composable engine primitives. These primitives can be combined to power any agency workflow — from competitive research to creative development to campaign optimization to client reporting. A shared intelligence layer ensures that every function benefits from the full context of the agency's knowledge, rather than operating in isolation.

The future of agency work is human led, AI driven.

### 1.4 Design Scope

This document covers the architectural design of the platform engine — the primitives, their interfaces, their relationships, and their composition patterns.

---

## 2. Design Philosophy & Principles

### 2.1 Core Philosophy

**AI-native means AI is the architecture, not a feature.** The platform is not a traditional SaaS tool with AI bolted on. The AI layer is the primary integration point between all system components. Data flows through AI understanding, not just through database joins.

### 2.2 Design Principles

**P1 — Primitives Over Products.** Build composable engine primitives that can be assembled into any workflow, rather than building fixed-function applications. The application layer is a composition of primitives, not a monolith.

**P2 — Shared Intelligence, Isolated Data.** All modules benefit from a common understanding of clients, brands, campaigns, syndicated research, internal learnings and RFPs. But data isolation between tenants and between clients within a tenant is absolute and cryptographically enforced.

**P3 — Human-in-the-Loop by Design.** AI handles volume, synthesis, and first drafts. Humans handle judgment, relationships, and final decisions. Every workflow has configurable approval gates. The system should make humans more effective, not replace their judgment.

**P4 — Context is the Product.** The platform's core value is assembling the right context at the right time — connecting a creative brief to past performance data, competitive intelligence, brand guidelines, syndicated research, internal learnings and RFPs and client preferences simultaneously. Isolated AI is commodity. Contextual AI is the moat.

**P5 — Progressive Autonomy.** Agencies should be able to start with AI-assisted workflows (AI suggests, human decides) and gradually increase autonomy (AI acts, human audits) as trust builds. The platform must support this spectrum without architectural changes.

**P6 — Observability as a First-Class Citizen.** Every AI decision must be traceable. Every data access must be auditable. Trust is built on transparency, and agency clients (especially in regulated industries) will demand it.

**P7 — Cost Awareness.** Every AI operation has a cost. The platform must be aware of these costs, attribute them accurately, and provide mechanisms to optimize spend-per-value at every level.


---

## 3. System Overview & Layered Architecture

### 3.1 Architectural Layers

The system is organized into four layers, from bottom to top:

```
┌─────────────────────────────────────────────────────────┐
│                   APPLICATION LAYER                      │
│  (Account Mgmt, Creative Studio, Strategy Hub,           │
│   Media Center, Project Ops, New Business, Reporting)    │
├─────────────────────────────────────────────────────────┤
│                  ORCHESTRATION LAYER                     │
│  (Workflow Engine, Event Bus, Cross-Module Intelligence,  │
│   Human-in-the-Loop Gates)                               │
├─────────────────────────────────────────────────────────┤
│                    ENGINE LAYER                           │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐   │
│  │ Identity │ │Knowledge │ │   RAG    │ │  Agent   │   │
│  │& Tenancy │ │  Base    │ │ Pipeline │ │ Runtime  │   │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘   │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐   │
│  │ Sandbox  │ │  Fluid   │ │Integration│ │Observa-  │   │
│  │Execution │ │ Compute  │ │ Framework│ │ bility   │   │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘   │
├─────────────────────────────────────────────────────────┤
│                 INFRASTRUCTURE LAYER                     │
│  (Compute, Storage, Networking, Secrets, GPU Pools)      │
└─────────────────────────────────────────────────────────┘
```

**Infrastructure Layer** — Cloud compute, storage, networking, and GPU resources. Abstracted from the engine layer so the platform is cloud-agnostic.

**Engine Layer** — The nine composable primitives. Each primitive exposes a well-defined internal API. Primitives communicate through the event bus and direct API calls.

**Orchestration Layer** — Composes primitives into multi-step, multi-agent, human-in-the-loop workflows. Manages state, coordination, and cross-functional intelligence.

**Application Layer** — User-facing modules built entirely by composing engine primitives and orchestration patterns. No application module has its own data store or AI pipeline — everything flows through the engine layer.

### 3.2 Primitive Dependency Map

```
                    ┌──────────────┐
                    │  Observability│ (observes all primitives)
                    └──────┬───────┘
                           │
        ┌──────────────────┼──────────────────────┐
        │                  │                      │
  ┌─────┴──────┐    ┌──────┴───────┐    ┌─────────┴───────┐
  │  Workflow  │    │   Agent      │    │   Sandbox       │
  │  Engine    │    │   Runtime    │    │   Execution     │
  └─────┬──────┘    └──────┬───────┘    └─────────────────┘
        │                  │
        │          ┌───────┴────────┐
        │          │  RAG Pipeline  │
        │          └───────┬────────┘
        │                  │
   ┌────┴────┐    ┌────────┴────────┐    ┌──────────────┐
   │ Event   │    │  Knowledge Base │    │  Integration │
   │ Bus     │    └────────┬────────┘    │  Framework   │
   └─────────┘             │             └──────────────┘
                   ┌───────┴────────┐
                   │Fluid Compute & │
                   │ Model Router   │
                   └───────┬────────┘
                           │
                   ┌───────┴────────┐
                   │   Identity &   │
                   │   Tenancy      │
                   └────────────────┘
```

All primitives depend on Identity & Tenancy for access control. Most primitives depend on Fluid Compute for AI inference. The dependency graph flows upward, with higher-level primitives composing lower-level ones.

---

## 4. Primitive

### 4.1 Identity, Tenancy & Access Control

#### 4.1.1 Purpose

Manages all identity, authentication, authorization, and data isolation across the platform. Defines the hierarchical tenancy model and enforces access boundaries at every layer.

#### 4.1.2 Tenancy Hierarchy

```
Platform (Fizz)
  └── Agency Tenant
        ├── Agency-level settings, models, knowledge
        ├── Team (e.g., Strategy, Creative, Media, Account)
        │     └── Team-level permissions, workflows
        ├── Client Workspace
        │     ├── Client-level brand assets, data, history
        │     ├── Campaign
        │     │     ├── Campaign assets, performance data, briefs
        │     │     └── Project
        │     │           └── Tasks, deliverables, timelines
        │     └── Competitor Profiles (scoped to this client)
        └── User
              ├── Role-based permissions
              ├── Personal preferences, activity history
              └── Session context
```

#### 4.1.3 Data Isolation Model

**Hard Isolation (cryptographic boundary):**
- Agency Tenant ↔ Agency Tenant: Complete isolation. No data sharing possible. Separate encryption keys per tenant. One agency on the platform can never access another agency's data, even through AI-mediated channels (e.g., RAG results, model fine-tuning, aggregated benchmarks).

**Firm Isolation (application-enforced, auditable):**
- Client Workspace ↔ Client Workspace within the same Agency: Isolated by default. An agency team working on Brand A cannot see Brand B's data unless explicitly granted cross-client access for a defined purpose (e.g., portfolio reporting). All cross-client data access is logged and auditable. AI agents inherit this isolation — an agent operating in Client A's context cannot retrieve Client B's documents from the knowledge base.

**Soft Isolation (permission-based):**
- Team ↔ Team within the same Client: Visible by default within a client workspace, but specific assets or workstreams can be restricted by role or team. Example: Financial data about a client engagement may be visible to Account leads but not to junior creatives.

#### 4.1.4 AI-Specific Access Control

When an AI agent acts on behalf of a user, it operates under an **effective permission scope** that is the intersection of:
- The user's permissions
- The agent's defined scope (agents can be further restricted beyond the user's access)
- The workflow's scope (a workflow may grant temporary elevated access for a specific step, with audit logging)

This means an agent can never exceed the permissions of the human who invoked it, and can be further constrained.

#### 4.1.5 Key Entities

- **Tenant** — top-level organizational boundary (the agency)
- **Workspace** — client-scoped data container within a tenant
- **User** — individual human identity with role-based and attribute-based permissions
- **Service Identity** — machine identity for agents, workflows, and integrations
- **Permission Policy** — declarative rules defining access (e.g., "Members of the Strategy team can read all documents in Workspace X but can only write to the Strategy folder")
- **Access Token** — scoped, time-limited credential issued per session or per agent execution, encoding the effective permission scope

### 4.2 Knowledge Base

#### 4.2.1 Purpose

The Knowledge Base is the institutional memory of the platform. It ingests, structures, relates, versions, and serves all knowledge artifacts — documents, data, entities, relationships, and derived insights. It is the primary data substrate that all other primitives read from and write to.

#### 4.2.2 Sub-Components

The Knowledge Base is composed of four interconnected stores:

##### 4.2.2.1 Document Store

Manages raw and processed documents of all types.

**Supported Content Types:**
- Text documents (briefs, strategies, reports, emails, chat logs)
- Presentations (decks, pitch materials)
- Spreadsheets (media plans, budgets, performance data)
- Creative assets (images, video, audio, design files)
- Structured data (campaign metrics, CRM records, financial data)
- Conversations (meeting transcripts, client call recordings, Slack threads)

**Processing Pipeline:**
Upon ingestion, every document passes through a processing pipeline:

1. **Format Extraction** — convert to processable format (PDF → text, audio → transcript, image → description + embedding, video → keyframes + transcript)
2. **Structure Detection** — identify document type, sections, headers, tables, key-value pairs. Understand the document's internal structure, not just its raw text.
3. **Intelligent Chunking** — split into chunks that respect semantic boundaries (paragraphs, sections, slide breaks) rather than arbitrary token windows. Each chunk retains metadata about its position within the parent document and its relationship to adjacent chunks.
4. **Entity Extraction** — identify and extract named entities (brands, people, campaigns, channels, metrics, dates, monetary values) from each chunk.
5. **Embedding Generation** — generate vector embeddings for each chunk using the appropriate embedding model (text, image, multi-modal). Multiple embeddings per chunk are supported (e.g., one optimized for semantic similarity, one for keyword matching).
6. **Classification & Tagging** — auto-classify the document's type, topic, relevance to specific clients/campaigns, and sensitivity level.
7. **Relationship Mapping** — connect the document and its entities to the Entity Graph.

8. **Human-in-the-Loop** — a human reviewer may add additional metadata or tags to the document after it has been processed. a human may be requested when not enough information is available to process the document. ex. raw csv dataset with no context. 

**Storage Model:**
- Original file preserved immutably
- Processed representations stored alongside (extracted text, chunks, embeddings)
- Full version history — every update creates a new version, previous versions remain accessible
- Lifecycle management — documents can be archived, marked as superseded, or flagged as current/authoritative

##### 4.2.2.2 Entity Graph

A knowledge graph mapping relationships between all meaningful entities in the platform.

**Core Entity Types:**
- **Organization** (client company, competitor, vendor, partner)
- **Brand** (a brand within an organization, with its identity, guidelines, voice)
- **Person** (client contact, agency team member, industry figure)
- **Campaign** (a marketing initiative with defined objectives, timeframe, channels)
- **Asset** (a creative deliverable — ad, video, social post, landing page)
- **Channel** (marketing channel — paid social, search, OOH, email, etc.)
- **Audience** (a defined target segment with demographic, psychographic, behavioral attributes)
- **Metric** (a KPI or measurement — CPA, brand lift, engagement rate)
- **Concept** (a strategic territory, theme, or messaging pillar)
- **Event** (a notable occurrence — product launch, PR crisis, competitive move, cultural moment)

**Relationship Types:**
- Structural: `Brand BELONGS_TO Organization`, `Campaign TARGETS Audience`
- Temporal: `Campaign PRECEDED Campaign`, `Asset UPDATED_FROM Asset`
- Causal/Analytical: `Campaign DROVE Metric`, `Event IMPACTED Brand`
- Creative: `Asset EXPRESSES Concept`, `Brand USES_VOICE VoiceProfile`
- Competitive: `Brand COMPETES_WITH Brand`, `Campaign RESPONDS_TO Campaign`

**Entity Resolution:**
The system must handle the same entity appearing across multiple documents and contexts. "Nike," "Nike, Inc.," "@nike," and "the Beaverton-based sportswear company" all resolve to the same entity. Entity resolution runs continuously as new content is ingested.

**Confidence & Provenance:**
Every entity and relationship carries a confidence score and provenance trail. Auto-extracted relationships from AI have lower initial confidence than human-confirmed ones. Confidence decays over time for time-sensitive assertions (e.g., "X is the CMO of Brand Y" should be re-verified periodically).

##### 4.2.2.3 Semantic Index

Vector storage and retrieval layer powering similarity search across all content types.

**Index Architecture:**
- Separate vector indices per content modality (text, image, audio/video) optimized for each embedding model
- Indices are partitioned by tenant and optionally by workspace for query-time performance and isolation
- Supports metadata filtering at query time (e.g., "find similar content but only within Client Y's workspace and only from the last 6 months")

**Embedding Strategy:**
- Text: Multiple embedding models may be used — a general-purpose model for broad retrieval, and potentially domain-fine-tuned models for marketing-specific similarity
- Images: Vision model embeddings for visual similarity search
- Multi-modal: Joint text-image embeddings for cross-modal search ("find images that match this description")

##### 4.2.2.4 Temporal Layer

Every knowledge artifact exists in time. The temporal layer manages this dimension.

**Temporal Metadata:**
- `created_at` — when the artifact was first ingested
- `effective_at` — when the information became true/relevant (a brand guideline might be uploaded today but effective since last quarter)
- `superseded_at` — when the information was replaced by newer information (null if current)
- `expires_at` — optional expiration for time-sensitive information (a competitive promotion ending on a specific date)
- `last_verified_at` — when a human or automated process last confirmed the information is still accurate

**Temporal Query Semantics:**
Queries to the knowledge base can specify temporal intent:
- "current" — retrieve only non-superseded, non-expired artifacts (default)
- "as of [date]" — retrieve artifacts that were current at a specific point in time
- "historical" — retrieve all versions, including superseded ones
- "trending" — weight recent artifacts more heavily


---



## 5. Data Architecture & Governance

### 5.1 Data Classification

All data in the platform is classified into tiers:

| Tier | Description | Examples | Handling |
|---|---|---|---|
| **Public** | Publicly available information | Published competitor ads, public financial filings, news articles | Minimal restrictions; can be used in anonymized benchmarks |
| **Internal** | Agency-internal information | Internal processes, team communications, agency financial data | Tenant-isolated; not available outside the agency tenant |
| **Client Confidential** | Client-specific proprietary information | Brand strategy documents, unreleased creative, campaign budgets | Workspace-isolated; additional encryption; strict access logging |
| **Regulated** | Subject to regulatory requirements | Healthcare client PHI, financial client PII, children's data | Compliance controls; data residency requirements; retention policies; enhanced audit |

### 5.2 Data Lifecycle

```
Ingestion → Processing → Active Use → Archival → Deletion
```

Each stage has defined rules per data classification tier:
- **Retention policies** — how long data is retained before archival/deletion (configurable per tenant, overridden by regulatory requirements)
- **Archival** — archived data is moved to cold storage, removed from active indices, but retrievable on demand
- **Deletion** — permanent removal from all stores, including backups (within the defined backup retention window). Supports "right to be forgotten" workflows.
- **Data export** — tenants can export all their data in standard formats at any time (data portability)

### 5.3 AI Training Data Governance

**Absolute rule: Tenant data is never used to train or fine-tune models that serve other tenants.** This includes:
- No cross-tenant data in fine-tuning datasets
- No cross-tenant data in few-shot examples
- No cross-tenant data in embedding model training
- Aggregated, anonymized benchmarks are only produced with explicit tenant opt-in and are subject to differential privacy techniques

**Within a tenant:** An agency may choose to fine-tune models on their own institutional knowledge (across their clients). This is permitted but:
- Requires explicit agency-level configuration
- Respects client workspace isolation (client A's data is not in the fine-tuning set if the agency has restricted cross-client learning)
- Is transparently logged and auditable

### 5.4 Data Residency

For tenants with data residency requirements:
- Knowledge base storage, compute, and processing can be pinned to specific geographic regions
- Cross-region data transfer is prohibited unless explicitly configured
- Model inference requests are routed to region-appropriate endpoints

---


## 6. Failure Modes & Resilience

### 6.1 Failure Scenarios & Mitigations

| Failure | Impact | Mitigation |
|---|---|---|
| **LLM Provider Outage** | Agents and RAG pipelines cannot generate responses | Model Router falls back to alternative providers. Queue non-urgent requests. Notify users of degraded capability for interactive sessions. |
| **Knowledge Base Index Corruption** | Search returns incorrect or no results | Maintain index replicas. Automated integrity checks. Rebuild from document store (source of truth). |
| **Integration Sync Failure** | External data becomes stale | Retry with backoff. Display data freshness indicators in UI. Alert on prolonged sync failures. |
| **Sandbox Execution Failure** | Analysis or processing tasks fail | Retry with increased resources. Log failure details for debugging. Fall back to cached results if available. |
| **Workflow Step Failure** | Multi-step process stalls | Retry the failed step. If retries exhausted, pause workflow and notify the responsible human with context. |
| **Event Bus Backlog** | Events process with delay | Scale consumers. Prioritize critical events (permissions, security) over informational events. |
| **Tenant Data Breach Attempt** | Unauthorized cross-tenant data access | Defense in depth — encryption boundaries, access control at every layer, anomaly detection. Automatic lockout on suspicious patterns. |

### 6.2 Resilience Principles

- No single point of failure for critical paths
- All state is persisted before acknowledgment (crash recovery without data loss)
- Circuit breakers on all external dependencies (prevent cascade failures)
- Graceful degradation over hard failure (partial functionality is better than no functionality)
- Automated health checks and self-healing where possible

---


## 7. Open Questions & Future Considerations

### 7.1 Open Design Questions

**Q1: Fine-Tuning Strategy**
How aggressively should we fine-tune domain-specific models vs. relying on RAG with general-purpose models? Fine-tuning offers better quality for specialized tasks but adds operational complexity and training data governance challenges.

**Q2: Agent Autonomy Defaults**
What should the default autonomy level be for new tenants? More autonomy = faster workflows but higher risk. More human-in-the-loop = safer but slower. Should this be configurable per tenant, per module, per workflow?

**Q3: Multi-Tenant Benchmarking**
Agencies would benefit from cross-industry benchmarks ("how does my client's social engagement compare to industry averages?"). How do we build opt-in, privacy-preserving benchmark datasets? What differential privacy guarantees are needed?

**Q4: Real-Time Collaboration**
Should the platform support real-time collaborative editing of AI-generated content (like Google Docs), or is a review-and-approve model sufficient? Real-time collaboration adds significant architectural complexity.

**Q5: Offline & Edge Capability**
Do agency teams need any offline capability (e.g., for client presentations in locations without reliable internet)? If so, which primitives need offline-capable variants?

**Q6: White-Labeling**
Agencies may want to present the platform as their own proprietary technology to clients. How deep does white-labeling need to go — just UI theming, or full domain/branding customization?

### 7.2 Future Considerations

**Multi-Modal Generation Evolution:**
As AI models evolve to handle video, audio, and interactive content generation natively, the Creative Studio module and Sandbox primitive will need to expand to support these modalities.

**Inter-Agency Collaboration:**
In some cases, agencies partner on large accounts (e.g., a creative agency and a media agency). The tenancy model may need to support controlled cross-tenant collaboration with strict scope boundaries.

**Client-Facing Portal:**
Agencies may want to give their clients direct access to certain parts of the platform (dashboards, approval workflows, asset libraries). This requires a separate client-facing tenancy tier with extremely restricted permissions.

**Marketplace for Workflows & Agent Definitions:**
As agencies build custom workflows and agent configurations, a marketplace for sharing these across the platform (with appropriate anonymization) could accelerate adoption and create network effects.

**Autonomous Campaign Management:**
As trust in AI grows, the platform should be architecturally ready for increasingly autonomous operations — AI managing campaigns end-to-end with human oversight rather than human execution with AI assistance. The progressive autonomy principle (P5) ensures the architecture supports this evolution without redesign.

---

## Appendix A: Glossary

| Term | Definition |
|---|---|
| **Agent** | An AI entity that can reason, plan, use tools, and take actions within defined boundaries |
| **Artifact** | Any piece of content or data produced or managed by the platform |
| **Connector** | A modular component that integrates an external system with the platform |
| **Entity** | A meaningful object in the knowledge graph (brand, person, campaign, etc.) |
| **Guardrail** | A constraint that limits what an agent can do, ensuring safety and quality |
| **Human-in-the-Loop Gate** | A point in a workflow where a human must review, approve, or provide input |
| **Pipeline Profile** | A pre-configured RAG pipeline optimized for a specific use case |
| **Primitive** | A foundational engine component that can be composed to build features |
| **Sandbox** | An isolated execution environment for running code safely |
| **Scope** | The set of data and actions accessible to an identity (user or agent) in a given context |
| **Span** | A single operation within a distributed trace |
| **Tenant** | The top-level organizational boundary (an agency) |
| **Trace** | A complete record of an execution path across all primitives |
| **Workspace** | A client-scoped data container within a tenant |
| **Workflow Definition** | A declarative specification of a multi-step process |
| **Workflow Instance** | A running execution of a workflow definition |

---