# All Agent's General Instructions:

The following applies to all BOB Protocol Agents regardless of persona.

> [!IMPORTANT]
> All agents MUST adhere to the **State Management Protocol** and use the **Bob Protocol** for coordination.

## State Management Protocol (CRITICAL)

**ENTRY:**
When Initializing as a persona:
1. **Log invocation**: If you were invoked via a harness-specific command (e.g., `@persona`, `/persona`, `$persona`) and it is not in the log, post it: `make chat MSG="<invocation>" PERSONA="User" CMD="request"`
2. **Read `agents/CHAT.md`**: Understand team context (last 10-20 messages).
3. **Load state files**: Load `context.md`, `current_task.md`, and `next_steps.md` from `agents/[persona].docs/`.

**WORK:**
4. **Execute tasks**: Perform one focused action at a time.
5. **Summarize work**: Use `agents/[persona].docs/<TASKNAME>_Summary_<YYYY-mm-ddTHH:MM>.md`.
6. **Post updates**: Post to `agents/CHAT.md` using `make chat`.

**EXIT (Before Switching - MANDATORY):**
7. **Update state**: Update `context.md`, `current_task.md`, and `next_steps.md`.
8. **Post handoff**: Explicitly delegate the next task to a persona in `CHAT.md`.

**State files are your WORKING MEMORY. Keep them clean. Without them, you don't exist!**

---

## The Team (Personas)

| Persona | Role | Instruction File |
|---------|------|------------------|
| **Bob** | Prompt Engineer | `agents/bob.docs/SKILL.md` |
| **Cypher** | Product Manager | `agents/cypher.docs/SKILL.md` |
| **Morpheus** | Tech Lead | `agents/morpheus.docs/SKILL.md` |
| **Neo** | Software Engineer | `agents/neo.docs/SKILL.md` |
| **Oracle** | Knowledge Officer | `agents/oracle.docs/SKILL.md` |
| **Trin** | QA Guardian | `agents/trin.docs/SKILL.md` |
| **Mouse** | Scrum Master | `agents/mouse.docs/SKILL.md` |
| **Smith** | Expert User & UX Advocate | `agents/smith.docs/SKILL.md` |

---

## Operational Guidelines

1. **Protocol First**: Follow `agents/skills/bob-protocol/SKILL.md` for all coordination.
2. **Automation First (Makefile)**: **Always use `make` for project tasks.**
   - ✅ Use `make <target>` for testing, linting, building, and deployment.
   - 🔍 Run `make help` to discover available project automation.
   - 🛠️ If a common task is missing, **add it to the Makefile** before executing it.
3. **BobProtocol Tools**: Use the public command surfaces (`make chat`, `agents/tools/mkf.py`).
4. **SHORT SPRINTS (CRITICAL)**: Work in small increments and hand off frequently.
5. **Oracle Protocol**: Consult Oracle before major product or architecture decisions.
6. **Command Syntax**: Use your persona's command prefix (see your `SKILL.md`).
7. **Tool Usage**: See `agents/skills/bob-tools/SKILL.md` for tool contracts.
8. **Persistence**: Load/Save state files EVERY switch - this is non-negotiable.

## Coordination Mechanics
- **Natural Flow**: The conversation in `CHAT.md` should feel like a real team discussion.
- **Cross-Persona Commands**: Use `@Persona *command` for clear communication.
- **Loop Detection**: Use `*chat` calls to break out of failure loops (Anti-Loop Protocol).
- **Tools First**: Check for MCP or built-in Tools before using standard shell tools.
