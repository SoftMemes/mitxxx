---
name: create-spec
description: Create a new spec file capturing the initial idea
---

# Create Spec Skill

You are a specialized skill for creating specification documents in the `specs/` directory.

## Purpose

This skill captures the initial idea for a specification with minimal processing. It documents what the user says **verbatim** without making assumptions, inferences, or technical suggestions.

## Workflow

When the user invokes this skill with a name argument (e.g., `/create-spec session-timeout`):

### Step 1: Validate Arguments

Check that the user provided a spec name:
- **If provided**: Use the name (e.g., `session-timeout`)
- **If missing**: Ask the user for a descriptive name for the spec

### Step 2: Ask ONE Question

Ask the user a single question to capture their idea:

**Question to ask:**
> "What is this spec describing?"

Wait for the user's response before proceeding.

### Step 3: Write Spec File

Create a minimal spec file at `specs/[spec-name].md` containing:

```markdown
# [Spec Name] Specification

> **Version**: 1.0 (Month Year)
> **Status**: Draft
> **Last Updated**: [current date]

## Description

[User's response - verbatim or lightly formatted for readability]

---

*This is a draft specification. Use `/refine-spec [spec-name]` to develop it further with structured questioning and technical details.*
```

**Important:**
- Write the user's description **as-is** - no paraphrasing, no elaboration
- You may add light formatting (paragraphs, bullet points) if the user's response contains natural structure
- Do NOT add:
  - Inferred goals or objectives
  - Technical architecture suggestions
  - Key considerations
  - Pre-computed questions
  - Implementation details

### Step 4: Report Completion

After the spec is created, inform the user:

> Created draft specification: `specs/[spec-name].md`
>
> This captures your initial idea. Next steps:
> - Review the draft spec
> - Run `/refine-spec [spec-name]` to develop it with detailed questioning
> - Run `/implement-spec [spec-name]` when it's ready for implementation

## Important Notes

- **Pure capture**: Just document what the user says - nothing more
- **ONE question only**: Ask only what the spec describes
- **Verbatim**: Use the user's words, don't elaborate or infer
- **Light formatting allowed**: Paragraphs/bullets if user's response has structure
- **Status = Draft**: Initial specs always start as "Draft"
- **Spec location**: All specs go in the `specs/` directory at repository root

## Example Usage

```
User: /create-spec session-timeout
Assistant: What is this spec describing?
User: We need to add configurable session timeouts so users can set how long they want their therapy sessions to last. Currently all sessions are fixed at 60 minutes.
Assistant: [Creates specs/session-timeout.md with the user's description verbatim]

Created draft specification: `specs/session-timeout.md`

This captures your initial idea. Next steps:
- Review the draft spec
- Run `/refine-spec session-timeout` to develop it with detailed questioning
- Run `/implement-spec session-timeout` when it's ready for implementation
```

## Rationale

- **Create-spec** = capture raw idea quickly
- **Refine-spec** = develop with questions, structure, technical details
- **Implement-spec** = implement in code

This separation keeps the initial capture fast and pure.