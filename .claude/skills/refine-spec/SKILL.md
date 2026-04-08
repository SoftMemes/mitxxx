---
name: refine-spec
description: Iteratively refine a spec with exhaustive questioning until implementation-ready
---

# Refine Spec Skill

You are a specialized skill for refining specification documents through exhaustive, iterative questioning.

## Purpose

This skill takes a draft specification and refines it through comprehensive questioning until all reasonable ambiguity is resolved and the spec is ready for implementation.

## Workflow

When the user invokes this skill with a name argument (e.g., `/refine-spec session-timeout`):

### Step 1: Validate and Read Spec

1. Check that the user provided a spec name
2. Read the existing spec from `specs/[spec-name].md`
3. If the spec doesn't exist, inform the user to run `/create-spec [name]` first

### Step 2: Launch Refinement Agent with Opus

Use the Task tool with the `general-purpose` subagent and `opus` model to perform exhaustive refinement:

```
Task tool with:
- subagent_type: "general-purpose"
- model: "opus"
- description: "Refine spec with exhaustive questioning"
- prompt:
  You are refining a specification document. Your goal is to ask exhaustive, iterative questions until the spec is complete and ready for implementation.

  CURRENT SPEC:
  [paste full spec content here]

  YOUR TASK:
  Ask comprehensive, detailed questions to resolve ALL ambiguities. Continue asking questions in multiple rounds until the user confirms the spec is complete.

  AREAS TO PROBE EXHAUSTIVELY:

  1. **Edge Cases**
     - What happens in error scenarios?
     - What are boundary conditions?
     - What happens with invalid inputs?
     - What happens with concurrent operations?

  2. **Missing Requirements**
     - Are there unstated assumptions?
     - What user stories are implied but not explicit?
     - What acceptance criteria should exist?
     - What non-functional requirements matter (performance, scalability, etc.)?

  3. **Risks & Contradictions**
     - Are there conflicting requirements?
     - Are there technical risks?
     - Are there security/privacy concerns?
     - Are there breaking changes to existing features?

  4. **Implementation Details**
     - What data structures are needed?
     - What APIs/interfaces need to change?
     - What proto definitions are needed (if applicable)?
     - What configuration is needed?
     - Which repositories/services are affected?

  5. **Error Handling**
     - How should each error scenario be handled?
     - What error messages should users see?
     - What logging/monitoring is needed?
     - What fallback behaviors are needed?

  6. **Testing Strategy**
     - What unit tests are needed?
     - What integration tests are needed?
     - How can this be manually tested?
     - What test data is needed?

  7. **Performance & Scalability**
     - What are performance requirements?
     - What are expected load patterns?
     - What caching strategies are needed?
     - What database queries will be affected?

  8. **User Experience**
     - How will users interact with this?
     - What UI changes are needed?
     - What happens during migration/rollout?
     - What documentation is needed?

  9. **Dependencies & Integration**
     - What other systems does this interact with?
     - What external APIs are needed?
     - What services need to be coordinated?
     - What order should changes be deployed?

  10. **Future Considerations**
      - What extensibility is needed?
      - What might change in the future?
      - What migration paths are needed?

  QUESTIONING APPROACH:
  - Start with high-priority gaps (implementation blockers)
  - Ask 1-4 questions per round using AskUserQuestion tool with structured options
  - For each question, provide 2-4 pre-defined answer options that cover likely responses
  - Users can always select "Other" to provide a custom answer
  - Batch related questions together in a single AskUserQuestion call
  - Questions should be answerable with a click when possible
  - After each round, assess if more questions are needed
  - When you believe all ambiguity is resolved, ask the user:
    "I've asked about [list topics]. Do you feel the spec is now complete and ready for implementation, or are there other areas we should explore?"

  EXAMPLE STRUCTURED QUESTIONS:

  Instead of asking: "Should timeouts be per-user configurable or system-wide?"

  Use AskUserQuestion with:
  - question: "How should session timeout be configured?"
  - header: "Config scope"
  - options:
    - label: "System-wide (Recommended)"
      description: "Single timeout value for all users, simpler to manage"
    - label: "Per-user configurable"
      description: "Users can set their own timeout, more flexible but complex"
    - label: "Per-organization"
      description: "Organization admins set timeout for their users"

  Instead of asking: "What happens if the user loses network during countdown?"

  Use AskUserQuestion with:
  - question: "How should we handle network loss during session timeout countdown?"
  - header: "Network loss"
  - options:
    - label: "Pause countdown (Recommended)"
      description: "Resume countdown when connection restored"
    - label: "Continue countdown"
      description: "Session ends even if user reconnects"
    - label: "Reset countdown"
      description: "Restart the full timeout period when connection restored"

  GUIDELINES FOR QUESTION DESIGN:
  - **Binary choices**: Yes/No, Enable/Disable (2 options)
  - **Configuration options**: Present 2-4 common choices (e.g., system-wide, per-user, per-org)
  - **Behavior choices**: Show 2-4 likely behaviors (e.g., retry, fail, fallback)
  - **MultiSelect**: Use when user might want multiple features/options enabled
  - **Let "Other" handle edge cases**: Don't try to enumerate every possibility upfront
  - **Recommend when appropriate**: Add "(Recommended)" to the most common/sensible option
  - **Descriptive labels**: Keep labels concise (1-5 words), descriptions explain implications

  UPDATING THE SPEC:
  Once the user confirms the spec is complete:
  1. Update the status from "Draft" to "Ready for Implementation"
  2. Remove or update the "Open Questions" section
  3. Add detailed sections based on the answers:
     - Architecture & Design
     - Data Models
     - API Changes
     - Error Handling
     - Testing Strategy
     - Deployment Plan
     - Key Files Reference (list files that will be modified)
  4. Write the updated spec back to specs/[spec-name].md

  CRITICAL: Continue asking questions until the user explicitly confirms they are satisfied. Do not stop prematurely.
```

### Step 3: Monitor Progress

The opus subagent will:
1. Ask comprehensive questions in rounds
2. Use AskUserQuestion tool for structured questioning
3. Continue until user confirms completion
4. Update the spec file with refined content
5. Change status from "Draft" to "Ready for Implementation"

### Step 4: Report Completion

After refinement is complete, inform the user:

> Specification refined and updated: `specs/[spec-name].md`
>
> Status: Ready for Implementation
>
> Next step:
> - Run `/implement-spec [spec-name]` to begin implementation

## Important Notes

- **Exhaustive questioning**: The agent must be thorough and ask about all areas listed above
- **Iterative process**: Multiple rounds of questions are expected and encouraged
- **User confirms completion**: Don't stop until the user explicitly says they're satisfied
- **Use opus model**: Always use `model: "opus"` for the refinement agent
- **Update status**: When complete, change status from "Draft" to "Ready for Implementation"
- **Structured questions**: Use AskUserQuestion tool for clarity

## Example Interaction Flow

```
User: /refine-spec session-timeout
Assistant: [Reads specs/session-timeout.md] → [Spawns opus agent]

Opus Agent: I've analyzed the session timeout spec. Let me start with critical implementation questions:

[Round 1 - Uses AskUserQuestion tool with structured options]

Question 1:
- question: "How should session timeout be configured?"
- header: "Config scope"
- options:
  - "System-wide (Recommended)" - Single timeout value for all users, simpler to manage
  - "Per-user configurable" - Users can set their own timeout, more flexible but complex
  - "Per-organization" - Organization admins set timeout for their users

Question 2:
- question: "Where should timeout enforcement be implemented?"
- header: "Implementation"
- options:
  - "Backend service (Recommended)" - Centralized control, easier to audit
  - "ML service" - Closer to conversation logic
  - "Both services" - Redundant enforcement for reliability

Question 3:
- question: "What should happen if a session timeout occurs while the user is mid-sentence?"
- header: "Mid-sentence"
- options:
  - "Wait for sentence completion (Recommended)" - Better UX, may delay timeout slightly
  - "Immediate termination" - Strict timeout enforcement
  - "Grace period" - Allow 30 seconds to complete thought

User: [Clicks answers]

Opus Agent: Thank you. Now let me ask about error handling and network scenarios:

[Round 2 - Uses AskUserQuestion tool]

Question 1:
- question: "How should we handle network loss during timeout countdown?"
- header: "Network loss"
- options:
  - "Pause countdown (Recommended)" - Resume when connection restored
  - "Continue countdown" - Session ends even if user reconnects
  - "Reset countdown" - Restart full timeout period on reconnection

Question 2:
- question: "Should we show a countdown timer to the user?"
- header: "UI Display"
- options:
  - "Yes, always visible (Recommended)" - Full transparency
  - "Yes, only last 2 minutes" - Less intrusive
  - "No, silent timeout" - Minimal UI clutter

User: [Clicks answers]

Opus Agent: Let me verify deployment and monitoring:

[Round 3 - Uses AskUserQuestion tool]

Question 1:
- question: "Should this feature be behind a feature flag initially?"
- header: "Rollout"
- options:
  - "Yes, gradual rollout (Recommended)" - Safer, can roll back easily
  - "No, deploy to all users" - Simpler, faster to production

Question 2:
- question: "What metrics should we track for session timeouts?"
- header: "Monitoring"
- multiSelect: true
- options:
  - "Timeout occurrences" - Count of sessions that timed out
  - "User reconnections" - Users who return after timeout
  - "Session duration distribution" - Track typical session lengths
  - "Timeout errors" - Failed timeout handling

User: [Clicks multiple answers]

Opus Agent: I've asked about configuration, implementation, edge cases, error handling, UX, deployment, and monitoring. Do you feel the spec is now complete and ready for implementation, or are there other areas we should explore?

User: Looks complete to me!

Opus Agent: [Updates spec with all refined details, changes status to "Ready for Implementation"]
```

## Error Handling

- **Spec not found**: Direct user to run `/create-spec [name]` first
- **Spec already "Ready for Implementation"**: Ask if user wants to refine further anyway
- **User interrupts**: Save progress by updating spec with questions asked so far