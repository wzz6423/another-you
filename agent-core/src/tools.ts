import { exec } from "node:child_process";
import { open, readdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { Type, type TSchema } from "typebox";
import type { AgentTool, AgentToolResult } from "@earendil-works/pi-agent-core";
import { isToolAllowed, type AgentConfig } from "./config.ts";
import { redactSecrets } from "./state.ts";

const OUTPUT_LIMIT = 128 * 1024;
const TIMEOUT_MS = 30_000;

function pathFor(path: string): string {
  return resolve(path === "~" ? homedir() : path.startsWith("~/") ? `${homedir()}/${path.slice(2)}` : path);
}

function defineTool<T extends TSchema>(tool: AgentTool<T>): AgentTool<T> { return tool; }

export function createAgentTools(config: AgentConfig): AgentTool<any>[] {
  const result = (text: string): AgentToolResult => ({
    content: [{ type: "text", text: config.privacy.redactSecrets ? redactSecrets(text) : text }],
    details: undefined,
  });
  const tools: AgentTool<any>[] = [];
  if (isToolAllowed(config, "filesystem")) tools.push(defineTool({
    name: "filesystem", label: "文件", description: "读取、写入文件或列出目录；支持绝对路径及相对当前目录的路径。读取最多返回 128 KiB。",
    parameters: Type.Object({ action: Type.Union([Type.Literal("read"), Type.Literal("write"), Type.Literal("list")]), path: Type.String(), content: Type.Optional(Type.String()) }),
    async execute(_id, params, signal) {
      signal?.throwIfAborted();
      const path = pathFor(params.path);
      if (params.action === "write") {
        if (typeof params.content !== "string") throw new Error("写入文件需要 content");
        await writeFile(path, params.content, { signal });
        return result(`已写入 ${path}`);
      }
      if (params.action === "list") return result((await readdir(path)).join("\n").slice(0, OUTPUT_LIMIT));
      const file = await open(path, "r");
      try {
        const buffer = Buffer.alloc(OUTPUT_LIMIT + 1);
        const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
        signal?.throwIfAborted();
        return result(buffer.subarray(0, Math.min(bytesRead, OUTPUT_LIMIT)).toString("utf8") + (bytesRead > OUTPUT_LIMIT ? "\n[内容已截断]" : ""));
      } finally { await file.close(); }
    },
  }));
  if (isToolAllowed(config, "shell")) tools.push(defineTool({
    name: "shell", label: "命令行", description: "执行 shell 命令，可指定 cwd。最长执行 30 秒，输出上限 128 KiB。",
    parameters: Type.Object({ command: Type.String(), cwd: Type.Optional(Type.String()) }),
    async execute(_id, params, signal) {
      signal?.throwIfAborted();
      return new Promise((resolveResult, reject) => {
        exec(params.command, { cwd: params.cwd ? pathFor(params.cwd) : undefined, signal, timeout: TIMEOUT_MS, maxBuffer: OUTPUT_LIMIT, killSignal: "SIGKILL" }, (error, stdout, stderr) => {
          const output = `${stdout}${stderr}`;
          if (error) reject(new Error(config.privacy.redactSecrets ? redactSecrets(`${error.message}\n${output}`) : `${error.message}\n${output}`));
          else resolveResult(result(output || "命令已完成"));
        });
      });
    },
  }));
  if (isToolAllowed(config, "network")) tools.push(defineTool({
    name: "network", label: "网络", description: "发起 HTTP(S) 请求，返回状态码和文本内容；最长 30 秒，最多读取 128 KiB。",
    parameters: Type.Object({ url: Type.String(), method: Type.Optional(Type.String()), body: Type.Optional(Type.String()) }),
    async execute(_id, params, signal) {
      const url = new URL(params.url);
      if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error("网络工具仅支持 HTTP(S)");
      const timeout = AbortSignal.timeout(TIMEOUT_MS);
      const response = await fetch(url, { method: params.method ?? "GET", body: params.body, signal: signal ? AbortSignal.any([signal, timeout]) : timeout, redirect: "error" });
      const reader = response.body?.getReader();
      const chunks: Uint8Array[] = [];
      let length = 0;
      let truncated = false;
      try {
        while (reader) {
          const chunk = await reader.read();
          if (chunk.done) break;
          const remaining = OUTPUT_LIMIT - length;
          chunks.push(chunk.value.subarray(0, remaining));
          length += Math.min(chunk.value.length, remaining);
          if (chunk.value.length > remaining || length === OUTPUT_LIMIT) { truncated = true; break; }
        }
      } finally { await reader?.cancel(); }
      return result(`HTTP ${response.status}\n${Buffer.concat(chunks).toString("utf8")}${truncated ? "\n[内容已截断]" : ""}`);
    },
  }));
  return tools;
}
