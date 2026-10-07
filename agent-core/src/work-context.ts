import { createHash } from "node:crypto";

const retentionMs = 30 * 24 * 60 * 60_000;
const contextLimit = 6000;
const sources = new Set(["application", "process", "workspace", "document", "browser-history"]);
interface WorkPart { key: string; item: Record<string, unknown>; observedAt: number }
export interface WorkInsight {
  keys: string[];
  summary: string;
  evidence: string[];
  actionable: boolean;
  observedAt: string;
  consumed: boolean;
  items: Record<string, unknown>[];
}
export interface WorkAnalysisState {
  completed: { key: string; observedAt: number }[];
  insights: WorkInsight[];
}
export interface WorkBatch { parts: WorkPart[]; context: Record<string, unknown> }

function stable(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, child]) => `${JSON.stringify(key)}:${stable(child)}`).join(",")}}`;
  return JSON.stringify(value);
}
function digest(value: unknown): string { return createHash("sha256").update(stable(value)).digest("hex"); }

export function isWorkContext(content: Record<string, unknown>): boolean { return content.scope === "local-work-context"; }

function workParts(content: Record<string, unknown>, now: number, lookbackHours: number): WorkPart[] {
  if (!Array.isArray(content.items) || content.items.length > 512) throw new Error("工作上下文必须提供不超过 512 条来源记录");
  const parts: WorkPart[] = [];
  const seen = new Set<string>();
  for (const value of content.items) {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("工作来源记录无效");
    const raw = value as Record<string, unknown>;
    if (typeof raw.id !== "string" || !raw.id || raw.id.length > 4096 || !sources.has(String(raw.source))
        || typeof raw.title !== "string" || raw.title.length > 500
        || !["complete", "truncated", "metadata-only"].includes(String(raw.contentStatus))
        || (raw.text !== undefined && (typeof raw.text !== "string" || raw.text.length > 24_000))) throw new Error("工作来源字段无效或超过长度限制");
    const observedAt = typeof raw.observedAt === "string" ? Date.parse(raw.observedAt) : NaN;
    if (!Number.isFinite(observedAt)) throw new Error("工作来源缺少有效观察时间");
    if (observedAt > now || now - observedAt > lookbackHours * 3600_000 || seen.has(raw.id)) continue;
    seen.add(raw.id);
    const metadata: Record<string, unknown> = {};
    for (const key of ["id", "source", "title", "contentStatus", "appName", "bundleId", "windowTitle", "path", "url", "workingDirectory", "executable", "startedAt", "activity", "format", "profile", "pid", "parentPID"]) {
      const field = raw[key];
      if (typeof field === "string") metadata[key] = field.slice(0, key === "id" || key === "path" || key === "url" || key === "workingDirectory" ? 4096 : 500);
      else if (typeof field === "number" && Number.isFinite(field)) metadata[key] = field;
    }
    // 来源元数据也有预算；正文另行拆段，不能把同一长文的后半部分永远跳过。
    for (const key of ["executable", "path", "url", "workingDirectory", "id"]) {
      if (JSON.stringify(metadata).length > 2500 && typeof metadata[key] === "string") metadata[key] = (metadata[key] as string).slice(0, 400);
    }
    const text = typeof raw.text === "string" ? raw.text : "";
    const segments: string[] = [];
    for (let start = 0; start < text.length;) {
      let end = Math.min(start + 2000, text.length);
      if (end < text.length && /[\uD800-\uDBFF]/.test(text[end - 1])) end--;
      segments.push(text.slice(start, end)); start = end;
    }
    if (!segments.length) segments.push("");
    segments.forEach((segment, index) => {
      const item = { ...metadata, ...(segment ? { text: segment } : {}), part: index + 1, parts: segments.length };
      parts.push({ key: digest({ originalId: raw.id, ...item }), item, observedAt });
    });
  }
  // 先给每个来源的第一段机会，避免一个长文档长期阻塞其他应用。
  return parts.sort((a, b) => Number(a.item.part) - Number(b.item.part) || b.observedAt - a.observedAt || a.key.localeCompare(b.key));
}

export class WorkContextAnalysis {
  private completed = new Map<string, number>();
  private insights: WorkInsight[] = [];
  private pending = new Map<string, WorkPart>();
  pendingCount = 0;

  constructor(saved?: WorkAnalysisState) {
    for (const record of saved?.completed ?? []) {
      if (/^[a-f0-9]{64}$/.test(record.key) && Number.isFinite(record.observedAt)) this.completed.set(record.key, record.observedAt);
    }
    this.insights = (saved?.insights ?? []).filter(item => Array.isArray(item.keys) && typeof item.summary === "string"
      && item.summary.length <= 2000 && Array.isArray(item.evidence) && item.evidence.length <= 8 && item.evidence.every(value => typeof value === "string" && value.length <= 500)
      && typeof item.actionable === "boolean" && Number.isFinite(Date.parse(item.observedAt)) && Array.isArray(item.items)).slice(-256);
  }

  next(content: Record<string, unknown>, now: number, lookbackHours: number): WorkBatch | undefined {
    this.prune(now);
    const parts = workParts(content, now, lookbackHours);
    const currentIDs = new Set(parts.map(part => part.item.id));
    const currentKeys = new Set(parts.map(part => part.key));
    for (const [key, part] of this.pending) {
      if (now - part.observedAt > lookbackHours * 3600_000 || (currentIDs.has(part.item.id) && !currentKeys.has(key))) this.pending.delete(key);
    }
    for (const part of parts) if (this.completed.has(part.key)) this.completed.set(part.key, part.observedAt);
    for (const part of parts) if (!this.completed.has(part.key)) this.pending.set(part.key, part);
    const pending = [...this.pending.values()].sort((a, b) => Number(a.item.part) - Number(b.item.part) || b.observedAt - a.observedAt || a.key.localeCompare(b.key)).slice(0, 1024);
    this.pending = new Map(pending.map(part => [part.key, part]));
    this.pendingCount = pending.length;
    if (!pending.length) return undefined;
    const coverage = Array.isArray(content.coverage) ? content.coverage.flatMap(value => {
      if (!value || typeof value !== "object") return [];
      const row = value as Record<string, unknown>;
      return [{ source: String(row.source ?? "").slice(0, 40), status: String(row.status ?? "").slice(0, 40) }];
    }).slice(0, 20) : [];
    const context: Record<string, unknown> = { source: "work", scope: "local-work-context", lookbackHours, coverage, remainingParts: pending.length, items: [] };
    const batch: WorkPart[] = [];
    for (const part of pending) {
      const items = [...batch, part].map(value => ({ ...value.item, observedAt: new Date(value.observedAt).toISOString() }));
      if (JSON.stringify({ ...context, items }).length > contextLimit) { if (batch.length) break; throw new Error("单个工作来源的元数据超过模型上下文预算"); }
      batch.push(part); context.items = items;
    }
    return { parts: batch, context };
  }

  complete(batch: WorkBatch, reply: { summary: string; evidence: string[]; actionable: boolean }, now: number): void {
    for (const part of batch.parts) { this.completed.set(part.key, part.observedAt); this.pending.delete(part.key); }
    this.insights.push({ ...reply, keys: batch.parts.map(part => part.key), observedAt: new Date(Math.max(...batch.parts.map(part => part.observedAt))).toISOString(), consumed: false,
      items: batch.parts.map(part => Object.fromEntries(Object.entries(part.item).filter(([key]) => key !== "text"))) });
    this.pendingCount = Math.max(0, this.pendingCount - batch.parts.length);
    this.prune(now);
  }

  recent(now: number, lookbackHours: number, activeOnly = false): WorkInsight[] {
    this.prune(now);
    return this.insights.filter(item => now - Date.parse(item.observedAt) <= lookbackHours * 3600_000 && (!activeOnly || !item.consumed));
  }

  consume(): void { for (const item of this.insights) item.consumed = true; }
  reset(): void { this.completed.clear(); this.pending.clear(); this.consume(); this.pendingCount = 0; }
  snapshot(now: number): WorkAnalysisState {
    this.prune(now);
    return structuredClone({ completed: [...this.completed].map(([key, observedAt]) => ({ key, observedAt })), insights: this.insights });
  }
  private prune(now: number): void {
    for (const [key, observedAt] of this.completed) if (observedAt > now || now - observedAt > retentionMs) this.completed.delete(key);
    if (this.completed.size > 8192) this.completed = new Map([...this.completed].sort((a, b) => b[1] - a[1]).slice(0, 8192));
    this.insights = this.insights.filter(item => Date.parse(item.observedAt) <= now && now - Date.parse(item.observedAt) <= retentionMs).slice(-256);
  }
}
