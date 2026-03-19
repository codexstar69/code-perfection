import { Type } from "@sinclair/typebox";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { join, dirname } from "node:path";

export default function (pi: ExtensionAPI) {
  const SKILL_DIR = join(dirname(__dirname), "skills", "code-perfection");
  const scriptsDir = join(SKILL_DIR, "scripts");

  // Cache reference file contents keyed by path, with mtime for invalidation
  const refCache = new Map<string, { mtime: number; content: string }>();

  const SCRIPT_TIMEOUT_MS = 120_000;
  const MAX_BUFFER = 10 * 1024 * 1024;
  const RETRYABLE_SIGNALS = new Set(["SIGTERM", "SIGKILL", "SIGHUP"]);
  const MAX_RETRIES = 2;

  function runScriptOnce(scriptPath: string, args: string[], cwd: string): { exitCode: number; output: string; retryable: boolean } {
    try {
      const output = execFileSync(scriptPath, args, {
        cwd,
        encoding: "utf-8",
        timeout: SCRIPT_TIMEOUT_MS,
        maxBuffer: MAX_BUFFER,
      });
      return { exitCode: 0, output, retryable: false };
    } catch (err: any) {
      const stdout = typeof err.stdout === "string" ? err.stdout : "";
      const stderr = typeof err.stderr === "string" ? err.stderr : "";
      const combined = (stdout + stderr).trim();
      const exitCode = typeof err.status === "number" ? err.status : 1;
      const signal: string | null = err.signal ?? null;

      // Determine if this is a transient failure worth retrying
      const isTimeout = err.killed === true && signal === "SIGTERM";
      const isTransientSignal = signal !== null && RETRYABLE_SIGNALS.has(signal);
      const retryable = isTimeout || isTransientSignal;

      const signalSuffix = signal ? ` (signal: ${signal})` : "";
      const timeoutPrefix = isTimeout ? "[TIMEOUT] " : "";
      return {
        exitCode,
        output: `${timeoutPrefix}${combined || `${err.message}${signalSuffix}`}`,
        retryable,
      };
    }
  }

  function runScript(script: string, args: string[] = [], cwd?: string): { exitCode: number; output: string } {
    const scriptPath = join(scriptsDir, script);
    if (!existsSync(scriptPath)) {
      return { exitCode: 127, output: `Script not found: ${scriptPath}` };
    }
    const resolvedCwd = cwd || process.cwd();

    let lastResult = runScriptOnce(scriptPath, args, resolvedCwd);
    for (let attempt = 1; attempt < MAX_RETRIES && lastResult.retryable; attempt++) {
      lastResult = runScriptOnce(scriptPath, args, resolvedCwd);
    }
    return { exitCode: lastResult.exitCode, output: lastResult.output };
  }

  function readRef(name: string): string {
    const refPath = join(SKILL_DIR, "references", name);
    try {
      const mtime = statSync(refPath).mtimeMs;
      const cached = refCache.get(refPath);
      if (cached && cached.mtime === mtime) {
        return cached.content;
      }
      const content = readFileSync(refPath, "utf-8");
      refCache.set(refPath, { mtime, content });
      return content;
    } catch {
      return `[ERROR: Reference file not found: ${refPath}]`;
    }
  }

  // --- Tools ---

  // verify
  pi.registerTool({
    name: "codeperfect_verify",
    label: "Code Perfection: Verify",
    description:
      "Run the 8-point verification checklist — compiles, tests pass, no any types, no secrets, no dead code, no scope creep. Returns PASS/FAIL with details.",
    parameters: Type.Object({
      changed_files: Type.Optional(
        Type.Array(Type.String(), {
          description: "Specific files to check. If omitted, auto-detects from git diff.",
        })
      ),
    }),
    async execute(toolCallId, params) {
      const args = params.changed_files ? ["--changed-files", ...params.changed_files] : [];
      const result = runScript("verify.sh", args);
      return {
        content: [{ type: "text", text: result.output }],
        details: { exitCode: result.exitCode, passed: result.exitCode === 0 },
      };
    },
  });

  // resolution loop
  pi.registerTool({
    name: "codeperfect_loop",
    label: "Code Perfection: Resolution Loop",
    description:
      "Manage the resolution loop issue ledger. Enforces fix-verify-decide cycles with auto-revert on failure and auto-defer after 3 attempts. Commands:\n" +
      "- init: args=[target-dir] — initialize the ledger\n" +
      "- add: args=[file, line, severity, description] — add an issue (severity: critical/high/medium/low)\n" +
      "- start: args=[ISS-N] — mark issue in-progress and acquire lock\n" +
      "- resolve: args=[ISS-N] — mark done, auto-commit, release lock\n" +
      "- fail: args=[ISS-N, reason] — auto-revert changes, record failure, release lock\n" +
      "- status: no args — exit code 0 = all done, 1 = issues remain (loop must continue)\n" +
      "- report: no args — generate final markdown report",
    parameters: Type.Object({
      command: Type.Union(
        [
          Type.Literal("init"),
          Type.Literal("scan"),
          Type.Literal("add"),
          Type.Literal("start"),
          Type.Literal("resolve"),
          Type.Literal("fail"),
          Type.Literal("status"),
          Type.Literal("report"),
        ],
        { description: "The resolution loop command to run" }
      ),
      args: Type.Optional(
        Type.Array(Type.String(), {
          description:
            "Command arguments: init=[target], add=[file, line, severity, description], start/resolve=[ISS-N], fail=[ISS-N, reason]",
        })
      ),
    }),
    async execute(toolCallId, params) {
      const result = runScript("resolution-loop.sh", [params.command, ...(params.args || [])]);
      return {
        content: [{ type: "text", text: result.output }],
        details: { exitCode: result.exitCode, command: params.command },
      };
    },
  });

  // audit state
  pi.registerTool({
    name: "codeperfect_audit",
    label: "Code Perfection: Audit State",
    description:
      "Manage large codebase audit state. Enforces one-domain-at-a-time processing with resume-safe persistence. Commands:\n" +
      "- init: args=[target] — initialize audit from triage.json\n" +
      "- status: no args — show progress for all domains\n" +
      "- next-domain: no args — returns NEXT/RESUME/ALL_DOMAINS_DONE\n" +
      "- start-domain: args=[name] — mark domain in-progress (fails if another is active)\n" +
      "- complete-domain: args=[name] — mark domain done, archive its issues\n" +
      "- find-boundaries: args=[target] — discover cross-domain import boundaries\n" +
      "- start-boundary: args=[pair] — mark boundary pair in-progress\n" +
      "- complete-boundary: args=[pair] — mark boundary pair done\n" +
      "- report: no args — generate final audit report",
    parameters: Type.Object({
      command: Type.Union(
        [
          Type.Literal("init"),
          Type.Literal("status"),
          Type.Literal("next-domain"),
          Type.Literal("start-domain"),
          Type.Literal("complete-domain"),
          Type.Literal("find-boundaries"),
          Type.Literal("start-boundary"),
          Type.Literal("complete-boundary"),
          Type.Literal("merge-findings"),
          Type.Literal("report"),
        ],
        { description: "The audit state command to run" }
      ),
      args: Type.Optional(
        Type.Array(Type.String(), {
          description:
            "Command arguments: init/find-boundaries=[target], start-domain/complete-domain=[name], start-boundary/complete-boundary=[pair]",
        })
      ),
    }),
    async execute(toolCallId, params) {
      const result = runScript("audit-state.sh", [params.command, ...(params.args || [])]);
      return {
        content: [{ type: "text", text: result.output }],
        details: { exitCode: result.exitCode, command: params.command },
      };
    },
  });

  // triage
  pi.registerTool({
    name: "codeperfect_triage",
    label: "Code Perfection: Triage",
    description:
      "Structural recon — discovers domains, classifies by risk tier (CRITICAL/HIGH/MEDIUM/LOW), counts files. Zero code reading. Writes .codeperfect/triage.json.",
    parameters: Type.Object({
      target: Type.Optional(
        Type.String({
          description: "Target directory to triage. Defaults to current directory.",
          default: ".",
        })
      ),
    }),
    async execute(toolCallId, params) {
      const result = runScript("triage.sh", [params.target || "."]);
      return {
        content: [{ type: "text", text: result.output }],
        details: { exitCode: result.exitCode },
      };
    },
  });

  // --- Commands ---
  pi.registerCommand("code-perfection", {
    description: "Run the Code Perfection resolution loop on a target directory",
    async handler(args, ctx) {
      const target = args.trim() || ".";
      const agentsMd = readRef("agents.md");
      const loopMd = readRef("resolution-loop.md");

      await ctx.waitForIdle();
      pi.sendMessage(
        `# Code Perfection — Resolution Loop\n\nTarget: \`${target}\`\n\n` +
          `## Code Standards\n\n${agentsMd}\n\n## Resolution Loop Protocol\n\n${loopMd}\n\n` +
          `## Severity Classification\n\n` +
          `Use these severity levels when adding issues:\n` +
          `- **critical**: Security vulnerabilities, data corruption, crashes, race conditions\n` +
          `- **high**: Logic errors, broken contracts, unhandled errors, type unsafety (\`any\`)\n` +
          `- **medium**: Dead code, complexity, poor naming, missing guard clauses\n` +
          `- **low**: Style inconsistencies, minor duplication, suboptimal patterns\n\n` +
          `## Step-by-Step Instructions\n\n` +
          `Execute these steps in order. Do NOT skip steps. Do NOT ask questions.\n\n` +
          `1. Run \`codeperfect_loop\` with command "init" and args ["${target}"]\n` +
          `2. Read ALL code files in \`${target}\`. Identify issues using the code standards above.\n` +
          `3. For each issue found: \`codeperfect_loop\` add with [file, line, severity, description]\n` +
          `   - Be specific in descriptions. Include the function/variable name.\n` +
          `   - Include the line number where the issue is most visible.\n` +
          `4. Enter the resolution loop:\n` +
          `   a. Pick the highest-severity OPEN issue from .codeperfect/issues.json\n` +
          `   b. \`codeperfect_loop\` start [ISS-N]\n` +
          `   c. Fix the issue with ONE atomic change (single concern per fix)\n` +
          `   d. \`codeperfect_verify\` to run the 8-point checklist\n` +
          `   e. If verify PASSED: \`codeperfect_loop\` resolve [ISS-N]\n` +
          `   f. If verify FAILED: \`codeperfect_loop\` fail [ISS-N, reason] — this auto-reverts your changes\n` +
          `      - On retry, use a FUNDAMENTALLY different approach, not a tweak\n` +
          `      - After 2 failures, re-read the entire module before attempt 3\n` +
          `      - After 3 failures, the script auto-defers the issue\n` +
          `   g. \`codeperfect_loop\` status — if exit code 1, go to step 4a. If exit code 0, proceed to step 5.\n` +
          `5. When done: \`codeperfect_loop\` report\n\n` +
          `## Critical Rules\n\n` +
          `- NEVER ask "should I continue?" — the status command decides.\n` +
          `- NEVER edit .codeperfect/issues.json directly — only the scripts modify it.\n` +
          `- NEVER commit manually — resolve auto-commits after each fix.\n` +
          `- ONE fix at a time. Do not batch multiple issues into one change.`
      );
    },
  });

  pi.registerCommand("code-perfection:audit", {
    description: "Full tiered codebase audit with domain-scoped scanning",
    async handler(args, ctx) {
      const target = args.trim() || ".";
      const agentsMd = readRef("agents.md");
      const auditMd = readRef("audit.md");
      const loopMd = readRef("resolution-loop.md");

      await ctx.waitForIdle();
      pi.sendMessage(
        `# Code Perfection — Full Codebase Audit\n\nTarget: \`${target}\`\n\n` +
          `## Code Standards\n\n${agentsMd}\n\n## Audit Strategy\n\n${auditMd}\n\n` +
          `## Resolution Loop Protocol\n\n${loopMd}\n\n` +
          `## Step-by-Step Instructions\n\n` +
          `Execute these steps in order. Do NOT skip steps. Do NOT ask questions.\n\n` +
          `### Phase 1: Structural Triage (Tier 0)\n` +
          `1. \`codeperfect_triage\` with target "${target}"\n` +
          `2. Read \`.codeperfect/triage.json\` to see the domain map and tier classifications\n` +
          `3. \`codeperfect_audit\` init ["${target}"]\n\n` +
          `### Phase 2: Domain Audits (Tier 1)\n` +
          `4. For each domain (process in tier order: CRITICAL, HIGH, MEDIUM, LOW):\n` +
          `   a. \`codeperfect_audit\` next-domain — get the next domain name\n` +
          `   b. If output says "ALL_DOMAINS_DONE", skip to Phase 3\n` +
          `   c. \`codeperfect_audit\` start-domain [name]\n` +
          `   d. \`codeperfect_loop\` init [domain-path] — initialize resolution loop for this domain\n` +
          `   e. Read ALL files in this domain. Identify issues per the code standards.\n` +
          `   f. For each issue: \`codeperfect_loop\` add [file, line, severity, description]\n` +
          `   g. Run the resolution loop (start -> fix -> verify -> resolve/fail -> status) until status returns exit code 0\n` +
          `   h. \`codeperfect_audit\` complete-domain [name]\n` +
          `   i. Go back to step 4a\n\n` +
          `### Phase 3: Boundary Audits (Tier 2)\n` +
          `5. \`codeperfect_audit\` find-boundaries ["${target}"]\n` +
          `6. For each boundary pair:\n` +
          `   a. \`codeperfect_audit\` start-boundary [pair]\n` +
          `   b. Read files from BOTH domains. Check for: trust violations, contract mismatches, race conditions, auth gaps\n` +
          `   c. \`codeperfect_audit\` complete-boundary [pair]\n\n` +
          `### Phase 4: Final Report (Tier 3)\n` +
          `7. \`codeperfect_audit\` report\n\n` +
          `## Critical Rules\n\n` +
          `- ONE domain at a time. The script rejects start-domain if another is in_progress.\n` +
          `- NEVER ask "should I continue?" — the scripts decide.\n` +
          `- If interrupted, resume with \`codeperfect_audit\` status then next-domain.`
      );
    },
  });

  pi.registerCommand("code-perfection:verify", {
    description: "Run the 8-point verification checklist",
    async handler(args, ctx) {
      await ctx.waitForIdle();
      const files = args.trim();
      if (files) {
        const fileList = files.split(/\s+/).map((f) => `"${f}"`).join(", ");
        pi.sendMessage(
          `Run \`codeperfect_verify\` now with changed_files: [${fileList}].`
        );
      } else {
        pi.sendMessage(`Run \`codeperfect_verify\` now (auto-detect changed files from git).`);
      }
    },
  });
}
