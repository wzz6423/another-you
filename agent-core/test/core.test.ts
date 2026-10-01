import { strict as assert } from "node:assert";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  configPathForDataDir,
  createDefaultConfig,
  isToolAllowed,
  loadConfig,
  parseAgentConfig,
  saveConfig,
} from "../src/config.ts";
import { encodeEvent, EventBus } from "../src/events.ts";
import { ProactiveScheduler } from "../src/scheduler.ts";

test("默认配置保持本地优先并关闭网络工具", () => {
  const config = createDefaultConfig("~/another-you-test");
  assert.equal(config.privacy.mode, "strict-local");
  assert.equal(config.privacy.allowNetwork, false);
  assert.equal(isToolAllowed(config, "filesystem"), true);
  assert.equal(isToolAllowed(config, "network"), false);
});

test("配置拒绝明文 API 密钥并强制 strict-local 网络策略", () => {
  assert.throws(
    () => parseAgentConfig({ model: { provider: "local", model: "test", apiKey: "secret" } }),
    /API 密钥/,
  );
  const config = parseAgentConfig({
    dataDir: "~/.another-you",
    model: { provider: "local", model: "test" },
    tools: { network: true },
    privacy: { mode: "strict-local", allowNetwork: true },
  });
  assert.equal(config.privacy.allowNetwork, false);
  assert.equal(isToolAllowed(config, "network"), false);
});

test("配置可以安全写入和读取本地数据目录", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "another-you-agent-core-"));
  try {
    const config = createDefaultConfig(dataDir);
    config.model.apiKeyEnv = "ANOTHER_YOU_API_KEY";
    const path = configPathForDataDir(dataDir);
    await saveConfig(config, path);
    const savedText = await readFile(path, "utf8");
    assert.equal(savedText.includes("ANOTHER_YOU_API_KEY"), true);
    assert.equal(savedText.includes("secret"), false);
    const loaded = await loadConfig(path);
    assert.equal(loaded.dataDir, config.dataDir);
    assert.equal(loaded.model.apiKeyEnv, "ANOTHER_YOU_API_KEY");
  } finally {
    await rm(dataDir, { recursive: true, force: true });
  }
});

test("时间信号在同一分钟内去重，事件信号遵守冷却时间", () => {
  const scheduler = new ProactiveScheduler(
    [
      {
        id: "morning",
        type: "time",
        at: "09:00",
        title: "开始一天",
        message: "整理今天最重要的三件事",
        cooldownMs: 0,
        dedupeWindowMs: 300_000,
      },
      {
        id: "focus-ended",
        type: "event",
        eventName: "focus-ended",
        title: "休息一下",
        message: "现在适合离开屏幕几分钟",
        cooldownMs: 60_000,
        dedupeWindowMs: 1_000,
      },
    ],
    new EventBus(),
    { defaults: { defaultCooldownMs: 0, defaultDedupeWindowMs: 0, pollIntervalMs: 1000 } },
  );
  const morning = new Date(2026, 9, 1, 9, 0, 0);
  assert.equal(scheduler.ingest({ type: "time", at: morning }, morning).length, 1);
  assert.equal(scheduler.ingest({ type: "time", at: new Date(morning.getTime() + 30_000) }, new Date(morning.getTime() + 30_000)).length, 0);

  const firstEvent = scheduler.ingest({ type: "event", name: "focus-ended" }, morning);
  assert.equal(firstEvent.length, 1);
  assert.equal(scheduler.ingest({ type: "event", name: "focus-ended" }, new Date(morning.getTime() + 2_000)).length, 0);
  assert.equal(scheduler.ingest({ type: "event", name: "focus-ended" }, new Date(morning.getTime() + 61_000)).length, 1);
});

test("闲置信号和统一 JSONL 事件输出可供宿主消费", () => {
  const bus = new EventBus();
  const received: string[] = [];
  bus.subscribe((event) => received.push(encodeEvent(event)));
  const scheduler = new ProactiveScheduler(
    [
      {
        id: "idle",
        type: "idle",
        minIdleMs: 300_000,
        title: "需要休息吗？",
        message: "你已经有一段时间没有活动了。",
        cooldownMs: 60_000,
      },
    ],
    bus,
    { defaults: { defaultCooldownMs: 0, defaultDedupeWindowMs: 0, pollIntervalMs: 1000 } },
  );
  const now = new Date(2026, 9, 1, 12, 0, 0);
  assert.equal(scheduler.tick(now, 300_000).length, 1);
  assert.equal(scheduler.tick(new Date(now.getTime() + 30_000), 360_000).length, 0);
  const event = JSON.parse(received[0]);
  assert.equal(event.kind, "proactive.suggestion");
  assert.equal(event.payload.trigger, "idle");
  assert.equal(received[0].endsWith("\n"), true);
});
