# skill-q Architecture

框架繼承自 [skill-x-starter](https://github.com/wahengchang/skill-x-starter)；skill-q 只改變技能集合（全部 `q-` prefix、quick／lightweight），lifecycle 機制維持一致。

## 1. Goal

這個 repository 解決的是「同一組個人 skills，如何在多台機器與多個 AI runtime 上保持同一來源、可更新、可診斷，而且不誤碰使用者既有檔案」。

核心原則：

1. **canonical source only**：技能作者只維護 `commands-src/`。
2. **generated artifacts are disposable**：`commands/` 與 transformed artifacts 不進 Git。
3. **deployment ownership is explicit**：manifest，而不是路徑猜測，是唯一 ownership proof。
4. **runtime differences live at the edge**：共同 canonical build 與 target adapters 分離。
5. **updates are conservative**：fetch + preview + fast-forward only；dirty/diverged 不自動處理。
6. **quick means low ceremony**：skills 保持單一職責、按需探索、直接 handoff；不要把 heavyweight workflow state 搬回來。

## 2. Data flow

```text
tracked source
┌──────────────────────────────┐
│ commands-src/<skill>/        │
│ _shared/                     │
└──────────────┬───────────────┘
               │ bin/build.sh
               ▼
┌──────────────────────────────┐
│ canonical staging            │
│ header injection             │
│ support-file materialization │
└──────────────┬───────────────┘
               │
      ┌────────┴─────────┐
      ▼                  ▼
 commands/         transformed artifacts
 canonical         e.g. opencode-commands/
      │                  │
      └────────┬─────────┘
               │ bin/skill-q sync
               ▼
        runtime discovery paths
               │
               ▼
  installation manifest / doctor
```

Canonical 處理包含 frontmatter 驗證（CRLF 容忍）、shared header 注入、`## Provenance` section 移除，以及 support file materialize（`cp -aL`，dereference shared symlink）。Build 先完整 stage，成功後才 swap final artifact directory，避免 consumer 看到半套輸出。artifact destination 必須是 repo 內 normalized relative child，且各 destination 不得重疊。

## 3. Lifecycle CLI

`bin/skill-q` 是唯一 lifecycle owner：

- `init`: resolve agent selection → build → sync → manifest。
- `install`: idempotent re-apply；若 checkout path 改變，依同一 installation id 修復 managed links。
- `sync`: 使用既有 build artifact 重新連結，並 prune 本 installation 已不再管理的 entry。
- `status`: 顯示 repository / commit / upstream / behind-ahead / worktree / agent versions / managed-path health；`--json` 為 machine-readable surface。
- `doctor`: 逐 entry 分成 `ok / missing / stale / foreign`。
- `update`: fetch tracked upstream → preview → clean/divergence gate → `merge --ff-only` → rebuild → sync → manifest refresh。
- `uninstall`: 只刪 manifest 中、而且當下仍指向原 target 的 path；user-owned replacement 一律保留。

Compatibility wrappers 只轉交給 lifecycle CLI，不再各自維護另一套規則。

## 4. Installation identity and manifest

每個 Git checkout 在 `.git/skill-q-install-id` 保存穩定 id；因此資料夾搬家後 identity 不變。state 預設：

```text
${XDG_STATE_HOME:-~/.local/state}/skill-q/<installation-id>/install.json
```

manifest 記錄 repository URL、checkout path、installed commit、selected agents、agent versions、OpenCode mode、skills、timestamps，以及每個 managed entry 的 path/target。

同一 HOME 可以存在多個 checkout。任何 checkout 只能操作自己 manifest 證明管理的 entries，避免 A repo 的 sync/uninstall 接管 B repo。

## 5. Target model

`bin/targets/targets.conf` 有兩種 target：

### Canonical consumer

consumer 可以直接讀 `commands/<name>/SKILL.md`，只需 metadata：

```bash
CANONICAL_CONSUMERS+=("my-agent:~/.my-agent/skills")
```

### Transformed target

consumer 需要不同 wire format 時新增 adapter：

```text
bin/targets/<adapter>.sh build <canonical-stage> <artifact-stage>
bin/targets/<adapter>.sh sync <artifact-dir>
bin/targets/<adapter>.sh bootstrap <artifact-dir>
```

adapter 永遠拿到已處理的 canonical tree；header injection、support file copy 不應在每個 adapter 重做。

## 6. OpenCode compatibility

- v1：skills 本身同步到 skills directory，另生成 thin command shims，透過 `skill` tool 載入 canonical skill。
- v2：原生 skill slash catalog，不建立 shim，避免同一 skill 顯示兩次。
- detection 可用 `SKILL_Q_OPENCODE_VERSION` override。

## 7. Update model

Invocation-time `bin/update-check` 只做低成本、可失敗開放的提示，並以 per-installation state 節流。真正的更新決策由 `bin/skill-q status/update` 做：

```text
fetch upstream
   │
   ├─ current/ahead → 不 pull
   ├─ diverged      → refuse
   ├─ dirty         → refuse
   └─ behind + clean
          │
          ▼
      preview + confirm
          │
          ▼
      fast-forward only
          │
      build → sync → doctor
```

## 8. Cloud / pinned install

`bin/cloud-bootstrap.sh` 使用 pinned ref，在 temporary checkout 中跑該 ref 自己的 build，然後 copy artifacts。它不建立 live symlink，也不保存 Git credentials。若 reused HOME 中已有 interactive installation symlink，只有 manifest 證明是本 framework 管理的 symlink 才會轉成 pinned copy；foreign symlink 保留。

## 9. Test model

`tests/lib/harness.sh` 是所有 suite 的共用 harness，負責三件事：

1. **suite selection**：`run_test --fast` 標記的測試組成 fast subset（`make test`），其餘只在 `make test-full` 執行。
2. **bounded execution**：每個測試有 timeout，逾時會終止該測試與其所有子行程並記為失敗，deadlock 不會拖垮整個 run；`tests/lib/timeout-fixture.sh` 是這條路徑本身的 regression fixture。
3. **fixtures**：template 只建立一次（artifact-free 與 prebuilt 兩份），再 `cp -a` 給各測試，因此測試彼此隔離又不必重複 build。

測試對象是 mechanism，不是某一組 skill 內容：fixture skill 由 harness 在缺少時生成，所以 fork 換掉全部範例 skills 之後 suite 仍然成立。

## 10. What is deliberately not tracked

`commands/`、`opencode-commands/` 是 derived data。把它們 commit 會形成第二個 truth source，並讓 source-only clone、target adapter 擴充與 update rebuild 更難保持一致，因此一律 gitignore。
