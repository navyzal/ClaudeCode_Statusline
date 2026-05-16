---
name: Vic_Statusline
description: Install my custom Claude Code statusline (activity banner + git + context/model/effort + Claude/Codex rate-limit bars + Codex API-key cost) onto a new machine. TRIGGER on Korean phrases "빅스테이터스라인", "내 statusline 세팅 복원", "statusline 스킬 설치", "Vic_Statusline 설치" or English "install Vic_Statusline", "restore my statusline", "set up custom statusline". Also handles syncing the live scripts back into this skill as a snapshot before pushing to git.
---

# Vic_Statusline

Claude Code 의 `statusLine` + 활동 배너 훅 세트를 다른 PC 로 이식하기 위한 스킬.

한 세트로 묶여야 동작하는 자산:

- `~/.claude/statusline-command.sh` — 메인 렌더러 (`.context_window.used_percentage` 를 `/tmp/claude-ctx-pct.<uid>.<sid>` 에 cache 하는 한 줄 포함)
- `~/.claude/scripts/claude-activity.sh` — UserPromptSubmit/PreToolUse/PostToolUse/Stop/SubagentStop 훅 디스패처
- `~/.claude/scripts/codex-usage.sh` — Codex 사용량 SQLite 헬퍼
- `~/.claude/scripts/context-threshold-check.sh` — Stop 훅: cache 파일 read → 80%+ 시 `hookSpecificOutput.additionalContext` 로 "HANDOFF 작성 후 stop" reminder 모델 inject (자율 라운드 룰 정합)
- `~/.claude/settings.json` 의 `statusLine` 블록 + 5 개 훅 (UserPromptSubmit / PreToolUse / PostToolUse / Stop ×2 [activity + threshold] / SubagentStop)

세부 동작·각 줄 의미는 `reference.md` 참조.

## 호출 분기

### 1. Install — 새 PC 에 내 statusline 복원

트리거: "Vic_Statusline 설치", "내 statusline 세팅 복원해줘", "statusline 스킬 설치",
"install Vic_Statusline".

#### 사전 조건 체크
- `jq` 설치 여부: `command -v jq`. 없으면 중단 + 안내 (`brew install jq` / `apt install jq`).
- `~/.claude/` 디렉토리 존재 여부 확인. 없으면 `mkdir -p`.

#### 절차
이 스킬 디렉토리(`~/.claude/skills/Vic_Statusline/`) 의 `assets/` 3 개를 대상 경로로
복사한다. 기존 파일은 전부 `.bak.<YYYYMMDD-HHMMSS>` 로 백업 후 덮어쓴다.

```bash
SKILL_DIR="$HOME/.claude/skills/Vic_Statusline"
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$HOME/.claude/scripts"

backup_if_exists() {
  local f=$1
  [ -f "$f" ] && cp -p "$f" "${f}.bak.${TS}"
}

# 1) 쉘 스크립트 4 개
for pair in \
  "$SKILL_DIR/assets/statusline-command.sh:$HOME/.claude/statusline-command.sh" \
  "$SKILL_DIR/assets/claude-activity.sh:$HOME/.claude/scripts/claude-activity.sh" \
  "$SKILL_DIR/assets/codex-usage.sh:$HOME/.claude/scripts/codex-usage.sh" \
  "$SKILL_DIR/assets/context-threshold-check.sh:$HOME/.claude/scripts/context-threshold-check.sh"
do
  src=${pair%%:*}
  dst=${pair##*:}
  backup_if_exists "$dst"
  cp "$src" "$dst"
  chmod +x "$dst"
done
```

#### settings.json 머지

`~/.claude/settings.json` 이 없으면 `{}` 로 신규 생성. 있으면 `.bak.<ts>` 로 백업 후
`jq` 로 머지:

```bash
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] && cp -p "$SETTINGS" "${SETTINGS}.bak.${TS}" || echo '{}' > "$SETTINGS"

# $HOME 을 실제 경로로 박아서 hook command 를 만든다 (플랫폼간 $HOME 전개 차이 회피).
ACTIVITY="$HOME/.claude/scripts/claude-activity.sh"

jq --arg home "$HOME" --arg act "$ACTIVITY" '
  # --- statusLine: 내 값으로 덮어쓰기 ---
  .statusLine = {
    "type": "command",
    "command": ("bash " + $home + "/.claude/statusline-command.sh")
  }
  # --- hooks: 5 종에 claude-activity.sh 훅을 append (중복 방지) ---
  | .hooks //= {}
  | reduce (
      ["UserPromptSubmit","user-prompt"],
      ["PreToolUse","tool-pre"],
      ["PostToolUse","tool-post"],
      ["Stop","stop"],
      ["SubagentStop","subagent-stop"]
    ) as $pair (.;
      .hooks[$pair[0]] //= []
      | if any(.hooks[$pair[0]][]?.hooks[]?.command // ""; test("claude-activity\\.sh"))
        then .
        else .hooks[$pair[0]] += [{
          "hooks": [{
            "type": "command",
            "command": ("bash " + $act + " " + $pair[1])
          }]
        }]
        end
    )
' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
```

#### 설치 검증
- `jq '.statusLine' "$SETTINGS"` 출력 확인.
- `jq '.hooks | keys' "$SETTINGS"` 에 5 종(UserPromptSubmit/PreToolUse/PostToolUse/Stop/SubagentStop)이 들어있는지.
- `jq '.hooks.Stop[0].hooks | length' "$SETTINGS"` ≥ 2 (claude-activity.sh + context-threshold-check.sh).
- `bash ~/.claude/statusline-command.sh <<< '{"session_id":"t","context_window":{"used_percentage":12},"model":{"display_name":"x"},"effort":{"level":"high"}}'`
  가 3~8줄 출력하는지 + line 3 의 effort 컬럼에 `high` 가 보이는지 + `/tmp/claude-ctx-pct.$(id -u).t` 에 `12` cache 됐는지.
- 임계값 테스트: `echo "85" > /tmp/claude-ctx-pct.$(id -u).t-thr && echo '{"session_id":"t-thr"}' | bash ~/.claude/scripts/context-threshold-check.sh` 가 `hookSpecificOutput.additionalContext` JSON 출력하는지 (80% 이상). `echo "50" > ...` 시 빈 출력 (이하).

완료 후 사용자에게 "Claude Code 를 재시작하면 새 statusline + 자동 핸드오프 임계 (80%) 가 적용됩니다." 안내. 임계값 변경 시 `export CLAUDE_CONTEXT_HANDOFF_THRESHOLD=85` 안내.

#### Stop hook 의 context-threshold-check.sh 추가 (자율 라운드 자동 핸드오프)

위 §settings.json 머지 의 jq 명령은 `claude-activity.sh` 만 등록한다. 자율 라운드 자동 핸드오프 (컨텍스트 80%+ 시 모델이 자동으로 HANDOFF-r{N+1}.md 작성 후 stop) 를 위해 Stop hook 에 `context-threshold-check.sh` 도 추가 등록 필요. 별도 jq 명령으로 적용 (기존 entry 는 보존):

```bash
CTX_CHECK="$HOME/.claude/scripts/context-threshold-check.sh"

jq --arg ctx "$CTX_CHECK" '
  .hooks //= {}
  | .hooks.Stop //= []
  | if (.hooks.Stop | length) == 0
    then .hooks.Stop = [{"hooks": [{"type":"command","command":("bash " + $ctx),"timeout":3}]}]
    else
      if any(.hooks.Stop[]?.hooks[]?.command // ""; test("context-threshold-check\\.sh"))
      then .
      else .hooks.Stop[0].hooks += [{
        "type": "command",
        "command": ("bash " + $ctx),
        "timeout": 3
      }]
      end
    end
' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
```

**메커니즘**:
- `statusline-command.sh` 가 stdin JSON 의 `.context_window.used_percentage` 를 매 렌더링 시점마다 `/tmp/claude-ctx-pct.<uid>.<sid>` 에 cache.
- Stop hook (`context-threshold-check.sh`) 가 매 모델 응답 종료 시점에 cache 파일 read + 80%+ 시 `hookSpecificOutput.additionalContext` JSON 으로 reminder 모델 inject ("HANDOFF 작성 후 stop").
- 모델은 다음 turn 에 reminder 보고 자율 라운드 룰 (`feedback_autonomous_rounds.md`) 정합 — 새 라운드 시작 X, HANDOFF-r{N+1}.md 작성 + commit + 1단락 보고 + STOP.

**임계값 환경변수**: `CLAUDE_CONTEXT_HANDOFF_THRESHOLD` (기본 80, 정수만). `export CLAUDE_CONTEXT_HANDOFF_THRESHOLD=85` 같이 settings 의 `env` 블록 또는 shell rc 에 등록.

### 2. Sync — 원본 PC 의 최신 스크립트를 이 스킬에 반영

트리거: "Vic_Statusline 동기화", "statusline 스킬 최신화", "sync Vic_Statusline".

현재 PC 가 *원본 PC* (= `~/.claude/statusline-command.sh` 가 최신) 라고 가정하고, 그
내용을 스킬의 `assets/` 로 복사해서 스냅샷을 갱신한다.

```bash
SKILL_DIR="$HOME/.claude/skills/Vic_Statusline"
cp "$HOME/.claude/statusline-command.sh"             "$SKILL_DIR/assets/statusline-command.sh"
cp "$HOME/.claude/scripts/claude-activity.sh"        "$SKILL_DIR/assets/claude-activity.sh"
cp "$HOME/.claude/scripts/codex-usage.sh"            "$SKILL_DIR/assets/codex-usage.sh"
cp "$HOME/.claude/scripts/context-threshold-check.sh" "$SKILL_DIR/assets/context-threshold-check.sh"
chmod +x "$SKILL_DIR/assets/"*.sh
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$SKILL_DIR/assets/.synced_at"
```

동기화 후 "git add / commit / push 해서 다른 PC 에 반영하세요" 안내.

### 3. Uninstall — 옵션

트리거: "Vic_Statusline 제거".

- `settings.json` 의 `.statusLine` 삭제, `.hooks.*` 에서 `claude-activity.sh` + `context-threshold-check.sh` 를 포함한 엔트리만 제거 (다른 훅은 보존).
- 쉘 스크립트 4 개 (statusline-command / claude-activity / codex-usage / context-threshold-check) 는 `.bak.<ts>` 로 남기고 원본은 삭제.

## 지금 작동 여부 체크

설치 후 문제가 있으면:

- `cat /tmp/claude-activity.$(id -u).*.json 2>/dev/null` 로 훅이 상태 파일을 쓰고
  있는지 확인. 비어있으면 훅 등록 실패.
- `ls -la /tmp/claude-ctx-pct.$(id -u).* 2>/dev/null` 로 statusline 의 ctx_pct cache 가 쓰이고 있는지 확인. 비어있으면 statusline-command.sh 에 cache block 누락 또는 stdin JSON 에 `.session_id` 부재.
- `ls -la ~/.codex/logs_2.sqlite` 없으면 Codex 줄은 당연히 안 뜸.
- statusline 전체가 안 뜨면 Claude Code 재시작 필요.
- 자동 핸드오프 임계가 trigger 안 되면: (1) `bash ~/.claude/scripts/context-threshold-check.sh <<< '{"session_id":"<your-session>"}'` 직접 실행 / (2) `jq '.hooks.Stop[0].hooks' ~/.claude/settings.json` 에 `context-threshold-check.sh` 등록 확인 / (3) cache 파일에 80% 이상 값 write 후 위 명령 재실행.

## 범위 밖

- 이 스킬은 `statusLine` + 활동 훅만 건든다. `enabledPlugins`, `permissions`,
  `model`, `effortLevel` 등 나머지 `settings.json` 키는 일절 건드리지 않는다.
- Codex CLI 자체의 설치/설정(`~/.codex/auth.json`, `config.toml`) 은 별개. Codex
  가 없으면 해당 줄만 안 뜨고 나머지는 정상 동작.
