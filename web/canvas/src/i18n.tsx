import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react';

// Canvas speaks English and Korean. The English sentence is the key, so a
// string without a Korean entry still reads correctly, just in English.
// {name}-style placeholders are filled from the second argument.
export type Lang = 'en' | 'ko';

const KO: Record<string, string> = {
  // Shell
  Canvas: '캔버스',
  '← Dashboard': '← 대시보드',
  Organization: '조직',
  Flow: '흐름',
  Undo: '실행 취소',
  'Zoom out': '축소',
  'Zoom in': '확대',
  'Fit to screen': '화면에 맞추기',
  More: '더 보기',
  'Show system agents': '시스템 에이전트 보기',
  'Show inactive agents': '비활성 에이전트 보기',
  'Tidy up layout': '자동 정렬',
  Refresh: '새로 고침',
  Refreshed: '새로 고쳤습니다',
  'How to read the board': '보드 읽는 법',
  Help: '도움말',
  Language: '언어',
  'Loading agents…': '에이전트를 불러오는 중…',
  'Open dashboard': '대시보드 열기',
  'Dashboard token required': '대시보드 토큰이 필요합니다',
  'Open the dashboard in this tab, enter the dashboard token, then come back to Canvas.': '이 탭에서 대시보드를 열고 토큰을 입력한 뒤 캔버스로 돌아오세요.',
  'Sign in first': '먼저 로그인하세요',
  'Sign in on the dashboard in this tab, then open Canvas from the menu.': '이 탭에서 대시보드에 로그인한 뒤 메뉴에서 캔버스를 여세요.',
  'Admins only': '관리자 전용',
  'Canvas shows and changes every agent and its grants, so it needs an admin account.': '캔버스는 모든 에이전트와 권한을 보고 바꾸므로 관리자 계정이 필요합니다.',
  'Canvas could not load': '캔버스를 불러오지 못했습니다',
  'Enter the dashboard token this server was started with.': '이 서버를 시작할 때 정한 대시보드 토큰을 입력하세요.',
  'Sign in to Canvas': '캔버스에 로그인',
  'Use your admin account, the same one as the dashboard.': '대시보드와 같은 관리자 계정을 쓰세요.',
  'That username and password did not match.': '아이디 또는 비밀번호가 맞지 않습니다.',
  'Dashboard token': '대시보드 토큰',
  Username: '아이디',
  Password: '비밀번호',
  Continue: '계속',
  'Sign in': '로그인',

  // Add menu
  Add: '추가',
  'Add to the board': '보드에 추가',
  'New agent': '새 에이전트',
  'Someone who does one kind of work': '한 가지 일을 맡는 구성원',
  'New team': '새 팀',
  'A box to keep agents together': '에이전트를 묶어 두는 상자',
  'Saved teams': '저장한 팀',
  '{n} agents': '에이전트 {n}명',
  'Example team': '예시 팀',
  'A lead with two members, ready to edit': '팀장 1명과 팀원 2명, 바로 고쳐 쓸 수 있습니다',
  'Delete saved team {name}': '저장한 팀 {name} 삭제',
  'Delete “{name}”?': '“{name}” 구성을 삭제할까요?',
  'Only the saved team is removed; agents created from it stay.': '저장해 둔 구성만 지워집니다. 이미 만든 에이전트는 그대로입니다.',
  Delete: '삭제',
  'Drag onto the board, or click': '보드로 끌어 놓거나 클릭하세요',

  // Empty state
  'Build your first team': '첫 팀을 만들어 보세요',
  'Add agents, then drop one onto another to decide who hands work to whom.': '에이전트를 추가한 뒤, 한 카드를 다른 카드 위에 놓아 누가 누구에게 일을 넘길지 정하세요.',
  'Add an agent': '에이전트 추가',
  'Start from an example': '예시로 시작하기',

  // Board hints and actions
  'Drop to put {child} under {parent}': '놓으면 {parent} 아래로 들어갑니다',
  '{parent} will be able to hand work to {child}.': '{parent} 에이전트가 {child} 에이전트에게 일을 넘길 수 있게 됩니다.',
  'Drop on an agent: {name} will be able to hand work to it. Release anywhere else to cancel.': '일을 받을 에이전트 위에 놓으세요. {name} 에이전트가 그 에이전트에게 일을 넘기게 됩니다. 빈 곳에 놓으면 취소됩니다.',
  'Drop here': '여기에 놓기',
  'Already hands work here': '이미 일을 넘기는 중',
  'From here': '여기서 시작',
  '{child} now works under {parent}': '{child} 에이전트를 {parent} 아래로 옮겼습니다',
  '{from} can now hand work to {to}': '이제 {from} → {to}로 일을 넘길 수 있습니다',
  '{from} already hands work to {to}': '이미 {from} → {to}로 일을 넘기고 있습니다',
  '{from} no longer hands work to {to}': '{from} → {to} 연결을 끊었습니다',
  'System agents run the platform itself and do not take work from the board.': '시스템 에이전트는 플랫폼 자체를 운영하므로 보드에서 일을 받지 않습니다.',
  'System agents are changed only from SQL.': '시스템 에이전트는 SQL에서만 바꿀 수 있습니다.',
  'Stop handing work?': '일 넘기기를 끊을까요?',
  '{from} will no longer be able to hand work to {to}.': '{from} 에이전트는 더 이상 {to} 에이전트에게 일을 넘길 수 없습니다.',
  'Disconnect': '연결 끊기',
  Moved: '옮겼습니다',
  'Moved into {team}': '“{team}” 팀에 넣었습니다',
  'Moved out of the team': '팀에서 뺐습니다',
  Resized: '크기를 바꿨습니다',
  'Tidied up': '정렬했습니다',
  'Undid: {what}': '되돌렸습니다: {what}',
  'Could not undo {what}: {why}': '되돌리지 못했습니다 ({what}): {why}',
  'Make a team': '팀으로 묶기',
  '{n} selected': '{n}개 선택됨',
  'Clear selection': '선택 해제',
  'Getting started': '시작하기',
  'Choose its model': '모델 고르기',
  'Put one agent under another': '한 에이전트를 다른 에이전트 아래에 두기',
  'Give the top agent a task': '맨 위 에이전트에게 작업 주기',
  'Drag one card onto another to put it under that agent.': '카드를 다른 카드 위로 끌어 놓으면 그 아래로 들어갑니다.',
  'New agent here': '여기에 새 에이전트',
  'New team here': '여기에 새 팀',
  'Open details': '자세히 보기',
  'Add an agent here': '이 팀에 에이전트 추가',
  'Put under…': '다른 에이전트 아래로…',
  'Put {name} under…': '{name} 에이전트를 어디 아래로 둘까요?',
  'The agent you choose will be able to hand {name} work.': '고른 에이전트가 {name} 에이전트에게 일을 넘길 수 있게 됩니다.',
  Under: '위 에이전트',
  'Put under': '아래로 두기',
  'Take out of the team': '팀에서 빼기',
  'Right-click a card or the board for more.': '카드나 빈 곳을 오른쪽 클릭하면 더 많은 동작이 있습니다.',

  // Lines (labels and legend)
  'hands work to': '일을 넘김',
  inherits: '상속',
  'handed work': '넘긴 일',
  'Hands work to': '일을 넘김',
  'A can give B a task. Drag one card onto another to set this up; click the line to remove it.': 'A가 B에게 작업을 줄 수 있습니다. 카드를 다른 카드 위에 놓아 만들고, 선을 눌러 끊습니다.',
  Inherits: '상속',
  "The lower system agent gets the upper one's abilities and base instructions.": '아래 시스템 에이전트가 위 에이전트의 능력과 기본 지시를 물려받습니다.',
  Team: '팀',
  'A box that keeps agents together. It grants nothing by itself.': '에이전트를 묶어 두는 상자입니다. 그 자체로 권한을 주지는 않습니다.',
  'Handed work': '넘긴 일',
  'A really gave B a task in recent work; ×N is how often.': '최근 작업에서 A가 실제로 B에게 일을 넘겼습니다. ×N은 횟수입니다.',
  'Lines that were not used fade out.': '쓰이지 않은 선은 흐리게 보입니다.',
  'Got it': '알겠어요',

  // Card
  'System agent': '시스템 에이전트',
  Ready: '준비됨',
  'Needs a model': '모델 필요',
  Inactive: '비활성',
  '{n} abilities': '능력 {n}개',
  '1 ability': '능력 1개',
  '+{n} inherited': '+{n}개 상속',
  'leads {n}': '{n}명 지휘',
  'No abilities yet': '아직 능력 없음',
  Working: '작업 중',
  'Waiting to start': '시작 대기',
  'Needs your approval': '승인 필요',
  'Waiting for others': '다른 에이전트 기다리는 중',
  Cancelled: '취소됨',
  Done: '완료',
  Failed: '실패',
  'Drag onto another agent to hand it work': '다른 에이전트에게 끌어 놓으면 일을 넘길 수 있습니다',
  'System agents': '시스템 에이전트',

  // Panel
  'Close details': '닫기',
  Overview: '개요',
  Chat: '대화',
  Activity: '활동',
  'This agent cannot work yet.': '이 에이전트는 아직 일할 수 없습니다.',
  'Choose a model below and turn it on.': '아래에서 모델을 고르고 켜 주세요.',
  'Turned off: it takes no work.': '꺼져 있어 일을 받지 않습니다.',
  On: '켜짐',
  Off: '꺼짐',
  'Turn on': '켜기',
  'Turn off': '끄기',
  'Choose a model before turning this agent on.': '켜기 전에 모델을 먼저 고르세요.',
  '{name} is on': '{name} 에이전트를 켰습니다',
  '{name} is off': '{name} 에이전트를 껐습니다',
  'What it does': '하는 일',
  'Written by hand, including how it replies. Change it with care.': '응답 방식까지 직접 작성된 지시입니다. 바꿀 때 주의하세요.',
  'Describe its job in plain words, the way you would brief a colleague.': '동료에게 일을 맡기듯 쉬운 말로 적으세요.',
  Model: '모델',
  'No model': '모델 없음',
  'Other model…': '다른 모델…',
  'Model name': '모델 이름',
  'No AI provider is set up yet. Add one under Settings on the dashboard.': '아직 AI 제공자가 없습니다. 대시보드의 설정에서 추가하세요.',
  'Model set to {model}': '모델: {model}',
  'Takes work from': '일을 받는 곳',
  'Nobody yet': '아직 없음',
  'Add who hands it work': '일을 주는 에이전트 추가',
  'Add who it hands work to': '일을 넘길 에이전트 추가',
  'Choose an agent…': '에이전트 선택…',
  'In team': '소속 팀',
  'No team': '팀 없음',
  'Moved to {team}': '“{team}” 팀에 넣었습니다',
  'Left the team': '팀에서 나왔습니다',
  Abilities: '능력',
  'Add an ability': '능력 추가',
  'Choose an ability…': '능력 선택…',
  'Website…': '웹사이트…',
  'Bind via a procedure': '절차에 묶어서 사용',
  'Remove {name}': '{name} 제거',
  'Inherited from {from}': '{from}에게서 상속',
  'It answers only from its instructions and memory.': '지시와 기억만으로 답합니다.',
  '{name} can now {what}': '{name} 에이전트에 능력 추가: {what}',
  'Removed {what}': '능력 제거: {what}',
  'Also give it to the agents above?': '위 에이전트에게도 함께 줄까요?',
  'An agent can only use what every agent that hands it work can use too. These agents hand work to {name} and lack {what}:': '에이전트는 자신에게 일을 주는 에이전트가 모두 가진 능력만 쓸 수 있습니다. 아래 에이전트는 {name} 에이전트에게 일을 주지만, “{what}” 능력이 없습니다:',
  'Give to all {n}': '{n}명 모두에게 주기',
  'Cannot add this here': '여기서는 추가할 수 없습니다',
  '{names} hand work to {name} and lack {what}, but system agents are changed only from SQL.': '{names} 에이전트가 {name} 에이전트에게 일을 주지만 “{what}” 능력이 없습니다. 시스템 에이전트는 SQL에서만 바꿀 수 있습니다.',
  'Website address': '웹사이트 주소',
  'Let {name} reach a website': '{name} 에이전트가 접속할 웹사이트',
  Allow: '허용',
  Advanced: '고급',
  Creativity: '창의성',
  'Model default': '모델 기본값',
  'Max steps per task': '작업당 최대 단계',
  'Retries': '재시도 횟수',
  'Tasks at once': '동시 작업 수',
  'Time limit per turn (seconds)': '턴당 시간 제한(초)',
  'No limit': '제한 없음',
  'How deep it may delegate': '위임 깊이',
  'Tasks per session': '세션당 작업 수',
  'Let a task choose its own model': '작업마다 모델 고르기 허용',
  'When you give it a task under Activity, you may pick a different model for that one task.': '활동 탭에서 작업을 줄 때 그 작업에만 다른 모델을 고를 수 있습니다.',
  Save: '저장',
  Reset: '되돌리기',
  'Saved {name}': '“{name}” 저장됨',
  'Autonomy': '자율성',
  'Ask an admin first': '관리자 승인 후 실행',
  'Decide, escalate when unsure': '스스로 결정, 애매하면 확인 요청',
  'Act on its own': '스스로 실행',
  "System agents' instructions and abilities are changed only from SQL; autonomy is the one setting here.": '시스템 에이전트의 지시와 능력은 SQL에서만 바뀝니다. 여기서는 자율성만 정할 수 있습니다.',
  'Inherits from': '상속받는 곳',
  'Instructions': '지시',
  'Goes straight to {name}: the same conversation as the dashboard’s Chat page.': '{name}에게 바로 전달됩니다. 대시보드 대화 페이지와 같은 대화입니다.',
  'Turn this agent on to talk to it.': '대화하려면 이 에이전트를 켜 주세요.',
  'Give it a task': '작업 주기',
  'What should {name} do?': '{name}에게 무엇을 시킬까요?',
  'Model for this task (optional)': '이 작업에 쓸 모델 (선택)',
  "Agent's model": '에이전트 기본 모델',
  'Start': '시작',
  'Task started on {name}': '{name}에게 작업을 맡겼습니다',
  'Recent work': '최근 작업',
  'Nothing yet.': '아직 없습니다.',
  'Loading…': '불러오는 중…',
  'Team name': '팀 이름',
  'Kind': '종류',
  Division: '본부',
  Project: '프로젝트',
  'Inside': '상위 팀',
  'Top level': '최상위',
  Rename: '이름 바꾸기',
  'Renamed to {name}': '이름 변경: {name}',
  Members: '구성원',
  'Drag agents into the box, or add one with “Add”.': '에이전트를 상자 안으로 끌어 오거나 “추가”로 넣으세요.',
  'Take {name} out of {team}': '{team} 팀에서 {name} 빼기',
  '{name} left {team}': '{team} 팀에서 {name} 에이전트를 뺐습니다',
  'Save as a reusable team': '재사용할 팀으로 저장',
  'Saves the agents in this box, their instructions and abilities, and who hands work to whom. Add it again later from “Add”.': '이 상자의 에이전트, 지시, 능력, 일을 넘기는 관계를 저장합니다. 나중에 “추가”에서 다시 넣을 수 있습니다.',
  Name: '이름',
  'Merge into another team…': '다른 팀과 합치기…',
  'Merge {name} into…': '“{name}” 팀을 어느 팀과 합칠까요?',
  'Its agents and teams move into the other one and this box goes away. Who hands work to whom stays as it is.': '구성원과 하위 팀이 다른 팀으로 옮겨지고 이 상자는 사라집니다. 일을 넘기는 관계는 그대로입니다.',
  Into: '합칠 팀',
  Merge: '합치기',
  'Merged {name}': '“{name}” 팀을 합쳤습니다',
  'Delete team': '팀 삭제',
  'Delete {name}?': '“{name}” 팀을 삭제할까요?',
  'The box goes away; its agents stay on the board.': '상자만 사라지고 에이전트는 보드에 남습니다.',
  'Deleted {name}': '“{name}” 삭제됨',

  // Dialogs
  Cancel: '취소',
  Create: '만들기',
  'New agent name': '새 에이전트 이름',
  'e.g. researcher': '예: researcher',
  'You can add a model later; until then it is saved turned off.': '모델은 나중에 정해도 됩니다. 그 전까지는 꺼진 상태로 저장됩니다.',
  'Created {name}': '“{name}” 만들었습니다',
  'Created {name}, turned off until it has a model': '“{name}” 만들었습니다. 모델을 정하면 켤 수 있습니다',
  'e.g. Research team': '예: 리서치팀',
  'Placed {name}': '“{name}” 팀을 놓았습니다',
  'Created an example team. Rename the agents and give them a model to start.': '예시 팀을 만들었습니다. 이름을 바꾸고 모델을 정하면 바로 쓸 수 있습니다.',

  'Plans the work, splits it into tasks, and hands them to the researcher and the writer.': '일을 계획하고 작업으로 나눈 뒤 researcher와 writer에게 넘깁니다.',
  'Finds and checks sources, then reports what it found.': '자료를 찾아 확인하고, 찾은 내용을 보고합니다.',
  'Turns the findings into a clear, short write-up.': '조사 결과를 짧고 분명한 글로 정리합니다.',

  // Flow
  'How work actually moved between agents': '에이전트 사이에서 일이 실제로 오간 흐름',
  'Who handed work to whom (last 500 tasks)': '누가 누구에게 일을 넘겼나 (최근 작업 500개)',
  'Nobody has handed work to anyone yet. Drop one agent onto another, then give the upper one a task.': '아직 넘긴 일이 없습니다. 에이전트를 다른 에이전트 위에 놓은 뒤 위쪽 에이전트에게 작업을 주세요.',
  '{n} failed': '{n}건 실패',
  Sessions: '세션',
  'Back to all work': '전체 흐름으로',
  '{agent} · {n} tasks · {state}': '{agent} · 작업 {n}개 · {state}',
  'in progress': '진행 중',
  'Replay': '다시 보기',
  'Previous step': '이전 단계',
  'Next step': '다음 단계',
  Live: '현재',
  Answer: '답변',
  'Started: {text}': '시작: {text}',
  'Finished in {n} steps': '{n}단계 만에 완료',
  'Failed: {text}': '실패: {text}',
  'just now': '방금',
  '{n} min ago': '{n}분 전',
  '{n} h ago': '{n}시간 전',

  // Chat
  'Message {name}': '{name}에게 메시지',
  Send: '보내기',
  'No messages yet.': '아직 메시지가 없습니다.',
  '{name} is working…': '{name} 작업 중…',
  'Chat is tied to an account: sign in on the dashboard in this tab to talk to agents.': '대화는 계정에 연결됩니다. 이 탭에서 대시보드에 로그인하세요.',
  'Ask General': 'General에게 묻기',
  Hide: '숨기기',

  // Abilities (friendly names)
  'Read web pages': '웹 페이지 읽기',
  'Call web services': '웹 서비스 호출',
  'Reach {host}': '{host} 접속',
  'Read: {what}': '읽기: {what}',
  'Run: {what}': '실행: {what}',
  'Use: {what}': '사용: {what}',
  Web: '웹',
  Data: '데이터',
  Routines: '루틴',
};

const Ctx = createContext<{ lang: Lang; setLang: (l: Lang) => void }>({ lang: 'en', setLang: () => {} });

function initial(): Lang {
  try {
    const v = localStorage.getItem('allgres_canvas_lang');
    if (v === 'en' || v === 'ko') return v;
  } catch {
    /* storage blocked: fall back to the browser language */
  }
  return navigator.language?.toLowerCase().startsWith('ko') ? 'ko' : 'en';
}

export function LangProvider({ children }: { children: ReactNode }) {
  const [lang, set] = useState<Lang>(initial);
  const setLang = useCallback((l: Lang) => {
    set(l);
    try {
      localStorage.setItem('allgres_canvas_lang', l);
    } catch {
      /* storage blocked: lasts until reload */
    }
    document.documentElement.lang = l;
  }, []);
  const value = useMemo(() => ({ lang, setLang }), [lang, setLang]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export type T = (s: string, vars?: Record<string, string | number>) => string;

export function translate(lang: Lang, s: string, vars?: Record<string, string | number>) {
  let out = lang === 'ko' ? KO[s] ?? s : s;
  if (vars) for (const [k, v] of Object.entries(vars)) out = out.split(`{${k}}`).join(String(v));
  return out;
}

export function useT(): T {
  const { lang } = useContext(Ctx);
  return useCallback((s, vars) => translate(lang, s, vars), [lang]);
}

export const useLang = () => useContext(Ctx);
