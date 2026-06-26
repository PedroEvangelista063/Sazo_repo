# Skill Registry

**Delegator use only.** Any agent that launches sub-agents reads this registry to resolve compact rules, then injects them directly into sub-agent prompts. Sub-agents do NOT read this registry or individual SKILL.md files.

See `_shared/skill-resolver.md` for the full resolution protocol.

## User Skills

| Trigger | Skill | Path |
|---------|-------|------|
| When building AI chat features — breaking changes from v4 | ai-sdk-5 | `C:\Users\inven\.config\opencode\skills\ai-sdk-5\SKILL.md` |
| When structuring Angular projects or deciding where to place components | angular-architecture | `C:\Users\inven\.config\opencode\skills\angular\architecture\SKILL.md` |
| When creating Angular components, using signals, or setting up zoneless | angular-core | `C:\Users\inven\.config\opencode\skills\angular\core\SKILL.md` |
| When working with forms, validation, or form state in Angular | angular-forms | `C:\Users\inven\.config\opencode\skills\angular\forms\SKILL.md` |
| When optimizing Angular app performance, images, or lazy loading | angular-performance | `C:\Users\inven\.config\opencode\skills\angular\performance\SKILL.md` |
| When creating a pull request, opening a PR, or preparing changes for review | branch-pr | `C:\Users\inven\.config\opencode\skills\branch-pr\SKILL.md` |
| find capacity, check quota, where can I deploy, capacity discovery | capacity | `C:\Users\inven\.agents\skills\microsoft-foundry\models\deploy-model\capacity\SKILL.md` |
| custom deployment, customize model deployment, choose version, select SKU | customize | `C:\Users\inven\.agents\skills\microsoft-foundry\models\deploy-model\customize\SKILL.md` |
| When editing or creating opencode's own configuration | customize-opencode | `<built-in>` |
| deploy model, deploy gpt, create deployment, model deployment | deploy-model | `C:\Users\inven\.agents\skills\microsoft-foundry\models\deploy-model\SKILL.md` |
| When building REST APIs with Django — ViewSets, Serializers, Filters | django-drf | `C:\Users\inven\.config\opencode\skills\django-drf\SKILL.md` |
| How do I do X, find a skill for X, is there a skill that can | find-skills | `C:\Users\inven\.agents\skills\find-skills\SKILL.md` |
| When creating PRs, writing PR descriptions, or using gh CLI | github-pr | `C:\Users\inven\.config\opencode\skills\github-pr\SKILL.md` |
| When writing Go tests, using teatest, or adding test coverage | go-testing | `C:\Users\inven\.config\opencode\skills\go-testing\SKILL.md` |
| When creating a GitHub issue, reporting a bug, or requesting a feature | issue-creation | `C:\Users\inven\.config\opencode\skills\issue-creation\SKILL.md` |
| When user asks to create an epic, large feature, or multi-task initiative | jira-epic | `C:\Users\inven\.config\opencode\skills\jira-epic\SKILL.md` |
| When user asks to create a Jira task, ticket, or issue | jira-task | `C:\Users\inven\.config\opencode\skills\jira-task\SKILL.md` |
| When user says "judgment day", "review adversarial", "dual review" | judgment-day | `C:\Users\inven\.config\opencode\skills\judgment-day\SKILL.md` |
| Deploy, evaluate, and manage Foundry agents end-to-end | microsoft-foundry | `C:\Users\inven\.agents\skills\microsoft-foundry\SKILL.md` |
| When working with Next.js — routing, Server Actions, data fetching | nextjs-15 | `C:\Users\inven\.config\opencode\skills\nextjs-15\SKILL.md` |
| Root skill for Omni-Gateway TS | omni-gateway-ts | `C:\Users\inven\.agents\skills\omni-gateway-ts\SKILL.md` |
| Change peon-ping settings like volume, pack rotation, categories | peon-ping-config | `C:\Users\inven\.claude\skills\peon-ping-config\SKILL.md` |
| Log exercise reps for the Peon Trainer | peon-ping-log | `C:\Users\inven\.claude\skills\peon-ping-log\SKILL.md` |
| Toggle peon-ping sound notifications on/off | peon-ping-toggle | `C:\Users\inven\.claude\skills\peon-ping-toggle\SKILL.md` |
| Set which voice pack plays for the current chat session | peon-ping-use | `C:\Users\inven\.claude\skills\peon-ping-use\SKILL.md` |
| When writing E2E tests — Page Objects, selectors, MCP workflow | playwright | `C:\Users\inven\.config\opencode\skills\playwright\SKILL.md` |
| Quick deployment to optimal region, best region for capacity | preset | `C:\Users\inven\.agents\skills\microsoft-foundry\models\deploy-model\preset\SKILL.md` |
| When writing Python tests — fixtures, mocking, markers | pytest | `C:\Users\inven\.config\opencode\skills\pytest\SKILL.md` |
| When writing React components — no useMemo/useCallback needed | react-19 | `C:\Users\inven\.config\opencode\skills\react-19\SKILL.md` |
| When user asks to create a new skill, add agent instructions | skill-creator | `C:\Users\inven\.config\opencode\skills\skill-creator\SKILL.md` |
| When styling with Tailwind — cn(), theme variables, no var() in className | tailwind-4 | `C:\Users\inven\.config\opencode\skills\tailwind-4\SKILL.md` |
| When writing TypeScript code — types, interfaces, generics | typescript | `C:\Users\inven\.config\opencode\skills\typescript\SKILL.md` |
| When using Zod for validation — breaking changes from v3 | zod-4 | `C:\Users\inven\.config\opencode\skills\zod-4\SKILL.md` |
| When managing React state with Zustand | zustand-5 | `C:\Users\inven\.config\opencode\skills\zustand-5\SKILL.md` |

## Compact Rules

Pre-digested rules per skill. Delegators copy matching blocks into sub-agent prompts as `## Project Standards (auto-resolved)`.

### ai-sdk-5
- Imports moved: `useChat`/`useCompletion` from `@ai-sdk/react`, not `ai`
- Transport is required: `new DefaultChatTransport({ api: "/api/chat" })` wraps the old `api` option
- `handleInputChange` removed — manage input state yourself with `useState`
- `message.parts` array replaces `message.content` string — iterate parts with `type: "text" | "image" | "tool-call" | "tool-result"`
- Server side: `streamText` from `ai`, returns `result.toDataStreamResponse()`

### angular-architecture
- Follow strict module/feature folder structure per Angular style guide
- Feature modules own their components, services, routing
- Shared module for common UI (pipes, directives, standalone components)
- Core module for singletons (auth service, API interceptor)
- Lazy-load feature routes, eagerly load Core and Shared

### angular-core
- Standalone components by default (no NgModule for them)
- Use `inject()` instead of constructor DI
- Signals (`signal()`, `computed()`, `effect()`) replace most RxJS in templates
- `@if`/`@for`/`@switch` control flow replaces `*ngIf`/`*ngFor`/`ngSwitch`
- Zoneless: configure `provideExperimentalZonelessChangeDetection`; use `ChangeDetectorRef` only as last resort

### angular-forms
- Prefer Reactive Forms over Template-Driven Forms for complex validation
- Use `form.controls` (typed) — `form.get('field')` only when dynamic key
- Signal Forms (experimental): `formControl()` from `@angular/forms/experimental`
- Validators: compose with `Validators.required`, `Validators.email`, etc.
- Async validators for server-side uniqueness checks

### angular-performance
- `NgOptimizedImage` for all `<img>` tags — `ngSrc`, `priority` on LCP, `fill` or explicit `width`/`height`
- `@defer` for non-critical content: `@defer { <heavy-component /> } @placeholder { <skeleton /> }`
- Lazy-load all feature routes
- SSR/SSG: configure `provideClientHydration()`; `isPlatformBrowser` guard for browser-only code

### branch-pr
- Every PR MUST link an approved issue (`Closes #N`) — no exceptions
- Branch naming: `type/description` where type is `feat|fix|chore|docs|style|refactor|perf|test|build|ci|revert`
- PR body MUST contain: linked issue, PR type checkbox, summary, changes table, test plan, contributor checklist
- Conventional commits: `type(scope): description` — match commit type to PR label
- Automated checks enforce issue linkage, approval status, and `type:*` label

### capacity
- Discovery-only skill — use to check model availability across Azure regions
- Queries TPM availability, quota limits per region/project
- Returns recommended regions with capacity; does NOT deploy
- For deployment after discovery, use `preset` or `customize` skill

### customize
- Full interactive: model version, SKU (GlobalStandard/Standard/ProvisionedManaged), capacity, RAI policy
- Step-by-step — user confirms each choice
- Enables advanced options: dynamic quota, priority processing, spillover
- Use for PTU deployments; `preset` for quick auto-deploy

### customize-opencode
- Only for editing opencode's own config files: `opencode.json`, `opencode.jsonc`, `~/.config/opencode/`, `.opencode/`
- Not for the user's application code
- Use when creating/fixing agents, subagents, skills, plugins, MCP servers, permission rules

### deploy-model
- Router skill — delegates to `preset` (auto), `customize` (interactive), or `capacity` (discovery)
- For listing existing deployments, use `foundry_models_deployments_list` MCP tool
- For agent/project creation, use separate tools — this is model deployment only

### django-drf
- ViewSets over function-based views for CRUD; use `ModelViewSet` + `get_serializer_class()` for per-action serializers
- Separate Read / Create / Update serializers with `write_only=True` on passwords
- `@action(detail=True, methods=["post"])` for custom endpoints on a ViewSet
- FilterSets with `django_filters` for search/filter; pagination via `PageNumberPagination`
- Test with `APIClient`, `force_authenticate`, `pytest.mark.django_db`

### find-skills
- Searches Engram registry and filesystem for matching skills
- Recommends installation path for found skills
- First point of contact when user asks "can you do X"

### github-pr
- PR title = conventional commit: `type(scope): description` where `type` is `feat|fix|docs|refactor|test|chore`
- Description structure: Summary (1-3 bullets), Changes, Testing checklist
- Atomic commits: one logical change per commit
- Use `gh pr create --title "..." --body "..."`; draft with `--draft`
- Avoid: vague titles, giant PRs (50+ files), empty descriptions

### go-testing
- Use `testing.T` and `github.com/stretchr/testify/assert` for assertions
- For TUI testing with Bubbletea: use `github.com/gentlemanprogramming/teatest`
- Table-driven tests with anonymous structs for multiple cases
- `t.Cleanup()` for teardown (not defer inside test functions)
- Run with `go test ./... -v -race`

### issue-creation
- Blank issues disabled — MUST use bug report or feature request template
- Pre-flight checks required: no duplicate, understands `status:approved` workflow
- Bug report: description, steps, expected/actual, OS, agent, shell fields
- Feature request: problem description, proposed solution, affected area
- Issues start with `status:needs-review`; maintainer adds `status:approved` before PR

### jira-epic
- Follows Prowler's standard epic format
- Includes business value, scope, dependencies, and acceptance criteria
- Breaks down into stories/tasks with estimates
- Links to related epics and initiatives

### jira-task
- Follows Prowler's standard task format
- Includes acceptance criteria and definition of done
- Links to parent epic/story
- Assignee, estimate, priority fields required

### judgment-day
- Launch TWO blind judge sub-agents in parallel via `delegate` (async) — NEVER sequential
- Inject matching compact rules as `## Project Standards (auto-resolved)` into both judges AND fix agent
- Synthesize verdict: Confirmed (both), Suspect (one), Contradiction (disagree)
- Fix agent applies confirmed issues only — separate delegation, not a judge
- Max 2 fix iterations — on 3rd failure, ESCALATED with full report
- Orchestrator never reviews code — only coordinates

### microsoft-foundry
- Full lifecycle: Docker build → ACR push → hosted/prompt agent create → invoke → eval
- Batch eval, prompt optimization, dataset curation from traces
- RBAC, quota, capacity checks via Foundry MCP tools
- Monitoring: agent deployment, custom metrics, knowledge index

### nextjs-15
- App Router file conventions: `layout.tsx` (root, required), `page.tsx`, `loading.tsx`, `error.tsx`, `not-found.tsx`
- Server Components by default — async component functions with direct `await db.query()`
- Server Actions: `"use server"` directive, use `revalidatePath`/`redirect` from `next/cache` and `next/navigation`
- Route Handlers: `app/api/route.ts` with `NextRequest`/`NextResponse`
- Metadata: export `metadata` object or `generateMetadata` from page/layout
- Use `import "server-only"` to prevent client import of server code

### omni-gateway-ts
- Root skill for Omni-Gateway TS, delegates specialized intelligence via `master_routing.md`
- MCP tool discovery via `mcp_registry.json`

### peon-ping-config
- Modifies peon-ping configuration: volume, pack rotation, categories, active pack
- All settings stored in config file; validates before applying

### peon-ping-log
- Log exercise reps for Peon Trainer: `/peon-ping-log N exercise_name`
- Supports pushups, squats, and other rep-based exercises
- Stores logs for streak tracking

### peon-ping-toggle
- Mute/unmute peon-ping sound notifications during a session
- Also handles config changes (volume, packs, categories)
- Applies immediately to current session

### peon-ping-use
- Sets voice pack (character voice) for current chat session
- Enables `session_override` rotation mode if not set
- Takes effect immediately

### playwright
- **If MCP tools available**: navigate → snapshot → interact → screenshot before writing tests (never assume UI structure)
- Test file structure: `base-page.ts`, `helpers.ts`, `{page-name}/{page-name}-page.ts`, `{page-name}.spec.ts`
- Selector priority: `getByRole` > `getByLabel` > `getByText` > `getByTestId` — never CSS selectors
- Reuse existing page objects — never recreate functionality that exists
- Move shared patterns to `BasePage`; utilities to `helpers.ts`
- Test tags: `@critical`, `@e2e`, `@{feature}`, `@{SUITE-ID}-{TEST-ID}`

### preset
- Automatically finds optimal Azure region for model deployment
- Checks current project region first, shows alternatives if capacity insufficient
- Single command — no interactive steps; use `customize` for version/SKU/RAI control

### pytest
- Use classes (`TestX`) for grouping related tests; one assertion concept per test
- Fixtures with `yield` for teardown; scope: `function` (default), `class`, `module`, `session`
- `conftest.py` for shared fixtures across test files
- `pytest.mark.parametrize` for multiple input/output cases
- Mocking: `unittest.mock.patch` as context manager; `MagicMock` for complex objects
- Use `pytest.mark.asyncio` for async test functions
- Register custom markers in `pyproject.toml` under `[tool.pytest.ini_options].markers`

### react-19
- No `useMemo`/`useCallback` — React Compiler handles memoization automatically
- Named imports only: `import { useState } from "react"` — never `import React from "react"`
- Server Components by default; add `"use client"` only for interactivity/hooks (useState, useEffect, events, browser APIs)
- `use()` hook reads promises (suspends) and context (conditional — unlike useContext)
- `useActionState` for form mutations with pending state; `useOptimistic` for optimistic UI
- `ref` is a regular prop — no `forwardRef` needed

### skill-creator
- Skill file structure: `skills/{name}/SKILL.md` + optional `assets/` and `references/`
- Frontmatter: `name`, `description` (includes Trigger), `license` (Apache-2.0), `metadata.author`, `metadata.version`
- Content guidelines: critical patterns first, tables for decisions, minimal code examples
- After creation, register in AGENTS.md skill table
- Don't create for: existing skills, trivial patterns, one-off tasks

### tailwind-4
- Never use `var()` in className: `bg-[var(--color-primary)]` is wrong; use `bg-primary`
- Never use hex colors in className: `text-[#ffffff]` is wrong; use `text-white`
- `cn()` utility (clsx + twMerge) only when merging/conditional classes — not for static classes
- For libraries that can't use className (Recharts), use `style` prop with `var()` constants
- Responsive: `sm:`, `md:`, `lg:` prefixes; dark mode: `dark:` prefix
- style prop for truly dynamic values: `style={{ width: `${x}%` }}`

### typescript
- Const objects first, then extract type: `const X = { ... } as const` → `type X = (typeof X)[keyof typeof X]`
- Flat interfaces — never inline nested objects; extract to dedicated interface
- Never `any` — use `unknown` with type guards, or generics
- Prefer `Pick`, `Omit`, `Partial`, `Required` over redefining types
- Use `import type { X }` for type-only imports
- Type guards: `function isX(val: unknown): val is X`

### zod-4
- Breaking from v3: top-level validators (`z.email()`, `z.uuid()`, `z.url()`), not `z.string().email()`
- `error` parameter replaces `message`: `z.string({ error: "..." })` instead of `z.string({ message: "..." })`
- `z.string().min(1)` replaces `z.string().nonempty()`
- `z.object({ ... }, { error: "..." })` replaces `required_error`
- `safeParse` returns `{ success, data/error }` — prefer over `parse` for user input
- `z.discriminatedUnion("field", [...])` more efficient than `z.union([...])` for tagged unions

### zustand-5
- `create<T>((set) => ({...}))` — no middleware wrapping unless needed
- Selectors to prevent rerenders: `const name = useStore((s) => s.name)` — never grab entire store
- `useShallow` for multiple fields: `useShallow((s) => ({ name: s.name, email: s.email }))`
- `persist` middleware for localStorage persistence (`name: "storage-key"`)
- Async actions: set `loading: true` → await → set result or error
- Slices pattern for large stores: compose multiple `createXSlice` functions
- `immer` middleware for mutable-style state updates

## Project Conventions

| File | Path | Notes |
|------|------|-------|
| AGENTS.md | `D:\D\PROJETOS EM ANDAMENTO\quero_comprar_vg\agent-teams-lite-main\AGENTS.md` | Index — references skills below |
| Agent Teams Lite Orchestrator | `D:\D\PROJETOS EM ANDAMENTO\quero_comprar_vg\agent-teams-lite-main\skills\` | All skills in this subtree |
| skill-resolver protocol | `D:\D\PROJETOS EM ANDAMENTO\quero_comprar_vg\agent-teams-lite-main\skills\_shared\skill-resolver.md` | Shared SDD protocol |
| README.md | `D:\D\PROJETOS EM ANDAMENTO\quero_comprar_vg\README.md` | Project overview, structure, setup |

Read the convention files listed above for project-specific patterns and rules. All referenced paths have been extracted — no need to read index files to discover more.

### Project Tech Stack (auto-detected)

- **Python ≥ 3.11** — pipeline ETL with Polars, httpx, psycopg2
- **Testing**: pytest 8 with pytest-cov, `[tool.pytest.ini_options]` in `pyproject.toml`
- **Linting**: ruff with `line-length = 100`, Python 3.11 target
- **Dependencies**: `pipeline/requirements.txt` (pinned versions)
- **Future**: FastAPI in `backend/`, Next.js in `frontend/` (not yet scaffolded)
