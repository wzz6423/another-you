"use strict";

const scenarios = {
  morning: {
    source: "晨间规则",
    time: "09:00",
    title: "先给今天，定一个小小的重点。",
    message: "到了你设定的晨间时段。需要一份简单的安排，让今天从最重要的事开始吗？",
    reason: "你设定了 09:00 的时间规则。同一条建议在 60 分钟内不会重复出现。",
    draft: ["写下今天最重要的一件事", "为它留出一段不被打扰的时间", "其余事项，等这个重点完成后再安排"],
  },
  focus: {
    source: "专注结束事件",
    time: "10:24",
    title: "告一段落了，给自己一点空隙。",
    message: "收到了你配置的专注结束事件。要不要先休息几分钟，再决定接下来做什么？",
    reason: "这条建议由演示中的「专注结束」事件触发，并非读取了你的屏幕或正在使用的应用。",
    draft: ["离开屏幕，站起来活动一下", "喝点水，让注意力慢慢回来", "回来后再选一件值得继续的事"],
  },
  idle: {
    source: "闲置时机规则",
    time: "16:40",
    title: "这一会儿，有空回顾一下吗？",
    message: "在演示中的空闲时段，留一分钟记下今天的进展。未完成的事，也可以明天继续。",
    reason: "演示模拟了达到闲置阈值的状态。这一网页没有获取你的设备活动；实际应用中的主动参与可随时暂停。",
    draft: ["记下一件今天已经完成的事", "把尚未完成的想法留成一句备注", "给明天留下一个清晰的小起点"],
  },
};

const tabs = Array.from(document.querySelectorAll("[data-scenario]"));
const panel = document.getElementById("demo-panel");
const suggestionView = document.getElementById("suggestion-view");
const outcomeView = document.getElementById("outcome-view");
const announcement = document.getElementById("demo-announcement");
const draftList = document.getElementById("draft-list");
const decisions = new Map();
let selectedScenario = "morning";

function showScenario(key, { moveFocus = false } = {}) {
  selectedScenario = key;
  const scenario = scenarios[key];
  tabs.forEach((tab) => {
    const selected = tab.dataset.scenario === key;
    tab.setAttribute("aria-selected", String(selected));
    tab.tabIndex = selected ? 0 : -1;
    if (selected && moveFocus) tab.focus();
  });
  panel.setAttribute("aria-labelledby", `tab-${key}`);
  document.getElementById("demo-source").textContent = scenario.source;
  document.getElementById("demo-time").textContent = scenario.time;
  document.getElementById("demo-title").textContent = scenario.title;
  document.getElementById("demo-message").textContent = scenario.message;
  document.getElementById("demo-reason").textContent = scenario.reason;
  document.getElementById("reason-details").open = false;
  renderDecision(decisions.get(key));
}

function renderDecision(decision, { moveFocus = false } = {}) {
  suggestionView.hidden = Boolean(decision);
  outcomeView.hidden = !decision;
  if (!decision) return;

  const outcomes = {
    accept: { icon: "✓", title: "一份小小的草稿，准备好了。", description: "这是演示草稿，留给你审阅。没有操作其他应用，也没有发送任何内容。" },
    snooze: { icon: "↗", title: "好，把这一刻留给你。", description: "演示中的建议已设为稍后。这一页不会发出通知，你可以随时重新体验。" },
    dismiss: { icon: "✓", title: "收到，这次就不打扰了。", description: "演示中的这条建议已忽略。你不需要为每一次出现，都给出回应。" },
  };
  const outcome = outcomes[decision];
  document.getElementById("outcome-icon").textContent = outcome.icon;
  document.getElementById("outcome-title").textContent = outcome.title;
  document.getElementById("outcome-description").textContent = outcome.description;
  draftList.replaceChildren();
  draftList.hidden = decision !== "accept";
  if (decision === "accept") {
    scenarios[selectedScenario].draft.forEach((text) => {
      const item = document.createElement("li");
      item.textContent = text;
      draftList.append(item);
    });
  }
  if (moveFocus) {
    announcement.textContent = outcome.title;
    document.getElementById("reset-suggestion").focus({ preventScroll: true });
  }
}

tabs.forEach((tab, index) => {
  tab.addEventListener("click", () => showScenario(tab.dataset.scenario));
  tab.addEventListener("keydown", (event) => {
    let nextIndex;
    if (event.key === "ArrowDown" || event.key === "ArrowRight") nextIndex = (index + 1) % tabs.length;
    if (event.key === "ArrowUp" || event.key === "ArrowLeft") nextIndex = (index - 1 + tabs.length) % tabs.length;
    if (event.key === "Home") nextIndex = 0;
    if (event.key === "End") nextIndex = tabs.length - 1;
    if (nextIndex === undefined) return;
    event.preventDefault();
    showScenario(tabs[nextIndex].dataset.scenario, { moveFocus: true });
  });
});

for (const [buttonId, decision] of [["accept-suggestion", "accept"], ["snooze-suggestion", "snooze"], ["dismiss-suggestion", "dismiss"]]) {
  document.getElementById(buttonId).addEventListener("click", () => {
    decisions.set(selectedScenario, decision);
    renderDecision(decision, { moveFocus: true });
  });
}

document.getElementById("reset-suggestion").addEventListener("click", () => {
  decisions.delete(selectedScenario);
  showScenario(selectedScenario);
  announcement.textContent = "已重置当前时机，可以重新选择。";
  document.getElementById("accept-suggestion").focus({ preventScroll: true });
});

document.getElementById("copy-command").addEventListener("click", async () => {
  const command = document.getElementById("start-command");
  const status = document.getElementById("copy-status");
  try {
    await navigator.clipboard.writeText(command.textContent.trim());
    status.textContent = "启动命令已复制。";
  } catch {
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(command);
    selection.removeAllRanges();
    selection.addRange(range);
    status.textContent = "浏览器未允许自动复制。命令已选中，请按 ⌘C（或 Ctrl+C）复制。";
  }
});
