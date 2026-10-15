#!/usr/bin/env node
/**
 * Dylan Heartbeat 补丁：修复「未找到用户时间」，让自动唤醒真正生效
 *
 * ── 问题 ──────────────────────────────────────────────
 * 上游 Issue #16：wake_up.js 的 getLastUserTime() 只从
 * enhanced_messages.json 的消息正文里找 "YYYY-MM-DD HH:mm" 时间前缀。
 * 但 Kelivo 有时不把时间写进正文，导致永远找不到用户时间 → 永不唤醒。
 *
 * Issue 里建议的修法是「回退查 message_timestamps.json（时间戳记忆库）」，
 * 但这依赖两边的消息正文完全一致（指纹匹配）。实测中时间线里的消息
 * 与记忆库里的消息内容并不相同，指纹对不上，所以那个修法不一定生效。
 *
 * ── 本补丁的做法 ──────────────────────────────────────
 * 换一个更可靠的信号源：网关自己就知道用户什么时候说过话。
 *
 *   1) server.js  —— 每次收到带 user 消息的请求，就把当前时间写入
 *                    last_user_activity.json
 *   2) wake_up.js —— 时间线里找不到时间前缀时，回退读这个文件
 *
 * 这个信号由网关注入，不依赖 Kelivo 的消息格式，因此稳定得多。
 *
 * ── 特性 ──────────────────────────────────────────────
 *   · 幂等：重复运行不会重复插入
 *   · 安全：改动前自动备份为 *.before-heartbeat-patch
 *   · 校验：找不到插入锚点会明确报错并退出，不会写坏文件
 *
 * ── 用法 ──────────────────────────────────────────────
 *   node fix-wake-time.js
 *   （不要加 sudo —— /opt/dylan-heartbeat 属于 ubuntu 用户，pm2 也是）
 */

"use strict";

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const APP_DIR = process.argv[2] || "/opt/dylan-heartbeat";
const SERVER_FILE = path.join(APP_DIR, "server.js");
const WAKE_FILE = path.join(APP_DIR, "wake_up.js");
const MARKER = "[心跳补丁]";
const BACKUP_SUFFIX = ".before-heartbeat-patch";

function say(msg) { console.log(msg); }
function ok(msg) { console.log("\x1b[1;32m[✓]\x1b[0m " + msg); }
function warn(msg) { console.log("\x1b[1;33m[!]\x1b[0m " + msg); }
function fail(msg) { console.log("\x1b[1;31m[x]\x1b[0m " + msg); }

// ── 补丁内容 ────────────────────────────────────────────

// server.js：在解析出 kelivoMessages 之后，记录「用户最后活动时间」
const SERVER_ANCHOR = "    const kelivoMessages = body.messages || [];";

const SERVER_ADD = [
  "",
  "    // " + MARKER + " 记录用户最后一次说话的时间，供 wake_up.js 在时间线缺少",
  "    // 时间前缀时回退使用（修复「未找到用户时间」）。",
  "    if (kelivoMessages.some(m => m && m.role === \"user\")) {",
  "      try {",
  "        fs.writeFileSync(",
  "          runtimeFile(\"last_user_activity.json\"),",
  "          JSON.stringify({ at: new Date().toISOString() }),",
  "          \"utf-8\"",
  "        );",
  "      } catch (e) {}",
  "    }"
].join("\n");

// wake_up.js：声明活动文件路径
const WAKE_ANCHOR_1 = "const TIMELINE_PATH = runtimeFile(\"enhanced_messages.json\");";
const WAKE_ADD_1 = "\nconst LAST_ACTIVITY_PATH = runtimeFile(\"last_user_activity.json\");";

// wake_up.js：getLastUserTime 末尾加回退
const WAKE_ANCHOR_2 = "  return null;\n}\n\nfunction stripPosition(messages) {";

const WAKE_ADD_2 = [
  "  // " + MARKER + " 时间线里没有时间前缀时，回退到网关记录的「用户最后活动时间」。",
  "  const fallback = readLastUserActivity();",
  "  if (fallback) return fallback;",
  "  return null;",
  "}",
  "",
  "function readLastUserActivity() {",
  "  // " + MARKER,
  "  try {",
  "    if (!fs.existsSync(LAST_ACTIVITY_PATH)) return null;",
  "    const data = JSON.parse(fs.readFileSync(LAST_ACTIVITY_PATH, \"utf-8\"));",
  "    const at = new Date(data && data.at);",
  "    return Number.isNaN(at.getTime()) ? null : at;",
  "  } catch (e) {",
  "    return null;",
  "  }",
  "}",
  "",
  "function stripPosition(messages) {"
].join("\n");

// ── 工具函数 ────────────────────────────────────────────

function readFileOrDie(file) {
  if (!fs.existsSync(file)) {
    fail("找不到文件：" + file);
    fail("请确认安装目录是否正确，或用 node fix-wake-time.js <安装目录> 指定。");
    process.exit(1);
  }
  return fs.readFileSync(file, "utf-8");
}

function applyPatch(file, content, anchor, replacement, label) {
  if (content.indexOf(MARKER) !== -1) {
    ok(label + "：已经打过补丁，跳过");
    return content;
  }
  const count = content.split(anchor).length - 1;
  if (count === 0) {
    fail(label + "：找不到插入位置，源码可能和本补丁预期的不一致。");
    fail("  预期锚点：" + JSON.stringify(anchor.slice(0, 70)));
    fail("  没有改动任何文件，请把这段报错截图。");
    process.exit(1);
  }
  if (count > 1) {
    fail(label + "：锚点出现 " + count + " 次，无法确定插入位置。没有改动任何文件。");
    process.exit(1);
  }
  ok(label + "：插入成功");
  return content.replace(anchor, replacement);
}

// ── 主流程 ──────────────────────────────────────────────

say("");
say("============================================================");
say("   Dylan Heartbeat 补丁：修复「未找到用户时间」");
say("============================================================");
say("  安装目录：" + APP_DIR);
say("");

if (typeof process.getuid === "function" && process.getuid() === 0) {
  warn("检测到用 root 在运行。");
  warn("pm2 里的 gateway / wake-up 属于 ubuntu 用户，root 重启会失败。");
  warn("建议改用： node fix-wake-time.js   （不要加 sudo）");
  say("");
}

if (!fs.existsSync(APP_DIR)) {
  fail("安装目录不存在：" + APP_DIR);
  process.exit(1);
}

// --- 1. 打 server.js 补丁 ---
say("==> 第 1 步：修改 server.js");
let serverSrc = readFileOrDie(SERVER_FILE);
const serverPatched = applyPatch(SERVER_FILE, serverSrc, SERVER_ANCHOR, SERVER_ANCHOR + SERVER_ADD, "server.js");

// --- 2. 打 wake_up.js 补丁 ---
say("");
say("==> 第 2 步：修改 wake_up.js");
let wakeSrc = readFileOrDie(WAKE_FILE);
if (wakeSrc.indexOf(MARKER) !== -1) {
  ok("wake_up.js：已经打过补丁，跳过");
} else {
  wakeSrc = applyPatch(WAKE_FILE, wakeSrc, WAKE_ANCHOR_1, WAKE_ANCHOR_1 + WAKE_ADD_1, "wake_up.js 时间常数");
  wakeSrc = applyPatch(WAKE_FILE, wakeSrc, WAKE_ANCHOR_2, WAKE_ADD_2, "wake_up.js 回退逻辑");
}

// --- 3. 写回（先备份）---
say("");
say("==> 第 3 步：备份并写入");
const changedServer = serverPatched !== readFileOrDie(SERVER_FILE);
const changedWake = wakeSrc !== readFileOrDie(WAKE_FILE);

if (!changedServer && !changedWake) {
  warn("两个文件都已经是打过补丁的状态，无需改动。");
} else {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  if (changedServer) {
    fs.copyFileSync(SERVER_FILE, SERVER_FILE + BACKUP_SUFFIX);
    fs.writeFileSync(SERVER_FILE, serverPatched, "utf-8");
    ok("server.js 已更新（备份：" + path.basename(SERVER_FILE) + BACKUP_SUFFIX + "）");
  }
  if (changedWake) {
    fs.copyFileSync(WAKE_FILE, WAKE_FILE + BACKUP_SUFFIX);
    fs.writeFileSync(WAKE_FILE, wakeSrc, "utf-8");
    ok("wake_up.js 已更新（备份：" + path.basename(WAKE_FILE) + BACKUP_SUFFIX + "）");
  }
  // 语法自检
  say("");
  say("==> 第 4 步：语法自检");
  let syntaxOk = true;
  for (const f of [SERVER_FILE, WAKE_FILE]) {
    try {
      execSync("node --check " + JSON.stringify(f), { stdio: "pipe" });
      ok(path.basename(f) + " 语法正确");
    } catch (e) {
      syntaxOk = false;
      fail(path.basename(f) + " 语法检查失败！");
      const out = (e.stderr && e.stderr.toString()) || (e.stdout && e.stdout.toString()) || "";
      console.log(out);
    }
  }
  if (!syntaxOk) {
    fail("正在从备份还原…");
    if (fs.existsSync(SERVER_FILE + BACKUP_SUFFIX)) fs.copyFileSync(SERVER_FILE + BACKUP_SUFFIX, SERVER_FILE);
    if (fs.existsSync(WAKE_FILE + BACKUP_SUFFIX)) fs.copyFileSync(WAKE_FILE + BACKUP_SUFFIX, WAKE_FILE);
    fail("已还原到补丁前的状态，请把上面的报错截图。");
    process.exit(1);
  }
}

// --- 5. 重启 ---
say("");
say("==> 第 5 步：重启服务");
try {
  execSync("pm2 restart gateway wake-up --update-env", { stdio: "inherit" });
  ok("已重启");
} catch (e) {
  warn("自动重启失败。请手动执行：");
  warn("  pm2 restart gateway wake-up --update-env");
}

// --- 完成 ---
say("");
say("============================================================");
say("  补丁完成");
say("============================================================");
say("");
say(" 接下来请做这两件事：");
say("");
say("  1) 打开手机 Kelivo，在 Heartbeat 供应商的对话里随便发一句");
say("     （比如「测试」）——这一步会生成活动时间文件");
say("");
say("  2) 等 2 分钟，然后跑：");
say("       pm2 logs wake-up --lines 40 --nostream");
say("");
say(" 日志里应该出现「AI 选择发送推送」或「本次未发送推送」，");
say(" 而不该再是「未找到用户时间」。");
say("");
say(" 想还原补丁：");
say("   cp " + SERVER_FILE + BACKUP_SUFFIX + " " + SERVER_FILE);
say("   cp " + WAKE_FILE + BACKUP_SUFFIX + " " + WAKE_FILE);
say("   pm2 restart gateway wake-up --update-env");
say("");
