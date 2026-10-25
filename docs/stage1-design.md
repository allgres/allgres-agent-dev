# 1단계 설계: 사람 조직, 결재, 판단 지점, 판단 기록

> 상태: **1a, 1b, 1c 구현됨** (조직·결재: [approvals-and-roles.md](approvals-and-roles.md), 판단 기록·내보내기: [decision-records.md](decision-records.md), 화면: 승인 페이지의 Mine/All, Routing, Decisions 탭). 7장의 결정은 모두 권장안으로 진행했습니다. [docs/improvement-plan.md](improvement-plan.md)의 1단계를 현재 코드에 맞춰 구체화한 설계입니다.

## 1. 목표와 범위

1단계가 끝나면 다음이 성립합니다.

1. 사람에게 소속(부서)과 역할이 있고, 승인 요청마다 **누가 결정해야 하는지**가 규칙으로 정해집니다. 기한이 지나면 상위 역할로 올라가고, 대리 결재자를 둘 수 있습니다.
2. 사람이 승인 요청이나 변경 제안을 결정할 때마다 그 결정이 **Laya 공식 학습 형식**으로 PostgreSQL에 쌓입니다. Laya를 쓰지 않아도 쌓입니다.
3. 쌓인 기록을 공식 `laya-train` / `laya-evals`가 읽는 JSONL로 내보낼 수 있습니다.

범위 밖(뒤 단계): 메뉴 재구성(2단계), 도구 위험 등급에 따른 물리 동작 승인(3단계), 팀 창구 담당 배정(5단계), Laya 연결과 지점별 모드 동작(6단계). 이 단계에서는 판단 지점의 `mode` 값을 저장만 하고 사용하지 않습니다.

## 2. 현재 코드에서 확인한 사실

| 항목 | 현재 상태 | 근거 |
|---|---|---|
| 사용자 | 역할은 `admin`, `user` 둘뿐. 소속 개념 없음 | `sql/control_plane.sql` `users` |
| 승인 요청 | `human_approvals`에 결정 권한자 정보가 없고, 누가 결정했는지도 저장하지 않음 | 같은 파일 `human_approvals` |
| 누가 결정했나 | 감사 로그에는 남음. 요청마다 세션의 사용자 id가 `allgres.audit_user_id`로 기록됨 | `allgres_private.audit()` |
| 승인 요청이 생기는 곳 | 에이전트의 `await_human`(24시간 만료), 실행 규칙의 `approve`, 결과를 알 수 없는 외부 호출 | `control_plane.sql`, `execution_guards.sql` |
| 변경 제안이 생기는 곳 | `create_agent`, `create_function`, `update_function`, `function_override`, `policy_change` 등 | `change_proposals`, `fn_decide_proposal` |
| 일반 사용자의 가시 범위 | 본인에게 배정된 에이전트(`user_agent_assignments`)의 작업에 속한 승인만 보임. 관리자는 전부 | `visible_agent_ids()`, `approvals.list` |
| 결정 API | `approvals.decide(approval_id, accept, reply)`, `proposals.decide(proposal_id, approve, reply)`. 선택지는 승인과 거절 둘뿐 | `grants_and_facade.sql` |
| 기한 처리 | `fn_watchdog`가 만료된 승인을 회수함 | `control_plane.sql` |

계획서 7.2절은 선택지에 "수정 요청"을 넣었지만, 현재 시스템에는 그 상태가 없습니다(승인, 거절과 답변 글만 있음). 1단계 판단 지점의 선택지는 `approve` / `reject` 둘로 하고, 수정 요청은 그 상태가 생길 때 질문 버전을 올려 추가합니다.

## 3. 사람 조직과 결재 (1a)

### 3.1 테이블

`org_units`: 부서와 팀. 중첩 가능.
| 열 | 내용 |
|---|---|
| `unit_id`, `name`(유일), `parent_unit_id` | 순환 방지는 캔버스 그룹과 같은 방식으로 검사 |

`org_roles`: 역할 이름 목록(예: 마케팅 본부장, 법무 담당).
| 열 | 내용 |
|---|---|
| `role_id`, `name`(유일), `description` | |

`org_memberships`: 한 사람이 어느 부서에서 어떤 역할을 맡는지. 한 행이 한 사실입니다.
| 열 | 내용 |
|---|---|
| `user_id`, `unit_id`(널 허용), `role_id` | 기본키는 세 열의 조합. 한 사람이 여러 행을 가질 수 있음 |

시스템 권한(`users.role`의 `admin`/`user`)은 그대로 둡니다. 조직 역할은 "누가 결정하나"에만 쓰이고, 다른 권한을 주지 않습니다.

### 3.2 결재 규칙

`approval_rules`: 승인 요청이나 변경 제안을 어느 역할에게 보낼지.
| 열 | 내용 |
|---|---|
| `rule_id`, `priority` | 숫자가 작을수록 먼저 맞춰 봄 |
| `applies_to` | `approval` 또는 `proposal` |
| `match_agent_group_id` | 널 허용. 작업의 에이전트가 이 캔버스 그룹(또는 그 하위 그룹)에 속할 때만 적용 |
| `match_kind` | 널 허용. 제안 종류(`create_function` 등) 또는 승인 유형(`await_human`, `execution`, `outbound_unknown`) |
| `decider_role_id`, `decider_unit_id` | 결정할 역할과, 널이 아니면 그 부서에 속한 사람만 |
| `escalate_after`, `escalate_role_id` | 널 허용. 이 시간이 지나도 결정이 없으면 이 역할에게도 열림 |

규칙이 없거나 맞는 규칙이 없으면 **지금과 똑같이 동작합니다**(관리자가 결정, 배정된 사용자는 자기 에이전트 것을 봄).

`approval_delegations`: 대리 결재. `from_user_id`, `to_user_id`, `valid_from`, `valid_until`. 기간 안에는 `to_user`가 `from_user`의 역할로 결정할 수 있습니다.

### 3.3 승인에 붙는 열

`human_approvals`와 `change_proposals`에 열을 추가합니다(둘 다 `ADD COLUMN IF NOT EXISTS`).

| 열 | 내용 |
|---|---|
| `routed_rule_id` | 맞춘 규칙. 널이면 규칙 없음 |
| `routed_role_id`, `routed_unit_id` | 규칙에서 복사한 결정 권한자 |
| `escalate_at`, `escalate_role_id` | 올릴 시각과 역할 |
| `decided_by_user_id`, `decided_via` | 결정한 사람과 방식(`self`, `delegate`, `admin`) |

규칙 맞춤은 행을 만들 때 한 번 합니다(`fn_route_decision`). 규칙을 나중에 바꿔도 이미 만들어진 요청은 처음 맞춘 대로 유지합니다.

### 3.4 결정 권한 판정

`fn_may_decide(user, approval_or_proposal)`:
1. 관리자는 항상 가능. (안전 밸브이자 기존 동작 유지)
2. 규칙이 맞춰진 요청이면, 사용자가 `routed_role`을 (지정됐다면 `routed_unit` 안에서) 갖고 있으면 가능. 대리 기간 중인 `from_user`의 역할도 인정.
3. `escalate_at`이 지났으면 `escalate_role`을 가진 사람도 가능.
4. 규칙이 맞춰지지 않은 요청이면 기존 규칙 그대로: 배정된 에이전트의 작업이면 가능(승인), 정책 변경 제안은 대상 에이전트 소유자.
5. 규칙이 맞춰진 요청에서 에이전트 소유자는 **보기만** 가능하고 결정은 못 합니다(7장 질문 3).

`approvals.decide`, `proposals.decide`는 이 판정을 먼저 통과해야 하고, 통과하면 결정한 사람과 방식을 위 열에 기록합니다. 판정 실패는 "이 요청을 결정할 권한이 없습니다"로 답하고 아무것도 바꾸지 않습니다.

### 3.5 승인함

`approvals.list`와 `proposals.list`에 `mine: true`를 추가해 "내가 결정할 것"만 돌려줍니다. 응답 행마다 `routed_role`, `escalate_at`, `can_decide`를 함께 줍니다. 일반 사용자의 가시 범위는 "배정된 에이전트의 것 + 나에게 라우팅된 것"으로 넓어집니다.

### 3.6 기한 올리기

새 워커를 만들지 않습니다. 권한 판정(3.4의 3번)이 `escalate_at`을 직접 비교하므로 별도 갱신이 필요 없습니다. 구현에서는 `fn_watchdog`의 감사 기록(`approvals.escalate`)을 넣지 않았습니다. 올라간 요청은 목록의 `escalate_at`으로 알 수 있습니다.

## 4. 판단 지점과 판단 기록 (1b)

### 4.1 판단 지점 등록

`decision_points`
| 열 | 내용 |
|---|---|
| `point_key`(유일), `version` | 질문 id와 버전. 지시문이나 선택지 설명이 바뀌면 `version`을 올리고 이전 버전 행은 지우지 않음 |
| `qtype` | `choice` / `score` / `noul` |
| `instructions`, `criteria`(jsonb) | Laya 질문의 `instructions`와 `criteria`(선택지 키 → 설명) |
| `state_fields` | 판단 상황 `state`에 넣을 필드 이름 목록. **목록에 없는 필드는 절대 기록하지 않음**(개인정보와 비밀값 보호) |
| `risk_level`, `mode` | 위험 등급과 Laya 모드. 1단계에서 `mode`는 항상 `off` |

1단계 기본 판단 지점은 지금 사람이 결정하는 두 곳입니다.

| `point_key` | 선택지 | 결정이 일어나는 곳 |
|---|---|---|
| `approval_decision` | `approve`, `reject` | `fn_decide_approval` |
| `proposal_decision` | `approve`, `reject` | `fn_decide_proposal` |

나머지 계획서 후보(물리 동작 승인, 팀 창구 배정 등)는 해당 기능이 생기는 단계에서 같은 방식으로 등록합니다. 조직이 새 판단 지점을 추가하는 RPC(`decisions.points.create`)는 이 단계에 포함하되, 결정이 일어나는 코드 위치는 기능과 함께 연결합니다.

### 4.2 판단 상황(`state`) 만들기

`fn_decision_state(point_key, source)` 한 함수가 `state`를 만듭니다. 나중에 Laya에 보낼 입력도 같은 함수를 쓰므로, 학습 때 본 형태와 실제 질문 형태가 어긋나지 않습니다.

`approval_decision`의 기본 `state_fields`:
- 승인 유형, 사유(`payload.reason`), 요청한 에이전트 이름과 그 에이전트의 작업 목표(`goal`)
- 실행 승인이면 동작 이름과 자원 이름(`action`, `resource`)
- `snapshot`, URL, 인자 값, 비밀값이 들어올 수 있는 필드는 **기본 제외**

`proposal_decision`의 기본 `state_fields`: 제안 종류, 대상 이름, 제안 사유(`reason`), 변경 요약(함수는 이름과 설명만, 본문 제외).

`state`는 사람이 읽는 문장 형태의 텍스트(`키: 값` 줄)로 만듭니다. 길이는 4,000자로 자르고, 잘렸으면 표시합니다.

### 4.3 기록

`decision_records` (추가만 하고 수정·삭제하지 않음)
| 열 | 내용 |
|---|---|
| `record_id`, `created_at` | |
| `point_key`, `point_version` | |
| `state` | `fn_decision_state` 결과 |
| `questions` | 판단 시점 질문의 사본: `{"<point_key>": {"type", "instructions", "criteria"}}` |
| `decided_by` | `human` (1단계는 항상 사람) |
| `decider_user_id`, `decided_via` | 결정한 사람과 방식 |
| `answer` | `approve` 또는 `reject` |
| `source_kind`, `source_id` | 원본 승인·제안 행 |
| `split` | `train` / `eval`. `record_id`의 해시로 한 번 정하며 이후 바뀌지 않음. 기본 비율은 train 90% / eval 10% |
| `context` | 팀(그룹), 언어, 시각 |

`decision_labels`
| 열 | 내용 |
|---|---|
| `record_id`, `expected`(jsonb), `tier` | `gold` / `silver` / `bronze` |
| `source`, `labeled_by_user_id`, `labeled_at`, `note` | |

사람이 직접 결정하면 같은 트랜잭션에서 `gold` 정답이 함께 붙습니다. 나중에 사람이 바로잡으면(`decisions.label.add`) 새 `gold` 행이 추가되고, 내보낼 때는 같은 기록의 정답이 여럿이면 가장 최근의 최고 등급 하나만 씁니다. 실제 결과로 확인된 `silver`나 LLM 판정 `bronze`는 이 단계에서 만들지 않습니다(그 경로가 생기는 단계에서 추가).

기록 실패가 결정 자체를 막으면 안 됩니다. 기록은 결정과 같은 트랜잭션에서 하되, 기록 코드가 오류를 내면 경고 감사 기록만 남기고 결정은 그대로 진행합니다.

### 4.4 내보내기

RPC `decisions.export(point_key?, split, tiers, since?, until?)`가 줄 단위 JSONL 텍스트를 돌려줍니다. 한 줄은 공식 형식입니다.

```json
{"state": "승인 유형: 실행 승인\n사유: Execution requires approval\n에이전트: marketing_strategist\n작업 목표: 1분기 광고 집행안 작성\n동작: http_request\n자원: ads.example.com",
 "questions": {"approval_decision": {"type": "choice",
   "instructions": "이 승인 요청을 승인할지 결정하라",
   "criteria": {"approve": "목적이 분명하고 범위 안의 요청", "reject": "근거가 부족하거나 범위를 벗어난 요청"}}},
 "expected": {"approval_decision": "approve"}}
```

- `split`이 `train`이면 학습용, `eval`이면 평가용입니다. 둘은 겹치지 않습니다.
- 기본 등급은 `gold`, `silver`입니다.
- 내보낼 때마다 `decision_exports`에 조건, 건수, 파일 해시, 요청자를 남깁니다.
- 질문 객체와 `expected` 필드는 공식 문서(`docs/finetune.md`)의 JSONL 예시를 그대로 따릅니다.

**공식 도구로 형식 검증.** 구현할 때 저장소의 공식 `laya` 패키지에서 데이터셋 파서(`laya.evals`, torch 불필요)로 내보낸 파일을 읽어 오류가 없는지 시험합니다. 이 검증은 PG 밖 일회성 확인이며 Allgres 코드에는 포함하지 않습니다.

## 5. 화면 (1c)

2단계 전체 재구성 전이므로 기존 화면에 필요한 만큼만 넣습니다.
- **승인(Approvals) 화면:** "내가 결정할 것 / 전체" 전환, 행마다 결정 권한자와 올라가는 시각 표시, 결정할 수 없는 행은 버튼 대신 이유 표시.
- **사용자(Users) 화면:** 사용자별 소속·역할 편집.
- **조직·결재 규칙:** 승인 화면 안의 "결재 규칙" 영역(관리자 전용)에서 부서, 역할, 규칙, 대리 지정.
- **판단 기록:** 판단 지점별 기록 건수(등급별), 내보내기 버튼(학습용/평가용). 관리자 전용.

## 6. 구현 순서와 검증

각 조각은 별도 PR로 나누고, 테스트가 통과하면 `main`에 병합합니다.

| 조각 | 내용 | 완료 기준 |
|---|---|---|
| 1a | 3장 전체: 테이블, 규칙 맞춤, 결정 권한 판정, 대리, 기한 올리기, 승인함 `mine` | `fn_selftest` 신규 케이스(규칙 없음=기존 동작, 규칙 맞춤, 권한 없는 사용자 거부, 대리, 기한 올림, 가시 범위), 기존 380건 유지 |
| 1b | 4장 전체: 판단 지점, 기록, 정답, 내보내기 | 두 결정 경로에서 기록과 정답이 생김, 비허용 필드가 `state`에 안 들어감, 기록 실패가 결정을 막지 않음, 내보낸 줄이 공식 파서로 읽힘, `train`/`eval` 겹침 없음 |
| 1c | 5장 화면 | 브라우저 테스트(규칙 만들기 → 라우팅된 승인을 해당 역할 사용자가 결정 → 기록 내보내기), 화면 스크린샷 |

공통: 새 RPC는 `sql/rpc_catalog.json`을 갱신하고(`scripts/gen_rpc_catalog.py`), `docs/`와 `CHANGELOG.md`를 함께 고칩니다. 알파라 업그레이드 스크립트는 없으므로 새 SQL은 새 설치 기준입니다.

## 7. 정해야 할 것

1. **조직 표현:** 소속과 역할을 `org_memberships` 한 표(사용자, 부서, 역할)로 표현하는 것으로 충분한지. 부서 없이 역할만 쓰는 조직도 가능합니다.
2. **선택지:** 1단계 판단 지점의 선택지를 `approve` / `reject` 둘로 하는 것(위 2장).
3. **라우팅된 요청의 소유자 권한:** 규칙이 맞춰진 요청에서 에이전트 소유자를 보기 전용으로 두는 것이 맞는지. 대안은 소유자도 결정 가능으로 두는 것인데, 결재선을 우회할 수 있어 권장하지 않습니다.
4. **`state`에 넣는 내용:** 작업 목표(`goal`)를 기본 포함해도 되는지. 학습에는 도움이 되지만 사용자가 입력한 글이 그대로 들어갑니다. 제외하면 기록은 안전하지만 정보가 줄어듭니다.
5. **`train` / `eval` 비율:** 기본 90/10.
