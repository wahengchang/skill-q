# 開發技能：操作手冊

README 給使用者；ARCHITECTURE 說設計；這份文件只定義新增／修改 skill 與 framework 時的日常規則。

## 1. 心智模型

| 路徑 | 規則 |
| --- | --- |
| `commands-src/<name>/SKILL.md` | canonical skill source；**手動編輯這裡** |
| `_shared/` | 所有 skills 共用的 tracked build input |
| `commands/` | build 產生的 canonical artifact；**不要編輯、不要 commit** |
| `opencode-commands/` | transformed artifact；**不要編輯、不要 commit** |
| `bin/targets/` | runtime metadata / adapters |
| `tests/` | mechanism test suite；`tests/lib/harness.sh` 是共用 harness |

一句話：**改 source → build → test → optional sync → commit source。**

## 2. 新增一顆 skill

```bash
mkdir -p commands-src/y-<skill-name>
cat > commands-src/y-<skill-name>/SKILL.md <<'EOF'
---
name: y-<skill-name>
description: 清楚說明做什麼，以及什麼情況應該觸發。
---

# Instructions
...
EOF

bin/build.sh
make test
bin/skill-q sync       # optional local smoke test
git add commands-src/y-<skill-name>
git commit -m "add y-<skill-name> skill"
```

也可以把草稿交給 `.codex/skills/canonicalize-skill` 產生 canonical skill。

### 支援檔案

`scripts/`、`references/`、templates 等放在同一 skill directory。build 會 follow shared symlink 並 materialize 成 self-contained artifact，因此 deployment 不依賴 source tree 裡的相對 symlink。

### `## Provenance`

若 skill source 需要記錄出處，寫成 `## Provenance` H2 section。它是 repository 的維護歷史，不是給 agent 的指令，因此 build 會把整段（到下一個 H2 為止）從 artifact 移除，只留在 `commands-src/`。

## 3. 修改 shared behavior

修改 `_shared/update-check-header.md` 或 build framework 後：

```bash
bin/build.sh
make test
git status --short
```

正常情況下 `commands/` / `opencode-commands/` 不會出現在 Git status。若出現，先修正 ignore/build 設定，不要把 generated files 加回 Git。

## 4. Naming

1. **skill-q 的所有技能一律使用 `y-` prefix**：`y-commit`、`y-review`、`y-summary`。沒有 prefix 的技能不進 `commands-src/`。
2. skill folder 與 frontmatter `name:` 必須相同。
3. prefix 之後使用小寫 kebab-case，不要空白、底線或中文名稱。
4. `y-` 之後用具體動詞或名詞說明用途；避免 `y-test`、`y-run` 這種過度泛用名稱。
5. `description` 同時描述能力與 trigger；它會影響 agent discovery。
6. 建議名稱不超過約 40 characters，以免 UI 截斷。

## 4.1 Quick 原則

q 是 quick。skill-q 的技能要維持輕量：

- 一顆技能只做一件事；需要多階段編排的工作不屬於這個 repo。
- `SKILL.md` 盡量控制在 100 行以內，指令用短列表而不是長篇說明。
- 預設不加 `scripts/` 或 `references/`；只有在明顯縮短 agent 執行路徑時才加。
- 不要求使用者先做冗長設定；技能應該可以直接執行。

## 5. 新增 runtime

優先判斷它是否能直接讀 canonical `SKILL.md`：

- 能：只改 `CANONICAL_CONSUMERS`。
- 不能：新增一個 transformed adapter，再登記到 `TRANSFORMED_TARGETS`。

不要把 runtime-specific branch 塞回 `build.sh`；adapter contract 見 AGENTS.md / ARCHITECTURE.md。

## 5.1 測試

| 指令 | 範圍 |
| --- | --- |
| `make test` / `make test-fast` | fast subset：build 正確性與必要 smoke coverage，改 skill content 時跑這個 |
| `make test-full` | 全部 integration / lifecycle 測試，改 `bin/`、`tests/`、`bin/targets/` 時必跑 |

測試用 `tests/lib/harness.sh`：

- `run_test [--fast] <name> <fn>` 註冊測試；沒有 `--fast` 的只在 full suite 執行。
- 每個 test 有 timeout（預設 240 秒，`--timeout` 或 `SKILL_Q_TEST_TIMEOUT` 可調），逾時會連同子行程一起終止並記為失敗，而不是卡住整個 session。
- `copy_project` / `copy_built_project` 從每個 suite 只建立一次的 template 複製 fixture，測試之間互相隔離。
- fixture 名稱 `example-skill`、`funny-text-rewriter` 由 harness 在缺少時自動補上，因此刪掉範例 skills 也不會讓測試失效。

測試只寫入暫存 `HOME` 與 local Git fixtures，不會碰到真實 agent 目錄。需要 `git`、Bash 與 `ripgrep (rg)`。CI 見 `.github/workflows/test.yml`：push 跑 fast suite，pull request 跑 full suite。

## 6. 安全規則

- 不要依名稱或 target prefix 判斷「這是我們的檔案」；ownership 只能來自 installation manifest 或 managed marker。
- 遇到既有 non-symlink / foreign symlink，保留並警告。
- update 不處理 dirty/diverged checkout；讓人先處理 Git 狀態。
- uninstall `--remove-checkout` 前必須保護 tracked、untracked，以及非 generated 的 ignored local content。
- cloud bootstrap 不接受 credential arguments；secret 由 build environment 提供。

## 7. 提交前 checklist

- [ ] `name:` 與 directory name 一致
- [ ] `description` 有明確 trigger
- [ ] `bin/build.sh` 成功
- [ ] `make test` 成功（改動 `bin/`、`tests/`、`bin/targets/` 時改跑 `make test-full`）
- [ ] `git status` 沒有 generated artifacts
- [ ] optional：在受影響 runtime 做實際 smoke test
- [ ] commit 只包含 canonical source / framework / docs，不包含 `commands/` 或 `opencode-commands/`
