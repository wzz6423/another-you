import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WorkContextAnalysis } from "../src/work-context.ts";
import { StateStore, type PersistedState } from "../src/state.ts";
import { createDefaultConfig } from "../src/config.ts";

const now = Date.parse("2026-10-07T12:00:00Z");
const item = (id: string, text?: string, source = "document", date = now) => ({
  id, title: id, source, observedAt: new Date(date).toISOString(), contentStatus: text ? "complete" : "metadata-only", ...(text ? { text } : {}),
});
const content = (items: unknown[]) => ({ scope: "local-work-context", items, coverage: [{ source: "application", status: "permission-required" }] });
const reply = { summary: "有来源的工作摘要", actionable: false, evidence: ["项目文档"] };

test("多来源分批完整读取长文尾部，模型上下文有界，重排和采集时间变化不重算", () => {
  const work = new WorkContextAnalysis();
  const fullText = "开头\n" + "这是较长的正文。".repeat(1100) + "\n末尾待办标记";
  const items = [item("file", fullText), item("app", "后台编辑器内容", "application"), item("worker", undefined, "process"), item("project", "项目说明", "workspace"), item("visit", undefined, "browser-history")];
  const read: Record<string, unknown>[] = [];
  for (let count = 0; count < 30; count++) {
    const batch = work.next(content(items), now, 24);
    if (!batch) break;
    assert.ok(JSON.stringify(batch.context).length <= 6000);
    read.push(...batch.context.items as Record<string, unknown>[]);
    work.complete(batch, reply, now);
  }
  assert.equal(read.filter(row => row.id === "file").sort((a, b) => Number(a.part) - Number(b.part)).map(row => row.text).join(""), fullText);
  assert.deepEqual(new Set(read.map(row => row.source)), new Set(["document", "application", "process", "workspace", "browser-history"]));
  assert.equal(work.pendingCount, 0);
  const nextTime = now + 60_000;
  assert.equal(work.next(content(items.reverse().map(row => ({ ...row, observedAt: new Date(nextTime).toISOString() }))), nextTime, 24), undefined);
  assert.ok(work.next(content([item("file", fullText.replace("末尾待办标记", "末尾内容已更新"))]), nextTime, 24));
});

test("Unicode 正文拆段不损坏代理对，元数据不能伪装成正文", () => {
  const work = new WorkContextAnalysis();
  const text = "😀中文𠀀".repeat(2000);
  const segments: { part: number; text: string }[] = [];
  for (let count = 0; count < 20; count++) {
    const batch = work.next(content([item("unicode", text), item("url", undefined, "browser-history")]), now, 24);
    if (!batch) break;
    for (const row of batch.context.items as Record<string, unknown>[]) {
      if (row.id === "unicode") segments.push({ part: Number(row.part), text: String(row.text) });
      else { assert.equal(row.contentStatus, "metadata-only"); assert.equal(row.text, undefined); }
    }
    work.complete(batch, reply, now);
  }
  assert.equal(segments.sort((a, b) => a.part - b.part).map(row => row.text).join(""), text);
});

test("应用切换或窗口关闭后仍会继续处理已采集但未分析的内容", () => {
  const work = new WorkContextAnalysis();
  const original = content([item("closed-window", "长文".repeat(7000) + "CLOSED_WINDOW_END", "application")]);
  const first = work.next(original, now, 24)!;
  work.complete(first, reply, now);
  let foundTail = false;
  for (let index = 0; index < 15; index++) {
    const batch = work.next(content([item("other-app", "其他应用内容", "application")]), now + 1000, 24);
    if (!batch) break;
    if (JSON.stringify(batch.context).includes("CLOSED_WINDOW_END")) foundTail = true;
    work.complete(batch, reply, now + 1000);
  }
  assert.equal(foundTail, true);
});

test("未完成批次可重试，先前待办不被之后的普通内容覆盖，历史跨重启按范围保留", () => {
  const work = new WorkContextAnalysis();
  const batch = work.next(content([item("important", "明确待办")]), now, 24)!;
  assert.deepEqual(work.next(content([item("important", "明确待办")]), now, 24)?.parts, batch.parts);
  work.complete(batch, { ...reply, actionable: true }, now);
  const other = work.next(content([item("ordinary", "普通内容")]), now, 24)!;
  work.complete(other, reply, now);
  assert.equal(work.recent(now, 24, true).some(row => row.actionable), true);
  const saved = work.snapshot(now);
  assert.equal(JSON.stringify(saved).includes("明确待办"), false);
  const restored = new WorkContextAnalysis(saved);
  assert.equal(restored.next(content([item("important", "明确待办")]), now, 24), undefined);
  assert.equal(restored.recent(now + 2 * 86400_000, 24).length, 0);
  assert.equal(restored.recent(now + 2 * 86400_000, 168).length, 2);
  assert.equal(restored.recent(now + 29 * 86400_000, 720).length, 2);
  assert.equal(restored.recent(now + 31 * 86400_000, 720).length, 0);
  work.consume();
  assert.equal(work.recent(now, 24, true).length, 0);
  assert.equal(work.recent(now, 24).length, 2);
  work.reset();
  assert.ok(work.next(content([item("important", "明确待办")]), now, 24));
});

test("时间范围包含边界并丢弃未来和过期记录，无效输入不能进入模型", () => {
  for (const hours of [24, 168, 720]) {
    const work = new WorkContextAnalysis();
    const batch = work.next(content([item("edge", "边界", "document", now - hours * 3600_000), item("old", "过期", "document", now - hours * 3600_000 - 1), item("future", "未来", "document", now + 1)]), now, hours)!;
    assert.deepEqual((batch.context.items as Record<string, unknown>[]).map(row => row.id), ["edge"]);
  }
  for (const invalid of [null, { ...item("x"), source: "unknown" }, { ...item("x"), text: "x".repeat(24_001) }, { ...item("x"), observedAt: "invalid" }, { ...item("x"), contentStatus: "all-read" }]) {
    assert.throws(() => new WorkContextAnalysis().next(content([invalid]), now, 24));
  }
});

test("关闭任一内容保存选项后不持久化近期工作摘要和来源", async t => {
  const directory = await mkdtemp(join(tmpdir(), "another-you-work-privacy-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const work = new WorkContextAnalysis();
  const batch = work.next(content([item("private-project", "私人正文")]), now, 24)!;
  work.complete(batch, { summary: "私人工作摘要", actionable: true, evidence: ["私人证据"] }, now);
  const state = { version: 1, paused: false, proposals: [], history: [], scheduler: {}, proactive: { tasks: {}, fingerprints: {}, seenNotifications: [], workAnalysis: work.snapshot(now) } } as unknown as PersistedState;
  for (const field of ["storePrompts", "storeResponses"] as const) {
    const privacy = createDefaultConfig(directory).privacy;
    privacy[field] = false;
    new StateStore(directory, privacy).save(state, directory);
    const saved = await readFile(join(directory, "state.json"), "utf8");
    for (const value of ["private-project", "私人正文", "私人工作摘要", "私人证据"]) assert.equal(saved.includes(value), false);
  }
});
