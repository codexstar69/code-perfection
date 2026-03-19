import { Type } from "@sinclair/typebox";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";

export default function (pi: ExtensionAPI) {
  const SKILL_DIR = join(dirname(__dirname), "skills", "code-perfection");
  const scriptsDir = join(SKILL_DIR, "scripts");

  function runScript(script: string, args: string[] = [], cwd?: string): { exitCode: number; output: string } {
    const cmd = `"${join(scriptsDir, script)}" ${args.map((a) => `"${a}"`).join(" ")}`;
    try {
      const output = execSync(cmd, {
        cwd: cwd || process.cwd(),
        encoding: "utf-8",
        timeout: 120000,
      });
      return { exitCode: 0, output };
    } catch (err: any) {
      return { exitCode: err.status || 1, output: err.stdout || err.message };
    }
  }

  // --- Tool: verify ---
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

  // --- Tool: resolution loop ---
  pi.registerTool({
    name: "codeperfect_loop",
    label: "Code Perfection: Resolution Loop",
    description:
      "Manage the resolution loop issue ledger. Commands: init, scan, add, start, resolve, fail, status, report. The loop enforces fix-verify-decide cycles with auto-revert and auto-defer.",
    parameters: Type.Object({
      command: Type.String({
        description: 'One of: init, scan, add, start, resolve, fail, status, report',
      }),
      args: Type.Optional(
        Type.Array(Type.String(), {
          description: "Arguments for the command (e.g., file, line, severity, description for add)",
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

  // --- Tool: audit state ---
  pi.registerTool({
    name: "codeperfect_audit",
    label: "Code Perfection: Audit State",
    description:
      "Manage large codebase audit state. Commands: init, status, next-domain, start-domain, complete-domain, find-boundaries, start-boundary, complete-boundary, report. Enforces one-domain-at-a-time and resume-safe state.",
    parameters: Type.Object({
      command: Type.String({
        description:
          'One of: init, status, next-domain, start-domain, complete-domain, find-boundaries, start-boundary, complete-boundary, report',
      }),
      args: Type.Optional(
        Type.Array(Type.String(), {
          description: "Arguments for the command (e.g., domain name, target path)",
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

  // --- Tool: triage ---
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
      const agentsMd = readFileSync(join(SKILL_DIR, "references", "agents.md"), "utf-8");
      const loopMd = readFileSync(join(SKILL_DIR, "references", "resolution-loop.md"), "utf-8");

      await ctx.waitForIdle();
      pi.sendMessage(
        `# Code Perfection — Resolution Loop\n\nTarget: ${target}\n\n` +
          `## Code Standards\n\n${agentsMd}\n\n## Resolution Loop Protocol\n\n${loopMd}\n\n` +
          `## Instructions\n\n` +
          `1. Run \`codeperfect_loop\` with command "init" and args ["${target}"]\n` +
          `2. Read code in ${target}, identify issues using the code standards above\n` +
          `3. For each issue: \`codeperfect_loop\` add with [file, line, severity, description]\n` +
          `4. Enter the resolution loop:\n` +
          `   - Pick highest-severity OPEN issue from .codeperfect/issues.json\n` +
          `   - \`codeperfect_loop\` start [ISS-N]\n` +
          `   - Fix the issue (one atomic change)\n` +
          `   - \`codeperfect_verify\` to check\n` +
          `   - If passed: \`codeperfect_loop\` resolve [ISS-N]\n` +
          `   - If failed: \`codeperfect_loop\` fail [ISS-N, reason]\n` +
          `   - \`codeperfect_loop\` status — if exit code 1, continue. If 0, done.\n` +
          `5. When done: \`codeperfect_loop\` report\n\n` +
          `NEVER ask "should I continue?" — the status command decides.`
      );
    },
  });

  pi.registerCommand("code-perfection:audit", {
    description: "Full tiered codebase audit with domain-scoped scanning",
    async handler(args, ctx) {
      const target = args.trim() || ".";
      const agentsMd = readFileSync(join(SKILL_DIR, "references", "agents.md"), "utf-8");
      const auditMd = readFileSync(join(SKILL_DIR, "references", "audit.md"), "utf-8");
      const loopMd = readFileSync(join(SKILL_DIR, "references", "resolution-loop.md"), "utf-8");

      await ctx.waitForIdle();
      pi.sendMessage(
        `# Code Perfection — Full Codebase Audit\n\nTarget: ${target}\n\n` +
          `## Code Standards\n\n${agentsMd}\n\n## Audit Strategy\n\n${auditMd}\n\n` +
          `## Resolution Loop Protocol\n\n${loopMd}\n\n` +
          `## Instructions\n\n` +
          `1. \`codeperfect_triage\` with target "${target}"\n` +
          `2. \`codeperfect_audit\` init ["${target}"]\n` +
          `3. For each domain (CRITICAL first):\n` +
          `   - \`codeperfect_audit\` next-domain\n` +
          `   - \`codeperfect_audit\` start-domain [name]\n` +
          `   - Run resolution loop on this domain (see /code-perfection)\n` +
          `   - \`codeperfect_audit\` complete-domain [name]\n` +
          `4. \`codeperfect_audit\` find-boundaries ["${target}"]\n` +
          `5. For each boundary pair: audit cross-domain issues\n` +
          `6. \`codeperfect_audit\` report`
      );
    },
  });

  pi.registerCommand("code-perfection:verify", {
    description: "Run the 8-point verification checklist",
    async handler(args, ctx) {
      await ctx.waitForIdle();
      pi.sendMessage(
        `Run \`codeperfect_verify\` now${args.trim() ? ` with changed_files: ${args.trim()}` : ""}.`
      );
    },
  });
}
