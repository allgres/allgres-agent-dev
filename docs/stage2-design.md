# 2단계 설계: 대시보드 정리와 첫 실행 경험

> 상태: **2a(메뉴), 2b(홈), 2c(용어와 빈 화면) 모두 구현됨. 2단계 끝.** [improvement-plan.md](improvement-plan.md)의 2단계를 현재 대시보드 코드에 맞춰 구체화한 설계입니다. 7장의 결정은 모두 권장안으로 진행했습니다.

## 1. 목표와 범위

처음 쓰는 사람이 설명서 없이 **"모델 연결 → 팀 만들기 → 첫 일 맡기기"** 를 끝낼 수 있게 하고, 메뉴 이름만 보고 원하는 기능이 어디 있는지 짐작할 수 있게 합니다.

범위는 **메뉴 구조, 홈 화면, 설정 화면 나누기, 용어**입니다. 기능은 바꾸지 않습니다. 새 연결 방식(MCP, 판단 모델)은 3단계, 크리에이터 에이전트는 4단계입니다. 대시보드는 의존성 없는 단일 파일(`web/index.html`)이고, 이 단계도 그 구조를 유지합니다. 캔버스(`/canvas`)는 별도 앱이라 건드리지 않습니다.

## 2. 지금 무엇이 문제인가 (코드에서 확인)

| 문제 | 근거 |
|---|---|
| 메뉴 묶음이 이름과 내용이 안 맞음 | "Chat" 묶음에 승인(Approvals)이 있고, "Settings" 묶음에 설정이 아닌 Agents, Memories, Audit이 있음 (`nav()`, 236행) |
| 설정 화면이 너무 많은 것을 담음 | 한 화면에 모델, 가격, API 연결, 함수, 사용법 문서, 실험, 일정, 허용 목록, 접근, 테마, 사용자가 있고 탭 셋(Integrations, Automation, Administration)으로만 나눔 (`settings()`, 748행) |
| 홈이 소개 문구와 숫자 위주 | 첫 영역이 홍보 문구("One database. One extension.")이고, 카드가 `Outbound`, `SQL`처럼 내부 용어. 지금 내가 해야 할 일(승인 대기 등)이 없음 |
| 첫 실행 안내가 채팅 하나에만 맞춰져 있음 | "Start a conversation" 3단계가 General 채팅까지만 안내하고, 팀 만들기와 일 맡기기는 이어지지 않음 |
| 같은 개념에 이름이 여럿 | 함수, 사용법 문서, 도구, 스킬, 능력(abilities)이 화면마다 섞임 |
| 활동 기록이 감사 메뉴 안에 있음 | 세션, 작업, 로그가 "Audit" 안의 탭 (`auditPage()`, 538행). 일의 진행 상황을 보려고 감사 메뉴를 열어야 함 |

## 3. 새 메뉴 구조

내부 페이지 ID와 저장된 화면 상태(`allgres_ui_page`)는 바꾸지 않고, **묶음과 이름만** 바꿉니다. 그래서 이미 쓰는 사람의 저장된 상태가 깨지지 않습니다.

**관리자**

| 묶음 | 항목 | 내용 | 지금 어디에 있나 |
|---|---|---|---|
| (맨 위) | **Home** | 아래 4장 | Dashboard |
| **Organization** | Canvas | 팀 그림 (별도 앱으로 이동) | 그대로 |
| | Agents | 에이전트 목록과 설정 | Settings 묶음 |
| | People | 사용자, 소속, 역할, 결재 규칙, 대리 | Settings의 Users + 승인 화면의 Routing 탭 |
| **Work** | General | 일반 채팅 | Chat 묶음 |
| | Projects | 프로젝트 채팅 | Chat 묶음 |
| | Approvals | 승인, 제안, 수정안, 판단 기록 | Chat 묶음 (Routing 탭은 People으로 이동) |
| | Activity | 세션, 작업, 로그 | Audit의 탭 |
| | Schedules | 정해진 일정으로 도는 일 | Settings의 Automation |
| **Abilities** | Functions & procedures | 에이전트가 쓰는 도구와 사용법 문서, 모델 실험 | Settings의 Automation |
| | Memories | 기억 | Settings 묶음 |
| | SQL | SQL 콘솔 | 맨 위 SQL |
| **Connections** | Models & prices | 모델 제공사, 가격 | Settings의 Integrations |
| | APIs | API 연결 | Settings의 Integrations |
| **Settings** | Access & appearance | 토큰, 내 이름, SQL 허용 목록, 테마, 자체 점검 | Settings의 Administration |
| | Audit log | 감사 기록 | Audit의 Log 탭 |

**일반 사용자**는 지금처럼 Chat(General, Projects, Approvals)과 My agents입니다. 묶음 이름만 Work로 맞춥니다.

3단계의 MCP 서버와 판단 모델 연결은 Connections에 항목으로 추가됩니다.

## 4. 홈 화면

위에서 아래로, **지금 할 일이 먼저** 옵니다.

1. **시작하기** (아직 끝나지 않은 단계가 있을 때만 보임)
   1. 모델 연결: 제공사를 추가하고 연결 시험이 통과함 → *Connections로 이동*
   2. 팀 만들기: 사용자가 만든 에이전트가 하나 이상 있음 → *Canvas로 이동*
   3. 첫 일 맡기기: 사용자가 만든 에이전트가 맡은 작업이 하나 이상 완료됨 → *Work → General로 이동*
   각 단계는 완료 여부를 서버가 이미 돌려주는 값(`providers`, `agents`, 완료된 작업 수)으로 판단합니다. 새 기록을 만들지 않습니다. 모두 끝나면 이 영역은 사라집니다.
2. **내가 결정할 것**: 승인 요청 중 내가 결정할 수 있는 것(`approvals.list` `mine`) 최대 3건과 "모두 보기". 한 줄 사유와 에이전트 이름, 바로 승인/거절 버튼.
3. **진행 중**: 실행 중이거나 대기 중인 작업(에이전트, 목표, 상태).
4. **주의가 필요한 것**: 실패한 작업, 연결 시험이 실패한 제공사, 만료된 승인. 없으면 이 영역은 보이지 않음.
5. **시스템 상태**(접힘): 지금의 카드(에이전트 수, 작업자 등)는 여기로. 내부 용어는 풀어서(Outbound → "Waiting external calls", SQL → "Waiting SQL calls").

홍보 문구 영역은 제거합니다.

## 5. 설정 화면 나누기

`settings()`는 한 번에 모든 패널을 그리고, 패널 제목으로 탭 그룹을 정합니다(`data-settings-group`). 이 구조를 그대로 두고 **어느 그룹을 보여줄지 인자로** 받게 합니다. 패널 코드는 옮기지 않으므로 기능이 깨질 위험이 작고, 메뉴 항목마다 같은 함수에 다른 그룹을 넘기면 됩니다.

| 메뉴 항목 | 보여줄 패널 |
|---|---|
| Models & prices | LLM providers, Model prices |
| APIs | API connections |
| Functions & procedures | Functions, Procedures, Capability lifecycle, Function model experiments |
| Schedules | Schedules |
| Access & appearance | Dashboard access, SQL sandbox allowlist, Theme |

기존 "Settings" 한 화면은 없애지 않고 **Access & appearance**로 줄입니다. Users 패널은 People로 옮깁니다.

## 6. 용어

화면 제목과 안내 문구에서만 바꾸고, 표의 열 이름이나 RPC 이름은 건드리지 않습니다.

| 화면에서 쓰는 말 | 뜻 | 바꿀 곳 |
|---|---|---|
| Abilities | 에이전트가 쓸 수 있는 함수, 사용법 문서, 도구의 총칭 | 메뉴 묶음 이름, 안내 문구 |
| Function | 에이전트가 호출하는 도구 한 개 | 패널 제목에 "(a tool an agent can call)" 보충 |
| Procedure | 이름 붙은 사용법 문서 | 패널 제목에 "(a how-to an agent follows)" 보충 |
| Decision / Request | 사람이 결정해야 하는 것 | Approvals 안내 문구 |

## 7. 정해야 할 것 (권장안으로 진행)

1. **메뉴 이름을 영어로 유지:** 대시보드는 영어 전용이므로(`I18N`) 이름도 영어로 둡니다.
2. **Canvas는 Organization 묶음에 두되 새 탭에서 열지 않음:** 지금처럼 같은 탭에서 이동합니다.
3. **Routing 탭을 People로 옮김:** 결재 규칙은 사람과 역할에 묶인 설정이므로 승인 화면보다 People에 어울립니다. Approvals는 요청을 처리하는 곳으로 남깁니다.
4. **Schedules를 Work에 둠:** 일정은 "일을 시키는 방법"이라 설정이 아닙니다.
5. **홈의 "시스템 상태"를 접힌 상태로 기본 표시.**

## 8. 구현 순서와 검증

| 조각 | 내용 | 완료 기준 |
|---|---|---|
| 2a | 새 메뉴 묶음과 이름, `settings()`에 그룹 인자, People(사용자 + 기존 Routing), Activity, Schedules 페이지 | 기존 기능이 모두 새 위치에서 열림. 저장된 이전 페이지 상태에서도 화면이 열림. 브라우저 테스트의 메뉴 이름 갱신 |
| 2b | 새 홈: 시작하기, 내가 결정할 것, 진행 중, 주의가 필요한 것, 접힌 시스템 상태 | 새 설치에서 3단계 안내가 순서대로 보이고, 단계를 마칠 때마다 다음으로 넘어감. 승인 대기가 있으면 홈에서 바로 결정됨 |
| 2c | 용어와 빈 화면 안내 정리 | 위 6장의 변경이 반영되고, 비어 있는 화면마다 다음에 할 일이 한 줄로 보임 |

공통: 각 조각은 별도 PR이고, 브라우저 테스트와 로컬 화면 확인(스크린샷)을 거친 뒤 병합합니다. 데이터베이스는 바꾸지 않으므로 `fn_selftest`는 그대로입니다. 새 설치 기준으로 시나리오(팀 만들기부터 첫 일 맡기기)를 처음부터 끝까지 한 번 눌러 봅니다.
