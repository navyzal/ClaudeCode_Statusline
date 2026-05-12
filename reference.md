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

## 자동 핸드오프 임계 hook

`~/.claude/scripts/context-threshold-check.sh` 는 Stop hook 의 두 번째 entry 로 등록되어 자율 라운드 자동 핸드오프 트리거를 담당:

- **Cache 작성** — `statusline-command.sh` 가 매 렌더링 시점마다 stdin JSON 의 `.context_window.used_percentage` 를 `/tmp/claude-ctx-pct.<uid>.<session_id>` 에 cache (한 줄, decimal). statusline 은 매 입력/출력/refresh 시 호출되므로 거의 실시간 반영.
- **Cache 읽기** — Stop hook 시 동일 path 의 cache read. 없거나 비어있으면 silent exit 0 (no-op).
- **임계 체크** — 환경변수 `CLAUDE_CONTEXT_HANDOFF_THRESHOLD` (기본 `80`) 와 정수 비교. 미만이면 silent exit 0.
- **임계 도달 시** — `hookSpecificOutput.additionalContext` JSON 출력. Claude Code 가 다음 모델 turn 의 system message 에 inject. 메시지 내용 = "HANDOFF-r{N+1}.md 작성 후 stop" (자율 라운드 룰 정합).
- **fail-safe** — 모든 분기가 `exit 0`. cache 부재 / jq 부재 / 정수 변환 실패 / 임계 미만 모두 정상 종료. Stop hook 자체를 절대 block 하지 않는다.

**왜 Stop hook 인가**: 모델 응답 종료 시점 = 라운드 종료 시점 의 가장 명확한 시그널. PostToolUse 도 가능하나 매 도구마다 trigger = 노이즈 ↑. UserPromptSubmit 은 사용자 프롬프트 제출 시점 = 자율 모드에서 거의 안 발생.

**왜 statusline 만 ctx_pct 받는가**: Claude Code 의 stdin JSON 은 hook 종류별로 schema 다름. statusline 의 stdin = full session state (`.context_window` 포함). Stop hook 의 stdin = `.session_id` + `.tool_name` 등 최소 정보. Cache 파일이 두 schema 를 잇는 bridge.

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
