# Parallel Sessions Specification

**Version:** 1.2.0
**Status:** Draft
**Date:** 2026-01-21
**Author:** ar-crawl team
**References:** [Command Line Interface Guidelines](https://clig.dev/)

---

## Executive Summary

Enable ar-crawl to run multiple simultaneous sessions as independent background processes using a `new` prefix that transforms any existing command into a background job. Jobs preserve their full command history for replay.

---

## 1. User Profiles

### User: Automation Engineer

**Role:** DevOps/automation engineer building data pipelines
**Goals:**
- Run multiple crawl jobs in parallel to reduce total processing time
- Monitor job progress across all running instances
- Re-run failed or successful jobs with same parameters

**Constraints:**
- Works primarily via CLI and scripts
- May run dozens of concurrent jobs
- Needs machine-readable output (JSON) for integration

**Daily workflow:**
1. Launch multiple crawl jobs targeting different sites
2. Check status of running jobs periodically
3. Retrieve results as jobs complete
4. Re-run failed jobs after fixing issues
5. Clean up completed jobs

### User: LLM Agent

**Role:** AI agent using ar-crawl as a tool
**Goals:**
- Spawn crawl tasks without blocking on completion
- Query job status programmatically
- Replay previous jobs with modifications

**Constraints:**
- Interacts via JSON-in/JSON-out protocol
- Cannot maintain persistent connections
- Needs idempotent operations

**Daily workflow:**
1. Start crawl job, receive job ID
2. Continue other work while crawl runs
3. Poll for completion or receive notification
4. Optionally re-run job with same or modified parameters

---

## 2. Design Philosophy

### CLI Design Principles (per clig.dev)

**Subcommand Pattern:** `noun verb` - e.g., `jobs status`, `jobs cancel`

**Output Modes:**
- Human-readable by default when stdout is a TTY
- Machine-readable with `--json` or `-j`
- Respect `NO_COLOR` and `TERM=dumb` environment variables
- Progress indicators for operations > 2 seconds

**Flag Conventions:**
- All flags have long form (`--status`) and short form (`-s`) where sensible
- Standard flags: `-h/--help`, `-v/--verbose`, `-q/--quiet`, `-j/--json`, `-o/--output`
- Flags preferred over positional args, except for primary target (job-id, url)

**Error Handling:**
- Errors to stderr, results to stdout
- Human-friendly error messages with actionable suggestions
- Exit code 0 = success, non-zero = failure (see Appendix C)

**Dangerous Operations:**
- Require `--force` or `-f` for destructive batch operations
- Interactive confirmation when TTY available (skipped with `--force` or `--no-input`)

**Configuration Precedence:**
1. Command-line flags (highest priority)
2. Environment variables
3. Project config (`.ar-crawl.yaml` in current directory)
4. User config (`$XDG_CONFIG_HOME/ar-crawl/config.yaml`)
5. System defaults (lowest priority)

**Piping Support:**
- `-` as output file means stdout
- Support reading job IDs from stdin for batch operations

### The `new` Prefix Pattern

Instead of creating a separate `job start` command that duplicates existing command functionality, the `new` prefix transforms ANY existing command into a background job:

```
# Foreground (blocking, current behavior)
ar-crawl crawl https://example.com
ar-crawl crawl-site https://example.com --depth 3
ar-crawl session

# Background (non-blocking, returns job ID)
ar-crawl new crawl https://example.com
ar-crawl new crawl-site https://example.com --depth 3
ar-crawl new session
```

**Benefits:**
- No command duplication
- Any command can become a job
- Familiar syntax - just add `new`
- Future commands automatically support background execution

### Job History Preservation

Every job stores its complete invocation, enabling:
- **Inspection:** See exactly what command was run
- **Replay:** Re-run the exact same job
- **Modification:** Re-run with parameter overrides

---

## 3. Happy Paths

### Happy Path: Parallel Site Crawling

**Preconditions:**
- ar-crawl installed and configured
- Network access to target sites

**Steps:**
1. `ar-crawl new crawl-site https://site1.com --depth 2` → `{"jobId": "abc123", "status": "pending"}`
2. `ar-crawl new crawl-site https://site2.com --depth 2` → `{"jobId": "def456", "status": "pending"}`
3. `ar-crawl jobs` → List of all jobs with status
4. `ar-crawl jobs status abc123` → Detailed job progress
5. `ar-crawl jobs wait abc123` → Blocks until complete
6. `ar-crawl jobs results abc123` → Returns crawl results

**Postconditions:**
- Both sites crawled in parallel
- Results available for retrieval
- Job history preserved

### Happy Path: Job Replay

**Preconditions:**
- Previous job exists in history

**Steps:**
1. `ar-crawl jobs show abc123` → Shows full command that was run
2. `ar-crawl jobs rerun abc123` → Starts new job with same parameters
3. `ar-crawl jobs rerun abc123 --depth 5` → Starts new job with override

**Postconditions:**
- New job created with (optionally modified) parameters
- Original job unchanged
- New job linked to original as "rerun of"

### Happy Path: Interactive Session as Background Job

**Preconditions:**
- ar-crawl installed

**Steps:**
1. `ar-crawl new session` → `{"jobId": "xyz789", "status": "running", "sessionId": "sess-001"}`
2. Job runs session in background, ready for commands
3. `ar-crawl jobs attach xyz789` → Attaches to session REPL
4. User interacts with session
5. `commit output.json` then `exit` → Session ends, job completes

**Postconditions:**
- Session ran as manageable job
- Results saved
- Job history shows session was run

---

## 4. Requirements

### REQ-001: New Prefix for Background Execution

The system SHALL accept a `new` prefix before any command to execute that command as a background job, returning a job ID WITHIN 500ms FOR all users.

**Syntax:**
```
ar-crawl new <command> [command-args...]
```

**Behavior:**
- Validates command and arguments synchronously
- Spawns background process
- Returns job ID immediately
- Original command runs asynchronously

**Acceptance Criteria:**
- `ar-crawl new crawl <url>` returns job ID
- `ar-crawl new crawl-site <url>` returns job ID
- `ar-crawl new session` returns job ID
- `ar-crawl new extract <file>` returns job ID
- Invalid commands rejected with error before spawning

**Trace:**
- TEST-001
- CON-001
- ADR-001

---

### REQ-002: Command Preservation in Job History

The system SHALL store the complete command invocation (command name, arguments, flags, environment) for each job FOR replay and inspection WITH exact reproducibility.

**Stored Data:**
```json
{
  "command": "crawl-site",
  "args": ["https://example.com"],
  "flags": {
    "depth": 3,
    "max-pages": 100,
    "config": "/path/to/config.yaml"
  },
  "env": {
    "PLAYWRIGHT_SERVICE_PORT": "3033"
  },
  "workingDir": "/home/user/project"
}
```

**Acceptance Criteria:**
- All positional arguments preserved
- All flags and their values preserved
- Relevant environment variables captured
- Working directory recorded

**Trace:**
- TEST-002
- CON-002
- REQ-011

---

### REQ-003: Job Listing and Filtering

The system SHALL list all jobs with filtering by status, command type, age, and tags WITHIN 100ms FOR users querying job status WITH JSON and table output formats.

**Acceptance Criteria:**
- List all jobs: `ar-crawl jobs`
- Filter by status: `ar-crawl jobs --status running`
- Filter by command: `ar-crawl jobs --command crawl-site`
- Filter by age: `ar-crawl jobs --since 1h`
- Output as JSON: `ar-crawl jobs --json`

**Trace:**
- TEST-003
- CON-003

---

### REQ-004: Job Status Query

The system SHALL return detailed job status including progress metrics, elapsed time, current phase, and the original command WITHIN 50ms FOR any valid job ID.

**Response Fields:**
- `jobId`: Unique identifier
- `status`: Current state
- `command`: Original command info (from REQ-002)
- `progress`: Percentage complete (if determinable)
- `elapsedMs`: Time since start
- `currentPhase`: What the job is doing now
- `errors`: Array of encountered errors

**Trace:**
- TEST-004
- CON-004

---

### REQ-005: Job Cancellation

The system SHALL cancel running or pending jobs WITHIN 1s of cancellation request FOR authorized users WITH graceful shutdown preserving partial results.

**Acceptance Criteria:**
- Cancel command: `ar-crawl jobs cancel <job-id>`
- Running jobs complete current operation before stopping
- Partial results are preserved
- Resources are cleaned up

**Trace:**
- TEST-005
- CON-005

---

### REQ-006: Result Retrieval

The system SHALL return job results in requested format FOR completed jobs WITH results persisted until explicit cleanup or TTL expiration.

**Acceptance Criteria:**
- Get results: `ar-crawl jobs results <job-id>`
- Output format: `ar-crawl jobs results <job-id> --format csv`
- Save to file: `ar-crawl jobs results <job-id> -o results.json`
- Results available for 24h by default (configurable)

**Trace:**
- TEST-006
- CON-006

---

### REQ-007: Dynamic Port Allocation

The system SHALL allocate unique ports for Playwright service instances automatically WHEN multiple background jobs require browser services FOR parallel execution.

**Acceptance Criteria:**
- Port range: `AR_CRAWL_PORT_RANGE=3033-3043` (default)
- Automatic port selection from available range
- Port conflicts detected and handled
- Port released on process termination

**Trace:**
- TEST-007
- ADR-002

---

### REQ-008: Job Registry Persistence

The system SHALL persist job metadata and command history to a registry WITHIN 100ms of state changes FOR cross-process visibility and replay WITH atomic writes.

**Registry Location:** `~/.ar-crawl/jobs.db` (SQLite)

**Acceptance Criteria:**
- Job metadata survives process restarts
- Command history preserved indefinitely (configurable)
- Concurrent writes are safe
- Registry queryable by any CLI process

**Trace:**
- TEST-008
- ADR-003

---

### REQ-009: Resource Limits

The system SHALL enforce configurable limits on concurrent jobs WHEN resource thresholds are exceeded FOR system stability WITH queuing of excess jobs.

**Default Limits:**
- Max concurrent jobs: 10 (configurable)
- Max pending in queue: 100

**Acceptance Criteria:**
- Jobs queued when at capacity
- Clear status showing queue position
- Configurable via config or environment

**Trace:**
- TEST-009
- CON-007

---

### REQ-010: Job Cleanup

The system SHALL support manual cleanup of job data WITH automatic cleanup of results after configurable TTL (default 24h) while preserving command history.

**Acceptance Criteria:**
- Clean results: `ar-crawl jobs clean <job-id>`
- Clean all old results: `ar-crawl jobs clean --before 7d`
- Command history preserved separately (for replay)
- Running jobs never cleaned

**Trace:**
- TEST-010
- CON-008

---

### REQ-011: Job Replay

The system SHALL re-run any historical job with identical or modified parameters FOR users wanting to repeat operations WITH new job ID assigned.

**Syntax:**
```
ar-crawl jobs rerun <job-id> [--override-flag value...]
```

**Behavior:**
1. Retrieve original command from job history
2. Apply any override flags
3. Execute as new background job
4. Link new job to original (`rerunOf: <original-id>`)

**Acceptance Criteria:**
- `ar-crawl jobs rerun abc123` runs exact same command
- `ar-crawl jobs rerun abc123 --depth 5` overrides depth
- New job created (original unchanged)
- Lineage tracked

**Trace:**
- TEST-011
- CON-009
- REQ-002

---

### REQ-012: Job Show (Inspect History)

The system SHALL display the complete stored command for any job FOR inspection and manual replay WITH copy-pasteable output.

**Output:**
```
Job: abc123
Status: completed
Created: 2026-01-21 10:30:00

Command:
  ar-crawl crawl-site https://example.com --depth 3 --max-pages 100

Config: /home/user/.ar-crawl/config.yaml
Working Dir: /home/user/project

To rerun: ar-crawl jobs rerun abc123
```

**Trace:**
- TEST-012
- CON-010

---

### REQ-013: Job Attach (For Sessions)

The system SHALL allow attaching to running interactive session jobs FOR continued interaction WITH the session REPL.

**Syntax:**
```
ar-crawl jobs attach <job-id>
```

**Behavior:**
- Connects stdin/stdout to running session
- Session continues from current state
- Detach returns to shell (session keeps running)

**Acceptance Criteria:**
- Only works for `session` command jobs
- Error if job not running or not a session
- Multiple attaches not allowed simultaneously

**Trace:**
- TEST-013
- CON-011

---

### REQ-014: Human-Friendly Error Messages

The system SHALL output errors to stderr in human-readable format WITH actionable suggestions FOR resolving the error.

**Error Format:**
```
error: Job 'abc123' not found

The job ID may have been cleaned up or never existed.

Try:
  ar-crawl jobs              # List all jobs
  ar-crawl jobs --since 7d   # Include older jobs
```

**Acceptance Criteria:**
- Errors go to stderr, results to stdout
- Error includes what went wrong
- Error includes suggested fix when possible
- Exit code reflects error type (see Appendix C)

**Trace:**
- TEST-019

---

### REQ-015: TTY-Aware Output

The system SHALL detect TTY and format output accordingly FOR optimal human and machine consumption.

**Behavior:**
- TTY detected: colored output, progress spinners, interactive prompts
- No TTY (pipe/redirect): plain output, no colors, no prompts, no progress
- `NO_COLOR` env set: disable colors even on TTY
- `--json` flag: always machine-readable regardless of TTY

**Acceptance Criteria:**
- `ar-crawl jobs | cat` produces plain text
- `ar-crawl jobs` in terminal shows colors and formatting
- `NO_COLOR=1 ar-crawl jobs` shows no colors

**Trace:**
- TEST-020

---

## 5. Non-Functional Requirements

### NFR-001: Job Start Latency

Job start (via `new` prefix) SHALL return job ID in ≤ 500ms UNDER normal load WITH 95th percentile.

**Trace:**
- TEST-014

---

### NFR-002: Job List Latency

Job list query SHALL complete in ≤ 100ms UNDER 1000 jobs WITH 95th percentile.

**Trace:**
- TEST-015

---

### NFR-003: History Retention

Command history SHALL be retained for ≥ 90 days by default FOR replay capability WITH configurable retention period.

**Trace:**
- TEST-016

---

### NFR-004: Memory Efficiency

Each background job process SHALL use ≤ 512MB RSS memory UNDER typical crawl workloads WITH 90th percentile.

**Trace:**
- TEST-017
- OBS-001

---

## 6. Architecture Decisions

### ADR-001: `new` Prefix Pattern

**Context:** Need to run existing commands as background jobs without duplicating command definitions.

**Decision:** Implement a `new` meta-command that wraps any existing command for background execution.

**Alternatives Considered:**
1. **Separate `job start` command:** Rejected - Requires duplicating all command arguments; maintenance burden.
2. **`--background` flag on each command:** Rejected - Must modify every command; inconsistent implementation.
3. **`&` shell backgrounding:** Rejected - Loses job tracking; no cross-process visibility.

**Implementation:**
```
ar-crawl new <command> [args...]
         ↓
1. Parse and validate <command> [args...] without executing
2. Serialize command to job record
3. Spawn: ar-crawl --job-mode <job-id> <command> [args...]
4. Return job ID to user
```

**Consequences:**
- (+) Any command automatically supports background execution
- (+) Single implementation point
- (+) Command validation before spawning
- (-) Slightly more complex argument parsing

**Trace:**
- REQ-001

---

### ADR-002: File-Based Job Registry with SQLite

**Context:** Multiple CLI processes need shared visibility into job state and history.

**Decision:** Use SQLite database at `~/.ar-crawl/jobs.db` for job registry and history.

**Schema Highlights:**
- `jobs` table: Current state, process info
- `job_history` table: Command preservation for replay
- Indexes on status, created_at, command

**Consequences:**
- (+) ACID transactions for state changes
- (+) Efficient queries with indexes
- (+) Command history preserved indefinitely
- (-) SQLite dependency

**Trace:**
- REQ-008

---

### ADR-003: Port Pool for Playwright Services

**Context:** Each job process may need its own Playwright service; fixed port causes conflicts.

**Decision:** Implement port pool with automatic allocation from configurable range.

**Algorithm:**
1. Read port range from config (default 3033-3043)
2. Query registry for ports in use by running jobs
3. Select first available port
4. Register port claim atomically with job
5. Release port on job completion/termination

**Consequences:**
- (+) Multiple simultaneous Playwright services
- (+) Automatic conflict resolution
- (-) Port exhaustion if too many concurrent jobs (mitigated by job limits)

**Trace:**
- REQ-007

---

### ADR-004: Command Serialization Format

**Context:** Need to store commands for replay with exact reproducibility.

**Decision:** Store commands as structured JSON, not as shell strings.

**Format:**
```json
{
  "command": "crawl-site",
  "positionalArgs": ["https://example.com"],
  "flags": {
    "depth": {"value": 3, "type": "integer"},
    "config": {"value": "/path/to/config.yaml", "type": "path"}
  },
  "capturedEnv": ["PLAYWRIGHT_SERVICE_PORT"],
  "workingDir": "/home/user/project"
}
```

**Rationale:**
- Shell strings are fragile (escaping, quoting issues)
- Structured format enables flag overrides in rerun
- Type information enables proper reconstruction

**Consequences:**
- (+) Reliable replay
- (+) Easy flag overrides
- (+) No shell injection risks
- (-) More complex serialization

**Trace:**
- REQ-002, REQ-011

---

## 7. Contracts

### CON-001: New Command Interface

**Endpoint:** CLI command `ar-crawl new <command> [args...]`

**Pre-conditions:**
- `<command>` is a valid ar-crawl command
- Arguments are valid for that command
- System has capacity for new job

**Post-conditions:**
- Job created with unique ID
- Job registered in registry with full command
- Background process spawned
- Job ID returned to caller

**Input:**
```
ar-crawl new crawl-site https://example.com --depth 3
ar-crawl new crawl https://example.com --config custom.yaml
ar-crawl new session
ar-crawl new extract input.html --fields '{"title": "//h1"}'
```

**Output (JSON):**
```json
{
  "jobId": "550e8400-e29b-41d4-a716-446655440000",
  "status": "pending",
  "command": "crawl-site",
  "url": "https://example.com"
}
```

**Error model:**
- `INVALID_COMMAND`: Command not recognized
- `INVALID_ARGS`: Arguments invalid for command
- `CAPACITY_EXCEEDED`: Too many concurrent jobs

**Implements:**
- REQ-001

**Verified by:**
- TEST-001

---

### CON-002: Jobs List Interface

**Endpoint:** CLI command `ar-crawl jobs [options]`

**Pre-conditions:** None

**Post-conditions:** List of jobs returned matching filters

**Input:**
```
ar-crawl jobs
ar-crawl jobs -s running              # or --status
ar-crawl jobs -c crawl-site           # or --command
ar-crawl jobs --since 1h
ar-crawl jobs -j                      # or --json
ar-crawl jobs -q                      # or --quiet (just IDs, one per line)
```

**Output (Table, default):**
```
JOB ID       STATUS     COMMAND      TARGET                   STARTED    PROGRESS
abc123       running    crawl-site   https://example.com      2m ago     45%
def456       completed  crawl        https://other.com        15m ago    100%
xyz789       pending    session      -                        1m ago     -
```

**Output (JSON):**
```json
{
  "jobs": [
    {
      "jobId": "abc123",
      "status": "running",
      "command": "crawl-site",
      "target": "https://example.com",
      "createdAt": "2026-01-21T10:30:00Z",
      "progress": 45
    }
  ],
  "total": 3
}
```

**Implements:**
- REQ-003

**Verified by:**
- TEST-003

---

### CON-003: Jobs Status Interface

**Endpoint:** CLI command `ar-crawl jobs status <job-id>`

**Pre-conditions:**
- Job ID exists in registry

**Post-conditions:** Detailed status returned

**Output (JSON):**
```json
{
  "jobId": "abc123",
  "status": "running",
  "command": {
    "name": "crawl-site",
    "args": ["https://example.com"],
    "flags": {"depth": 3, "max-pages": 100}
  },
  "createdAt": "2026-01-21T10:30:00Z",
  "startedAt": "2026-01-21T10:30:01Z",
  "elapsedMs": 120000,
  "progress": 45,
  "pagesProcessed": 23,
  "currentPhase": "crawling",
  "currentUrl": "https://example.com/page/5",
  "errors": []
}
```

**Error model:**
- `JOB_NOT_FOUND`: Job ID does not exist

**Implements:**
- REQ-004

**Verified by:**
- TEST-004

---

### CON-004: Jobs Cancel Interface

**Endpoint:** CLI command `ar-crawl jobs cancel <job-id>`

**Pre-conditions:**
- Job exists
- Job is in `pending` or `running` state

**Post-conditions:**
- Job state changed to `cancelled`
- Background process terminated
- Partial results preserved

**Output:**
```json
{
  "jobId": "abc123",
  "status": "cancelled",
  "message": "Job cancelled, partial results preserved"
}
```

**Error model:**
- `JOB_NOT_FOUND`: Job ID does not exist
- `INVALID_STATE`: Job already in terminal state

**Implements:**
- REQ-005

**Verified by:**
- TEST-005

---

### CON-005: Jobs Results Interface

**Endpoint:** CLI command `ar-crawl jobs results <job-id> [options]`

**Pre-conditions:**
- Job exists
- Job is in terminal state (completed/failed/cancelled)

**Post-conditions:** Results returned or written to file

**Input:**
```
ar-crawl jobs results abc123
ar-crawl jobs results abc123 --format csv
ar-crawl jobs results abc123 -o results.json    # or --output
ar-crawl jobs results abc123 -o -               # output to stdout (for piping)
```

**Error model:**
- `JOB_NOT_FOUND`: Job ID does not exist
- `JOB_NOT_COMPLETE`: Job still running
- `RESULTS_EXPIRED`: Results cleaned up (but history preserved)

**Implements:**
- REQ-006

**Verified by:**
- TEST-006

---

### CON-006: Jobs Wait Interface

**Endpoint:** CLI command `ar-crawl jobs wait <job-id> [options]`

**Pre-conditions:**
- Job exists

**Post-conditions:**
- Blocks until job reaches terminal state
- Returns final status

**Input:**
```
ar-crawl jobs wait abc123
ar-crawl jobs wait abc123 -t 5m               # or --timeout
ar-crawl jobs wait abc123 -p                  # or --progress (show live updates)
ar-crawl jobs wait abc123 abc456 xyz789       # wait for multiple jobs
cat job-ids.txt | ar-crawl jobs wait -        # read job IDs from stdin
```

**Behavior:**
- Without `--progress`: blocks silently, returns final status
- With `--progress`: shows live progress updates (spinner, percentage)
- Multiple jobs: waits for all, returns combined status

**Error model:**
- `JOB_NOT_FOUND`: Job ID does not exist
- `TIMEOUT`: Wait timeout exceeded (exit code 124)

**Implements:**
- REQ-001

**Verified by:**
- TEST-018

---

### CON-007: Jobs Show Interface

**Endpoint:** CLI command `ar-crawl jobs show <job-id>`

**Pre-conditions:**
- Job exists in history

**Post-conditions:** Full command information displayed

**Output:**
```
Job: abc123
Status: completed
Created: 2026-01-21 10:30:00
Duration: 2m 34s

Command:
  ar-crawl crawl-site https://example.com --depth 3 --max-pages 100

Config: ~/.ar-crawl/config.yaml
Working Dir: /home/user/project

Rerun: ar-crawl jobs rerun abc123
```

**Implements:**
- REQ-012

**Verified by:**
- TEST-012

---

### CON-008: Jobs Rerun Interface

**Endpoint:** CLI command `ar-crawl jobs rerun <job-id> [--overrides...]`

**Pre-conditions:**
- Job exists in history
- Command is still valid

**Post-conditions:**
- New job created
- New job linked to original
- Background process spawned

**Input:**
```
ar-crawl jobs rerun abc123
ar-crawl jobs rerun abc123 --depth 5
ar-crawl jobs rerun abc123 --max-pages 200 --depth 5
```

**Output:**
```json
{
  "jobId": "newjob456",
  "status": "pending",
  "rerunOf": "abc123",
  "command": "crawl-site",
  "overrides": {"depth": 5}
}
```

**Error model:**
- `JOB_NOT_FOUND`: Original job not in history
- `INVALID_OVERRIDE`: Override flag not valid for command

**Implements:**
- REQ-011

**Verified by:**
- TEST-011

---

### CON-009: Jobs Attach Interface

**Endpoint:** CLI command `ar-crawl jobs attach <job-id>`

**Pre-conditions:**
- Job exists and is running
- Job is a `session` command

**Post-conditions:**
- Terminal attached to session REPL
- User can interact with session

**Error model:**
- `JOB_NOT_FOUND`: Job does not exist
- `JOB_NOT_RUNNING`: Job not in running state
- `NOT_A_SESSION`: Job is not a session command
- `ALREADY_ATTACHED`: Another terminal is attached

**Implements:**
- REQ-013

**Verified by:**
- TEST-013

---

### CON-010: Jobs Clean Interface

**Endpoint:** CLI command `ar-crawl jobs clean [options]`

**Pre-conditions:** None

**Post-conditions:**
- Matching job results removed
- Command history optionally preserved

**Input:**
```
ar-crawl jobs clean abc123              # Clean specific job (no confirm needed)
ar-crawl jobs clean --before 7d         # Prompts: "Clean 15 jobs? [y/N]"
ar-crawl jobs clean --before 7d -f      # or --force: skip confirmation
ar-crawl jobs clean -s completed        # or --status: clean by status
ar-crawl jobs clean --purge abc123      # Remove entirely (including history)
ar-crawl jobs clean --dry-run           # Show what would be cleaned
```

**Confirmation Behavior:**
- Single job ID: no confirmation required
- Batch operations (`--before`, `--status`, `--all`): requires confirmation OR `--force`
- When stdin is not a TTY: requires `--force` for batch operations
- `--dry-run`: shows what would be cleaned without doing it

**Output:**
```json
{
  "cleaned": 5,
  "freedBytes": 12456000,
  "historyPreserved": true
}
```

**Error model:**
- `CONFIRMATION_REQUIRED`: Batch operation without --force and no TTY

**Implements:**
- REQ-010

**Verified by:**
- TEST-010

---

## 8. Test Specifications

### TEST-001: New Prefix Background Execution

**Objective:** Verify `new` prefix executes commands in background

**Scenario:**
1. Run `ar-crawl new crawl https://httpbin.org/delay/5`
2. Measure time for command to return
3. Verify job ID returned
4. Query job status

**Expected Results:**
- Command returns in < 500ms
- Job ID is valid UUID
- Job status shows `running` or `pending`

**Trace:**
- REQ-001, CON-001

---

### TEST-002: Command Preservation

**Objective:** Verify commands are stored correctly

**Scenario:**
1. Run `ar-crawl new crawl-site https://example.com --depth 3 --max-pages 50`
2. Query `ar-crawl jobs show <job-id>`
3. Verify all arguments preserved

**Expected Results:**
- Command name: `crawl-site`
- URL preserved
- `--depth 3` preserved
- `--max-pages 50` preserved

**Trace:**
- REQ-002, CON-007

---

### TEST-003: Multiple Command Types

**Objective:** Verify `new` works with different commands

**Scenario:**
1. `ar-crawl new crawl https://example.com`
2. `ar-crawl new crawl-site https://example.com`
3. `ar-crawl new session`
4. `ar-crawl jobs`

**Expected Results:**
- All three jobs created
- Each shows correct command type
- All running independently

**Trace:**
- REQ-001

---

### TEST-004: Concurrent Job Execution

**Objective:** Verify multiple jobs run in parallel

**Scenario:**
1. Start 5 jobs targeting `/delay/2` endpoints
2. Wait for all to complete
3. Measure total time

**Expected Results:**
- Total time < 5s (parallel execution)
- All jobs complete successfully

**Trace:**
- REQ-001, REQ-007

---

### TEST-005: Job Cancellation

**Objective:** Verify jobs can be cancelled

**Scenario:**
1. Start long-running job
2. Cancel while running
3. Query status and results

**Expected Results:**
- Cancel succeeds
- Status is `cancelled`
- Partial results available

**Trace:**
- REQ-005, CON-004

---

### TEST-006: Job Rerun

**Objective:** Verify job replay works

**Scenario:**
1. Complete a job with specific flags
2. `ar-crawl jobs rerun <job-id>`
3. Verify new job has same command
4. `ar-crawl jobs rerun <job-id> --depth 10`
5. Verify override applied

**Expected Results:**
- Rerun creates new job
- Same command preserved
- Override modifies specific flag only
- `rerunOf` links to original

**Trace:**
- REQ-011, CON-008

---

### TEST-007: Port Allocation

**Objective:** Verify dynamic port allocation

**Scenario:**
1. Start job 1, note port
2. Start job 2, note port
3. Verify ports differ
4. Complete job 1
5. Start job 3, verify port reuse possible

**Expected Results:**
- Jobs get unique ports
- Ports released after completion

**Trace:**
- REQ-007, ADR-003

---

### TEST-008: Cross-Process Visibility

**Objective:** Verify jobs visible across CLI invocations

**Scenario:**
1. Start job from terminal A
2. Query `ar-crawl jobs` from terminal B
3. Cancel from terminal B

**Expected Results:**
- Job visible from terminal B
- Cancel works from terminal B

**Trace:**
- REQ-008

---

### TEST-009: Session Attach

**Objective:** Verify attaching to session jobs

**Scenario:**
1. `ar-crawl new session`
2. `ar-crawl jobs attach <job-id>`
3. Send commands through attached session
4. Detach

**Expected Results:**
- Attach connects to REPL
- Commands work
- Session continues after detach

**Trace:**
- REQ-013, CON-009

---

### TEST-010: History Preservation After Clean

**Objective:** Verify history survives result cleanup

**Scenario:**
1. Complete a job
2. `ar-crawl jobs clean <job-id>`
3. `ar-crawl jobs show <job-id>`
4. `ar-crawl jobs rerun <job-id>`

**Expected Results:**
- Results removed
- History still shows command
- Rerun still works

**Trace:**
- REQ-010, REQ-002

---

## 9. Observability

### OBS-001: Job Metrics

**Metrics:**
- `ar_crawl_jobs_total{status, command}`: Counter by status and command type
- `ar_crawl_jobs_active`: Gauge of running jobs
- `ar_crawl_job_duration_seconds{command}`: Histogram by command
- `ar_crawl_job_reruns_total`: Counter of rerun operations

**Trace:**
- NFR-004

---

### OBS-002: Job Logs

**Log events:**
- `{event: "job_created", jobId, command, args}`
- `{event: "job_started", jobId, port, pid}`
- `{event: "job_completed", jobId, status, duration}`
- `{event: "job_rerun", jobId, originalJobId, overrides}`

**Location:** `~/.ar-crawl/logs/jobs.jsonl`

---

## 10. CLI Command Summary

```
# Start background jobs (new prefix)
ar-crawl new <command> [args...]       # Run any command as background job
ar-crawl new crawl <url>               # Background single-page crawl
ar-crawl new crawl-site <url>          # Background site crawl
ar-crawl new session                   # Background interactive session
ar-crawl new extract <file>            # Background extraction

# Manage jobs (noun-verb pattern)
ar-crawl jobs                          # List all jobs
ar-crawl jobs [-s STATUS] [-c CMD] [-j]  # Filter and format options
ar-crawl jobs status <job-id>          # Detailed job status
ar-crawl jobs show <job-id>            # Show stored command (for replay)
ar-crawl jobs wait <job-id> [-t TIMEOUT] [-p]  # Wait for completion
ar-crawl jobs results <job-id> [-o FILE]       # Get job results
ar-crawl jobs cancel <job-id>          # Cancel running job
ar-crawl jobs rerun <job-id> [--flags] # Rerun with optional overrides
ar-crawl jobs attach <job-id>          # Attach to session job
ar-crawl jobs clean [options] [-f]     # Clean up old jobs
ar-crawl jobs logs <job-id> [-f]       # View/follow job logs

# Common flags (available on most commands)
-h, --help          Show help
-j, --json          JSON output
-q, --quiet         Minimal output
-v, --verbose       Verbose output
-f, --force         Skip confirmations
-o, --output FILE   Output to file (use - for stdout)
```

---

## Appendix A: Registry Schema

```sql
-- Job state and metadata
CREATE TABLE jobs (
  id TEXT PRIMARY KEY,
  status TEXT NOT NULL DEFAULT 'pending',
  pid INTEGER,
  port INTEGER,
  created_at INTEGER NOT NULL,
  started_at INTEGER,
  completed_at INTEGER,
  progress INTEGER DEFAULT 0,
  current_phase TEXT,
  result_file TEXT,
  error TEXT,
  rerun_of TEXT,  -- Links to original job if this is a rerun
  FOREIGN KEY (rerun_of) REFERENCES jobs(id)
);

-- Command history (preserved separately for replay)
CREATE TABLE job_commands (
  job_id TEXT PRIMARY KEY,
  command TEXT NOT NULL,
  positional_args TEXT,  -- JSON array
  flags TEXT,            -- JSON object
  captured_env TEXT,     -- JSON object
  working_dir TEXT,
  config_file TEXT,
  created_at INTEGER NOT NULL,
  FOREIGN KEY (job_id) REFERENCES jobs(id)
);

-- Port allocations
CREATE TABLE port_allocations (
  port INTEGER PRIMARY KEY,
  job_id TEXT NOT NULL,
  allocated_at INTEGER NOT NULL,
  FOREIGN KEY (job_id) REFERENCES jobs(id)
);

-- Indexes
CREATE INDEX idx_jobs_status ON jobs(status);
CREATE INDEX idx_jobs_created ON jobs(created_at);
CREATE INDEX idx_jobs_rerun ON jobs(rerun_of);
CREATE INDEX idx_commands_command ON job_commands(command);
```

---

## Appendix B: Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `XDG_DATA_HOME` | `~/.local/share` | XDG base directory for data |
| `XDG_CONFIG_HOME` | `~/.config` | XDG base directory for config |
| `AR_CRAWL_MAX_JOBS` | `10` | Maximum concurrent jobs |
| `AR_CRAWL_PORT_RANGE` | `3033-3043` | Port range for Playwright |
| `AR_CRAWL_RESULT_TTL` | `86400` | Result TTL in seconds (24h) |
| `AR_CRAWL_HISTORY_TTL` | `7776000` | History TTL in seconds (90d) |
| `NO_COLOR` | (unset) | Disable colored output when set |
| `AR_CRAWL_NO_PROGRESS` | (unset) | Disable progress indicators when set |

**File Locations (XDG Compliant):**
- Data/Jobs: `$XDG_DATA_HOME/ar-crawl/` (default: `~/.local/share/ar-crawl/`)
- Config: `$XDG_CONFIG_HOME/ar-crawl/config.yaml` (default: `~/.config/ar-crawl/config.yaml`)
- Logs: `$XDG_DATA_HOME/ar-crawl/logs/`

---

## Appendix C: Exit Codes

| Code | Meaning | Example |
|------|---------|---------|
| `0` | Success | Command completed successfully |
| `1` | General error | Unspecified failure |
| `2` | Invalid usage | Bad arguments, unknown flag |
| `3` | Job not found | Invalid job ID |
| `4` | Invalid state | Cancel on completed job |
| `5` | Capacity exceeded | Too many concurrent jobs |
| `10` | Network error | Failed to reach target URL |
| `11` | Service error | Playwright service unavailable |
| `124` | Timeout | `jobs wait --timeout` exceeded |
| `130` | Interrupted | User pressed Ctrl-C |

---

## Appendix D: Help Text Requirements

Each command MUST provide:
1. **Synopsis**: One-line usage pattern
2. **Description**: 1-2 sentence explanation
3. **Examples**: At least 2 practical examples (most common first)
4. **Flags**: All flags with short and long forms
5. **See Also**: Related commands

**Example help output for `ar-crawl jobs`:**
```
Usage: ar-crawl jobs [options]

List and filter background jobs.

Examples:
  ar-crawl jobs                     # List all jobs
  ar-crawl jobs -s running          # Show only running jobs
  ar-crawl jobs -j | jq '.jobs[]'   # Pipe JSON to jq

Options:
  -s, --status <status>   Filter by status (pending|running|completed|failed|cancelled)
  -c, --command <cmd>     Filter by command type
      --since <duration>  Show jobs started within duration (e.g., 1h, 2d)
  -j, --json              Output as JSON
  -q, --quiet             Output only job IDs, one per line
  -h, --help              Show this help

See also: jobs status, jobs show, jobs wait
```

---

**END OF SPECIFICATION**
