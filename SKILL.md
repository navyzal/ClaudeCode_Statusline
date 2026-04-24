---
name: Vic_Statusline
description: Install my custom Claude Code statusline (activity banner + git + context/model/effort + Claude/Codex rate-limit bars + Codex API-key cost) onto a new machine. TRIGGER on Korean phrases "빅스테이터스라인", "내 statusline 세팅 복원", "statusline 스킬 설치", "Vic_Statusline 설치" or English "install Vic_Statusline", "restore my statusline", "set up custom statusline". Also handles syncing the live scripts back into this skill as a snapshot before pushing to git.
---

# Vic_Statusline

Claude Code 의 `statusLine` + 활동 배너 훅 세트를 다른 PC 로 이식하기 위한 스킬.

한 세트로 묶여야 동작하는 자산:

- `~/.claude/statusline-command.sh` — 메인 렌더러
- `~/.claude/scripts/claude-activity.sh` — UserPromptSubmit/PreToolUse/PostToolUse/Stop 훅 디스패처
- `~/.claude/scripts/codex-usage.sh` — Codex 사용량 SQLite 헬퍼
- `~/.claude/settings.json` 의 `statusLine` 블록 + 4 개 훅

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

# 1) 쉘 스크립트 3 개
for pair in \
  "$SKILL_DIR/assets/statusline-command.sh:$HOME/.claude/statusline-command.sh" \
  "$SKILL_DIR/assets/claude-activity.sh:$HOME/.claude/scripts/claude-activity.sh" \
  "$SKILL_DIR/assets/codex-usage.sh:$HOME/.claude/scripts/codex-usage.sh"
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
  # --- hooks: 4 종에 claude-activity.sh 훅을 append (중복 방지) ---
  | .hooks //= {}
  | reduce (
      ["UserPromptSubmit","user-prompt"],
      ["PreToolUse","tool-pre"],
      ["PostToolUse","tool-post"],
      ["Stop","stop"]
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
- `jq '.hooks | keys' "$SETTINGS"` 에 4 종이 들어있는지.
- `bash ~/.claude/statusline-command.sh <<< '{"session_id":"t","context_window":{"used_percentage":12},"model":{"display_name":"x"},"output_style":{"name":"high"}}'`
  가 3~8줄 출력하는지.

완료 후 사용자에게 "Claude Code 를 재시작하면 새 statusline 이 적용됩니다." 안내.

### 2. Sync — 원본 PC 의 최신 스크립트를 이 스킬에 반영

트리거: "Vic_Statusline 동기화", "statusline 스킬 최신화", "sync Vic_Statusline".

현재 PC 가 *원본 PC* (= `~/.claude/statusline-command.sh` 가 최신) 라고 가정하고, 그
내용을 스킬의 `assets/` 로 복사해서 스냅샷을 갱신한다.

```bash
SKILL_DIR="$HOME/.claude/skills/Vic_Statusline"
cp "$HOME/.claude/statusline-command.sh"       "$SKILL_DIR/assets/statusline-command.sh"
cp "$HOME/.claude/scripts/claude-activity.sh"  "$SKILL_DIR/assets/claude-activity.sh"
cp "$HOME/.claude/scripts/codex-usage.sh"      "$SKILL_DIR/assets/codex-usage.sh"
chmod +x "$SKILL_DIR/assets/"*.sh
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$SKILL_DIR/assets/.synced_at"
```

동기화 후 "git add / commit / push 해서 다른 PC 에 반영하세요" 안내.

### 3. Uninstall — 옵션

트리거: "Vic_Statusline 제거".

- `settings.json` 의 `.statusLine` 삭제, `.hooks.*` 에서 `claude-activity.sh` 를
  포함한 엔트리만 제거 (다른 훅은 보존).
- 쉘 스크립트 3 개는 `.bak.<ts>` 로 남기고 원본은 삭제.

## 지금 작동 여부 체크

설치 후 문제가 있으면:

- `cat /tmp/claude-activity.$(id -u).*.json 2>/dev/null` 로 훅이 상태 파일을 쓰고
  있는지 확인. 비어있으면 훅 등록 실패.
- `ls -la ~/.codex/logs_2.sqlite` 없으면 Codex 줄은 당연히 안 뜸.
- statusline 전체가 안 뜨면 Claude Code 재시작 필요.

## 범위 밖

- 이 스킬은 `statusLine` + 활동 훅만 건든다. `enabledPlugins`, `permissions`,
  `model`, `effortLevel` 등 나머지 `settings.json` 키는 일절 건드리지 않는다.
- Codex CLI 자체의 설치/설정(`~/.codex/auth.json`, `config.toml`) 은 별개. Codex
  가 없으면 해당 줄만 안 뜨고 나머지는 정상 동작.
