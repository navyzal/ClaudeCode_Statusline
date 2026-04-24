# Vic_Statusline reference

`statusline-command.sh` 가 그리는 줄들과 그 의미. 디버깅·커스터마이즈 시 참조.

## 출력 라인 (최대 8줄)

| 순서 | 내용 | 색 | 데이터 출처 |
|---|---|---|---|
| 0 | `● Working · <tool>? · <elapsed>` / `✓ Done · Ns ago` / `○ Idle` | 주황·녹색·회색 | `/tmp/claude-activity.<uid>.<session>.json` (훅이 씀) |
| 1 | `<user> | <branch> [(wt: name)]` | 파랑·시안 | `whoami`, `git rev-parse --abbrev-ref HEAD` |
| 2 | `<dir>` | 노랑 | stdin `.workspace.current_dir` 또는 `.cwd` |
| 3 | `[Context Window] <bar> <pct>% | <model> | <effort>` | 임계값 색 + 시안/마젠타 | stdin `.context_window`, `.model`, `.output_style` |
| 4 | `*Claude Code ~5h <bar> <pct>% | <remaining> | (<reset>)` | Claude 오렌지 | stdin `.rate_limits.five_hour` |
| 5 | `*Claude Code ~7d <bar> <pct>% | <remaining> | (<reset>)` | Claude 오렌지 | stdin `.rate_limits.seven_day` |
| 6 | `Codex Review ~5h …` *또는* `Codex {OpenAI|Azure} 💰 $cost (today)` | Codex 블루 | `~/.claude/scripts/codex-usage.sh` |
| 7 | `Codex Review ~7d …` (구독 모드 한정) | Codex 블루 | 동일 |

API-key 모드에서는 6/7 이 한 줄(`Codex {provider} 💰 $cost`) 로 합쳐진다.

## 활동 배너 훅

`~/.claude/scripts/claude-activity.sh` 가 4 종 훅을 받아서
`/tmp/claude-activity.<uid>.<session_id>.json` 을 갱신:

- `UserPromptSubmit` → state=`working`, `turn_started_at`=now.
- `PreToolUse`       → state=`tool`, `tool`=tool_name (turn_started_at 유지).
- `PostToolUse`      → state=`working` (다음 도구 호출 또는 stop 까지).
- `Stop`             → state=`done`, `ended_at`=now.

`DONE_TTL=60` 초가 지나면 `done` → `idle` 회색으로 디케이.

## Codex 헬퍼

`codex-usage.sh` 는 `~/.codex/auth.json` 의 `auth_mode` 로 모드를 판정:

- `apikey`  → API-key 모드. 오늘(로컬 자정 기준) 의 `response.completed` 토큰을
  PRICING 표(공시 단가 또는 placeholder) 로 곱해 `$cost` 추정.
- 그 외     → 구독 모드. `~/.codex/logs_2.sqlite` 의 rate_limits 이벤트에서
  `~5h` / `~7d` 사용률·리셋 시각을 읽음.

60 초 캐시 (`/tmp/codex-usage-cache.<uid>.json`) — 매 statusline 호출마다
SQLite 를 두드리지 않게 함.

## 디자인 의도

- **활동 배너 (line 0)** 가 맨 위인 이유: 시선이 가장 먼저 닿는 위치에 "지금 뭔가
  돌고 있는가 / 끝났는가" 를 띄워 사용자가 굳이 터미널을 들여다보지 않아도 상태를
  주변시 (peripheral vision) 로 잡게 한다.
- **컨텍스트 바**는 임계값 색(녹·황·적) 으로 칠해서 "곧 컨텍스트 한계" 를 즉시
  알아차리게 한다. 반면 Claude/Codex rate-limit 바는 *공급자 식별* 이 더 중요해
  브랜드 컬러로 고정 (오렌지=Claude, 블루=Codex).
- `wt: <name>` 워크트리 태그: 메인 체크아웃이 아닌 linked worktree 에서 작업할
  때 무심코 잘못된 작업 트리에 커밋하는 사고를 막기 위함.
