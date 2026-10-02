import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { TestContext } from "node:test";

export async function writePiFixture(dataDir: string, endpoint: string, thinkingLevel = "off"): Promise<string> {
  const directory = join(dataDir, "pi");
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "settings.json"), JSON.stringify({ defaultProvider: "fixture-provider", defaultModel: "fixture", defaultThinkingLevel: thinkingLevel }));
  await writeFile(join(directory, "auth.json"), JSON.stringify({ "fixture-provider": { type: "api_key", key: "another-you-fixture" } }));
  await writeFile(join(directory, "models.json"), JSON.stringify({ providers: { "fixture-provider": {
    baseUrl: endpoint, api: "openai-completions",
    models: [{ id: "fixture", name: "fixture", input: ["text", "image"], reasoning: true, contextWindow: 32768, maxTokens: 2048,
      compat: { supportsStore: false, supportsDeveloperRole: false, supportsReasoningEffort: true, maxTokensField: "max_tokens" } }],
  } } }));
  return directory;
}

export async function usePiFixture(_t: TestContext, dataDir: string, endpoint = "http://127.0.0.1:1/v1"): Promise<string> {
  return writePiFixture(dataDir, endpoint);
}
