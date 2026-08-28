# skill-q

**q = quick。** skill-q 是一組刻意保持輕量、快速的技能（skills），全部以 `q-` 為 prefix，例如 `q-plan`、`q-debug`、`q-review`。每顆技能都應該單一用途、低 ceremony、能直接執行，不追求大型 workflow framework。

這個 repository 把 canonical `SKILL.md` 技能安全地部署到 Claude Code、Codex CLI 與 OpenCode：**單一 source、generated artifacts、installation manifest、target adapters，以及可診斷／可更新／可安全移除的完整生命週期**。框架來自 [skill-x-starter](https://github.com/wahengchang/skill-x-starter)。

## 快速開始

```bash
npx skills add wahengchang/skill-q --list
npx skills add wahengchang/skill-q
```

預設是 **project-local**，不會殘留在 global。只安裝指定技能並同步給三個常用 agent：

```bash
npx skills add wahengchang/skill-q \
  --skill q-plan --skill q-debug --skill q-ship \
  -a claude-code -a codex -a opencode
```

只有加 `-g` 才是 global；移除時 scope 也要一致：

```bash
npx skills add wahengchang/skill-q -g
npx skills remove q-plan          # project-local
npx skills remove -g q-plan       # global
```

> **同名安全：** skills CLI 目前仍有同名來源可能互相取代的已知問題。安裝前先用 `npx skills list` 和 `npx skills list -g` 檢查；不要讓另一個 repo 再發布相同的 `q-*` name。
>
> **OMP：** 目前沒有獨立 `omp` target；把 skill 安裝到 OMP 實際使用的 `claude-code`、`codex`、`opencode`。長時間運行的 session 安裝後應重開。

## Legacy lifecycle

原有 checkout-based installer 暫時保留，供既有使用者遷移：

```bash
git clone https://github.com/wahengchang/skill-q.git ~/.skill-q
cd ~/.skill-q
./install.sh
bin/skill-q status
```

## Lifecycle

| 指令 | 用途 |
| --- | --- |
| `bin/skill-q init` | 第一次選擇 agents、build、sync、記錄 manifest |
| `bin/skill-q install` | 依既有選擇重新安裝；checkout 搬家後也用它修復 links |
| `bin/skill-q sync` | 不 rebuild，只重新同步部署路徑 |
| `bin/skill-q status` | fetch upstream 後顯示版本、behind/ahead、agents、managed paths；支援 `--json` |
| `bin/skill-q doctor` | 檢查 missing / stale / foreign paths；CI 可用 `--strict` |
| `bin/skill-q update` | preview 後只允許 fast-forward；dirty/diverged checkout 會拒絕更新 |
| `bin/skill-q uninstall` | 只移除 manifest 證明屬於本 installation 的項目 |

舊入口 `bin/sync-skills.sh`、`bin/doctor.sh`、`bin/apply-update.sh` 保留為 compatibility wrappers。

## Source of truth

```text
commands-src/<name>/SKILL.md   ← 唯一手動編輯的技能來源
_shared/                       ← 共用 build input
        │
        ├── bin/build-registry.sh
        │   └── skills/        ← tracked npx-skills distribution
        └── bin/build.sh
            └── commands/      ← legacy disposable artifacts（gitignored）
opencode-commands/             ← disposable OpenCode v1 shims（gitignored）
        │
        ▼ bin/skill-q sync
~/.claude/skills/
~/.agents/skills/
~/.codex/skills/               ← compatibility path，可關閉
~/.config/opencode/skills/
~/.config/opencode/commands/   ← 僅 OpenCode v1
```

**commit `skills/`，但不要直接編輯它。不要 commit `commands/` 或 `opencode-commands/`。** 支援檔案會 materialize 進每顆 published skill，因此 `npx skills add --skill <name>` 安裝單顆技能仍是自包含的。

## 新增／修改技能

在 Codex 中可以使用 repo-local `.codex/skills/canonicalize-skill`，或直接編輯 `commands-src/<name>/SKILL.md`：

```bash
bin/build-registry.sh
bin/build.sh
make test
bin/skill-q sync       # optional local smoke test
git add commands-src _shared skills
```

repo 內保留 `q-example` 作為安裝驗證與格式樣板。實際技能使用同一個 `q-` prefix。

skill-q 的技能規則：

- 所有技能名稱一律 `q-` 開頭，資料夾名與 frontmatter `name:` 相同。
- 保持 quick：單一用途、少 ceremony、按需探索；不要把 workflow framework 搬進單一 skill。
- `description` 要同時寫清楚「做什麼」與「什麼時候觸發」。
- 完成並驗證 repository change 的 skill，正常 handoff 到 `q-ship`；planning 與 optional review 例外見 `commands-src/AGENTS.md`。

完整命名與提交規則見 [CONTRIBUTING.md](./CONTRIBUTING.md)。

## Target adapters

`bin/targets/targets.conf` 是 runtime registry：

- canonical-format runtime 只需加入 `CANONICAL_CONSUMERS`；
- 需要不同格式的 runtime 則新增 `bin/targets/<adapter>.sh`，實作 `build / sync / bootstrap` 三個 action。

OpenCode v1 需要 command shim；OpenCode v2 原生列出 skills，因此不建立 shim，並會清理由本 installation 管理的舊 shim。可用 `SKILL_Q_OPENCODE_VERSION=v1|v2` 強制指定。

## Installation state 與安全規則

每個 checkout 有穩定 installation id；manifest 預設放在：

```text
~/.local/state/skill-q/<installation-id>/install.json
```

manifest 是 ownership proof。sync、doctor、cloud bootstrap 與 uninstall 都不會只因為「名字一樣」或「看起來指向這個 repo」就接管既有檔案。外部／使用者自有 path 會保留並回報為 foreign。

`update` 會先 fetch、preview commits 與受影響 skills；只有 clean、非 diverged checkout 才允許 fast-forward。技能執行前的 `bin/update-check` 只是節流的 fail-open 提醒；權威狀態永遠是 `bin/skill-q status`。

## Container / cloud image

```bash
bin/cloud-bootstrap.sh <private-repo-url> <tag-or-full-commit-sha>
```

它 checkout pinned ref、執行該版本自己的 build，再把 artifact **copy** 到 image HOME，不依賴 runtime 保留 Git checkout。憑證由 image builder 的 SSH agent / secret 提供，腳本不接受或保存 credentials。

## 常用環境變數

| 變數 | 用途 |
| --- | --- |
| `SKILL_Q_AGENTS` | 預設 agent selection |
| `SKILL_Q_OPENCODE_VERSION=auto|v1|v2` | OpenCode shim 策略 |
| `SKILL_Q_CODEX_COMPAT=0` | 不同步 `~/.codex/skills` compatibility path |
| `SKILL_Q_STATE_HOME` / `SKILL_Q_STATE_DIR` | state 位置 |
| `SKILL_Q_DISABLE_UPDATE_CHECK=1` | 關閉 invocation-time update hint |
| `SKILL_Q_CHECK_INTERVAL_SECONDS` | 更新檢查節流，預設 3600 秒 |
| `SKILL_Q_SNOOZE_DAYS` | 拒絕更新後延後天數，預設 7 |

## 測試

```bash
make test        # fast subset：build 正確性與必要 smoke coverage
make test-full   # 全部 integration / lifecycle 測試
```

改動 `bin/`、`tests/` 或 `bin/targets/` 時請跑 `make test-full`。每個測試有 timeout 保護（`./tests/run.sh --full --timeout 60`），fixture 由 `tests/lib/harness.sh` 提供，因此換掉範例 skills 也不影響測試。

測試只使用暫存 HOME / local Git fixtures，不會修改真實 agent 目錄。需要 `git`、Bash 與 `ripgrep (rg)`。CI 定義在 `.github/workflows/test.yml`（push 跑 fast、pull request 跑 full）。另外建議在 Claude Code、Codex CLI、OpenCode v1/v2 各做一次實際 discovery smoke test。
