---
name: implement-spec
description: Implement (or update existing implementation) from a spec using planning mode
---

# Implement Spec Skill

You are a specialized skill for implementing features from specification documents.

## Purpose

This skill reads a specification document and implements it in code. It is **idempotent** - it analyzes existing implementations and updates them rather than duplicating code.

## Workflow

When the user invokes this skill with a name argument (e.g., `/implement-spec session-timeout`):

### Step 1: Validate and Read Spec

1. Check that the user provided a spec name
2. Read the existing spec from `specs/[spec-name].md`
3. If the spec doesn't exist, inform the user to run `/create-spec [name]` first
4. Check the spec status:
   - **If "Draft"**: Suggest running `/refine-spec [name]` first
   - **If "Ready for Implementation"** or **"Implemented"**: Proceed

### Step 2: Enter Planning Mode

Use the `EnterPlanMode` tool to begin planning the implementation:

```
EnterPlanMode tool (no parameters needed)
```

This will activate planning mode where you can:
- Explore the codebase
- Analyze existing implementations
- Design the implementation approach
- Get user approval before executing

### Step 3: Planning Mode Instructions

Once in planning mode, you will have access to exploration and planning agents. Follow this approach:

#### Phase 1: Exploration (in planning mode)

Use Explore agents to analyze the codebase:

1. **Search for existing implementations**
   - Look for code that already implements parts of the spec
   - Search for relevant files mentioned in the spec (if any)
   - Find similar features that this might build upon

2. **Understand architecture patterns**
   - Identify which repositories are affected (based on spec)
   - Understand existing patterns for similar features
   - Map out integration points

3. **Identify affected files**
   - List files that will need modification
   - Find proto definitions if applicable
   - Locate configuration files
   - Find test files

#### Phase 2: Design (in planning mode)

Use Plan agent to design the implementation:

1. **Analyze existing vs. required**
   - What's already implemented?
   - What needs to be added?
   - What needs to be modified?
   - What can be removed?

2. **Design approach**
   - If feature exists partially: Plan updates to existing code
   - If feature doesn't exist: Plan new implementation
   - Avoid duplication - update existing patterns
   - Follow repository conventions

3. **Create detailed plan**
   - List all files to create/modify
   - Describe changes for each file
   - Identify dependencies between changes
   - Note any breaking changes
   - Plan migration strategy if needed

#### Phase 3: User Approval (in planning mode)

Present the plan to the user and:
- Ask clarifying questions if needed
- Get approval before implementation
- Adjust based on feedback

#### Phase 4: Implementation (after exiting planning mode)

After user approves the plan:
1. Implement the changes file by file
2. Follow the plan precisely
3. Update the spec status to "Implemented" when done
4. Add "Implementation Notes" section to spec with:
   - Date implemented
   - Key files modified/created
   - Any deviations from the plan

### Step 4: Update Spec After Implementation

After successfully implementing, update the spec file:

```markdown
> **Status**: Implemented
> **Last Updated**: [date implemented]

[... existing spec content ...]

## Implementation Notes

**Implemented**: [Month Year]

**Key Changes**:
- [List of files created/modified]
- [Summary of implementation approach]

**Deviations from Spec** (if any):
- [Any changes from original plan and why]
```

## Important Notes

- **Use planning mode**: ALWAYS use EnterPlanMode - never implement directly
- **Idempotent**: Analyze existing code first, update rather than duplicate
- **Use opus**: Planning should use opus model for complex analysis
- **Follow composite patterns**: Use composite repository conventions from CLAUDE.md
- **Test before commit**: Run `./gradlew check` from composite root
- **Update spec status**: Change to "Implemented" when done

## Example Usage

```
User: /implement-spec session-timeoutAssistant: [Reads specs/session-timeout.md]

The spec is marked "Ready for Implementation". Entering planning mode to analyze and plan the implementation.

[Calls EnterPlanMode]

--- IN PLANNING MODE ---

[Phase 1: Exploration]
- Searching for existing session management code...
- Found: SessionOrchestrator in ash-backend-services
- Found: Existing timeout configurations in AppConfiguration.kt
- Analyzing how sessions are currently managed...

[Phase 2: Design via Plan Agent]
- Planning updates to SessionOrchestrator
- Need to add timeout configuration
- Need to add proto field for user preferences
- Need to add UI settings (out of scope - note for frontend team)
- Creating detailed plan...

[Phase 3: User Approval]
Presenting implementation plan:
1. Update contracts: Add session_timeout_minutes to UserPreferences proto
2. Update backend: Modify SessionOrchestrator to use configurable timeout
3. Update ml-service: Handle timeout events
4. Add tests for timeout behavior

Does this approach look good?

User: Yes, proceed

--- EXITS PLANNING MODE ---

[Phase 4: Implementation]
Assistant implements the changes following the plan...
```

## Error Handling

- **Spec not found**: Direct user to run `/create-spec [name]` first
- **Spec status is "Draft"**: Suggest running `/refine-spec [name]` first for better results
- **Planning mode failures**: Report issues and ask for guidance
- **Implementation failures**: Roll back changes and report errors
- **Test failures**: Fix tests before marking as complete

## Multi-Repository Considerations

When implementation spans multiple repositories:

1. **Follow dependency order** (from CLAUDE.md):
   - ash-contracts first (if proto changes needed)
   - ash-services-common second (if shared library changes needed)
   - Service repositories third (ash-backend-services, ash-ml-services, ash-internal-services)

2. **Create coordinated PRs**:
   - Use same branch naming pattern across repos
   - Link PRs in descriptions
   - Use `/create-pr` skill after implementation

3. **Test integration**:
   - Run `./gradlew check` from composite root
   - Verify all repositories build together

## Spec Status Tracking

The spec status field helps track implementation lifecycle:

- **Draft** → Use `/refine-spec` to make it implementation-ready
- **Ready for Implementation** → Use `/implement-spec` to implement it
- **Implemented** → Feature is live, spec is historical record

## Best Practices

1. **Always use planning mode** - Don't skip this step
2. **Search for existing implementations** - Avoid duplication
3. **Follow established patterns** - Be consistent with codebase
4. **Update tests** - Add/modify tests as needed
5. **Update spec when done** - Mark as "Implemented" with notes
6. **Run checks before committing** - Ensure `./gradlew check` passes
7. **Create PRs** - Use `/create-pr` for multi-repo coordination
