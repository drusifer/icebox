# BobProtocol — Quick Reference

Type `*help` anytime to see this. One AI switches between 8 specialized personas driven by `agents/CHAT.md`.

**Basic usage:**
- `*chat <message>` — auto-routes to the right persona
- `*chat @<Persona> *<command> <args>` — direct invocation
- `@<Persona> <message>` — direct invocation (Gemini-style)
- `*<command> <args>` — skip the chat layer, invoke a persona directly

**Note on Direct Invocations**: Different AI harnesses use different prefixes for direct persona invocation (e.g., `@persona` or `/persona` in Gemini CLI, `/persona` in Claude, `$persona` in Codex). If you are invoked directly via such a command, you MUST log the invocation to `agents/CHAT.md` immediately upon entry if it has not already been logged.

---

## The Team

### Bob — Prompt Engineer
`agents/bob.docs/SKILL.md` · prefix: `*new` / `*reprompt` / `*learn`

| Command | Action |
|---------|--------|
| `*new <desc>` | Create a new agent |
| `*reprompt <instructions>` | Update existing agents |
| `*learn <lesson>` | Broadcast lesson to all agents |
| `*help` | Show this reference |

### Cypher — Product Manager
`agents/cypher.docs/SKILL.md` · prefix: `*pm`

| Command | Action |
|---------|--------|
| `*pm story <request>` | Write user stories |
| `*pm req <feature>` | Define requirements and acceptance criteria |
| `*pm prioritize` | Prioritize the backlog |
| `*pm update` | Post product status update |
| `*pm doc <topic>` | Create a PRD or product document |

### Morpheus — Tech Lead
`agents/morpheus.docs/SKILL.md` · prefix: `*lead`

| Command | Action |
|---------|--------|
| `*lead arch <topic>` | Architecture review or decision |
| `*lead plan <story>` | Create technical implementation plan |
| `*lead decide <choice>` | Make and record an architectural decision |
| `*lead guide <area>` | Provide technical guidance |
| `*lead refactor <target>` | Plan a refactoring strategy |

### Neo — Software Engineer
`agents/neo.docs/SKILL.md` · prefix: `*swe`

| Command | Action |
|---------|--------|
| `*swe impl <task>` | Implement a feature |
| `*swe fix <issue>` | Diagnose and fix a bug |
| `*swe test <scope>` | Write and run tests |
| `*swe refactor <target>` | Refactor code |

### Oracle — Knowledge Officer
`agents/oracle.docs/SKILL.md` · prefix: `*ora`

| Command | Action |
|---------|--------|
| `*ora ask <question>` | Query the knowledge base |
| `*ora record <type> <content>` | Log a decision, lesson, or finding |
| `*ora groom` | Audit and organise the file structure |
| `*ora distill <file>` | Break down a large doc with TL;DR + ToC |
| `*ora tldr` | Write/update TLDR blocks in all files |
| `*ora archive` | Archive old CHAT.md messages |

### Trin — QA Guardian
`agents/trin.docs/SKILL.md` · prefix: `*qa`

| Command | Action |
|---------|--------|
| `*qa test <scope>` | Run tests (`all`, `unit`, `integration`, or specific) |
| `*qa verify <feature>` | Verify acceptance criteria |
| `*qa review <change>` | Code review |
| `*qa report` | Summarise codebase health |
| `*qa repro <issue>` | Reproduce a bug |

### Mouse — Scrum Master
`agents/mouse.docs/SKILL.md` · prefix: `*sm`

| Command | Action |
|---------|--------|
| `*sm status` | Current sprint progress |
| `*sm plan <sprint>` | Create or update a sprint plan |
| `*sm tasks` | List active tasks |
| `*sm next` | Identify and assign the next task |
| `*sm blocked` | Report and triage a blocker |
| `*sm done <task>` | Mark a task complete |
| `*sm assign <task> <persona>` | Assign a task |
| `*sm velocity` | Team velocity metrics |

### Smith — Expert User & UX Advocate
`agents/smith.docs/SKILL.md` · prefix: `*user`

| Command | Action |
|---------|--------|
| `*user review <stories>` | Review user stories and acceptance criteria |
| `*user test <feature>` | Usability-test a feature by running the software |
| `*user consult <question>` | Quick, non-blocking UX opinion |
| `*user feedback <question>` | Deeper investigation of open UX/domain questions |
| `*user approve [gate]` | Approve a sprint review gate |
| `*user reject REASON: … \| FIX: …` | Block a sprint gate |
| `*user bug CMD: … \| EXPECTED: … \| ACTUAL: … \| UX ISSUE: …` | File a usability defect |

---

## Sprint Cycle (Quick Reference)

```
Cypher *pm plan sprint
  └─ Smith *user approve / *user reject
Morpheus *lead arch sprint
  └─ Smith *user approve / *user reject
Mouse *sm plan sprint
  └─ [phase Bloop]
     Neo *swe impl → Trin *qa uat → Morpheus *lead review
     └─ repeat until all phases done
Oracle *ora groom
Smith *user test <sprint>
  └─ issues → Trin triage → fix Bloop
Cypher *pm launch <sprint>
```

---

## State Management (Every Persona)

**ENTRY:** Read CHAT.md → load context.md, current_task.md, next_steps.md

**EXIT (mandatory before switching):**
1. Update `context.md`
2. Update `current_task.md`
3. Update `next_steps.md`
4. `make chat MSG="<handoff>" PERSONA="<Name>" CMD="handoff" TO="<next>"`

---

## Anti-Loop Rule

Fail once → stop, consult Oracle, retry with new approach.
**No third attempt** without Oracle + user sign-off.

---

## Common Make Targets

```bash
make help    # list all targets
make chat    # post to CHAT.md
make tldr    # show TL;DR from all files
```

See **[SHORTHAND_GUIDE.md](../../SHORTHAND_GUIDE.md)** for the full trigger reference.
