# Vic_Statusline

내 커스텀 Claude Code statusline 스킬. 한 set 의 쉘 스크립트 + 훅 +
설정을 다른 PC 로 한 번에 이식하기 위한 도구.

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
- `~/.claude/{statusline-command.sh, scripts/claude-activity.sh, scripts/codex-usage.sh}` 복사
- `~/.claude/settings.json` 의 `statusLine` + 4 개 활동 훅을 머지 (기존 키 보존)
- 기존 파일은 모두 `.bak.<ts>` 로 백업

설치 후 Claude Code 재시작.

## 원본 PC 에서 스냅샷 갱신

statusline 스크립트를 수정한 뒤:

```
"Vic_Statusline 동기화"   ← 자연어로 호출
```

→ 라이브 `~/.claude/...` 의 3 개 스크립트가 이 레포의 `assets/` 로 복사됨.
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
    ├── statusline-command.sh
    ├── claude-activity.sh
    └── codex-usage.sh
```
