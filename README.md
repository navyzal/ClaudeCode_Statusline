# Vic_Statusline

내 커스텀 Claude Code statusline 스킬. 한 set 의 쉘 스크립트 + 훅 +
설정을 다른 PC 로 한 번에 이식하기 위한 도구.

## 어떤 모양으로 나오는지

정상 동작 시 최대 9 줄까지 출력된다 (실제 출력은 ANSI 컬러 처리 — 아래는
컬러를 지운 샘플).

```
● Working · Bash · 0:12
navyzal | main (wt: feature-x)
~/Workspace/my-project
Claude: me@example.com | Codex: me@example.com
[Context Window] ████░░░░░░  42% | Opus 4.7 | high
*Claude Code ~5h ███░░░░░░░  32% | 3:41 | (4/24 23:00)
*Claude Code ~7d ██░░░░░░░░  21% | 5:14:22 | (4/30 18:00)
Codex Review ~5h █░░░░░░░░░  14% | 4:02 | (4/24 23:30) [2m ago]
Codex Review ~7d ██░░░░░░░░  18% | 6:22:11 | (5/1 12:00) [2m ago]
```

### 활동 배너 (첫 줄) 상태 변화

- `● Working · <tool> · 0:12` — 턴이 진행 중. 도구 이름과 턴 경과 시간을 같이 표시.
- `⏳ Wait · 0:34` — 모델 응답은 끝났지만 `run_in_background` Bash / Agent 등
  비동기 작업이 아직 열려 있는 상태. 모든 비동기가 닫히는 시점에 `Done` 으로 전환.
- `✓ Done · 3s ago` — 턴 종료 직후 (60s 동안 유지). 타임스탬프는 마지막 비동기
  작업이 실제로 끝난 시점 기준이라 `Wait` 가 길었어도 정확함.
- `○ Idle` — 유휴.

### Codex 줄 변형

- **구독 모드**: 위 샘플처럼 `~5h` / `~7d` 두 줄.
- **API-key 모드 (Azure/OpenAI)**: 한 줄로 합쳐져 오늘 누적 비용만 표시.
  ```
  Codex Azure 💰 $0.1234 (today) [5m ago]
  ```

### 컬러 규칙 (실제 출력)

- `● Working` 주황, `✓ Done` 녹색, `○ Idle` 회색.
- `[Context Window]` 바는 임계값별 녹→황→적 (곧 한계인지 한눈에).
- `*Claude Code` 바는 Claude 브랜드 오렌지, `Codex` 바는 Codex 블루 —
  공급자 식별을 위해 퍼센트와 무관하게 고정.
- `(wt: ...)` 워크트리 태그는 linked worktree 에서만 등장 (메인 체크아웃 혼동 방지).

각 줄이 어떤 stdin 필드·스크립트에서 오는지는 `reference.md` 참조.

## 새 PC 에서 복원하는 법

```bash
# 1) 스킬 폴더로 클론
mkdir -p ~/.claude/skills
cd ~/.claude/skills
git clone <git-remote-url> Vic_Statusline

# 2) Claude Code 실행 후 자연어로 설치 호출
#    "Vic_Statusline 스킬로 statusline 설치해줘"
#    또는 "내 statusline 세팅 복원해줘"
```

설치는 `SKILL.md` 의 "Install" 절차대로 진행되며:
- `~/.claude/{statusline-command.sh, scripts/claude-activity.sh, scripts/codex-usage.sh, scripts/context-threshold-check.sh}` 복사
- `~/.claude/settings.json` 의 `statusLine` + 5 개 훅 (UserPromptSubmit / PreToolUse /
  PostToolUse / Stop ×2 [activity + threshold] / SubagentStop) 을 머지 (기존 키 보존)
- 기존 파일은 모두 `.bak.<ts>` 로 백업

설치 후 Claude Code 재시작.

### 자동 핸드오프 임계 (80%)

`context-threshold-check.sh` 는 Stop hook 으로 등록되어 context window 사용량이
임계값 (기본 80%) 을 넘으면 `hookSpecificOutput.additionalContext` 로 모델에
"HANDOFF-r{N+1}.md 작성 후 stop" reminder 를 inject 한다. 프롬프트 캐시 cliff
직전에 자율 라운드 루프를 자연스럽게 멈추기 위함.

임계값 변경: `export CLAUDE_CONTEXT_HANDOFF_THRESHOLD=85`.

## 원본 PC 에서 스냅샷 갱신

statusline 스크립트를 수정한 뒤:

```
"Vic_Statusline 동기화"   ← 자연어로 호출
```

→ 라이브 `~/.claude/...` 의 4 개 스크립트가 이 레포의 `assets/` 로 복사됨.
→ 그 다음 `git add -A && git commit && git push`.

## 의존성

- `jq` (settings.json 머지용)
- `bash`
- (선택) `sqlite3` — Codex 사용량 줄을 보고 싶다면 필요. 없어도 statusline 의 나머지
  줄은 정상 동작.

## 구조

```
Vic_Statusline/
├── SKILL.md          # Claude Code 가 읽는 스킬 정의 (트리거 + 절차)
├── reference.md      # 각 statusline 라인의 의미와 데이터 출처
├── README.md         # 이 파일
└── assets/
    ├── statusline-command.sh        # 메인 렌더러 (+ ctx_pct cache 작성)
    ├── claude-activity.sh           # 활동 배너 상태 머신 (Working/Wait/Done/Idle)
    ├── codex-usage.sh               # Codex 사용량 (live RPC + sqlite 폴백)
    └── context-threshold-check.sh   # Stop hook: 80% 임계 자동 핸드오프 reminder
```
