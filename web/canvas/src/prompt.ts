// A new agent's stored system prompt starts with the reply protocol the
// runtime relies on (sql/control_plane.sql, ensure_policy): reply with one
// JSON object, and the shape of each action. People describe the agent's
// job; Canvas keeps the protocol in front of it instead of letting a plain
// sentence replace it. Keep PROTOCOL identical to ensure_policy's text.
export const PROTOCOL = "You are an agent whose next action is decided only as JSON.\nReply with a single JSON object, no markdown, no extra keys:\n{\"action\":\"final_answer\",\"answer\":\"...\"}\n{\"action\":\"execute_sql\",\"sql\":\"SELECT ...\"}\n{\"action\":\"call_function\",\"function\":\"...\",\"args\":{}}\n{\"action\":\"delegate\",\"agent_name\":\"...\",\"input\":{},\"wait\":false}\n{\"action\":\"await_children\"}\n{\"action\":\"await_human\",\"reason\":\"...\"}\nSQL must be a single SELECT or WITH against schema-qualified views you were given.\ndelegate's \"wait\" defaults to false (hand off and your turn ends); set it true to keep going instead of\nfinishing, so you can delegate to more agents or later call await_children to pause until every agent you\ndelegated to has finished, with what each one did visible on your next turn.\n";
const JOB = '\n# Your job\n';

/** The part a person writes, or null when the prompt is not protocol + job (written by hand, shown whole). */
export function jobOf(prompt: string | null | undefined): string | null {
  const p = prompt || '';
  if (!p.startsWith(PROTOCOL.trimEnd())) return null;
  const i = p.indexOf(JOB);
  return i < 0 ? p.slice(PROTOCOL.trimEnd().length).trim() : p.slice(i + JOB.length).trim();
}

export function withJob(job: string): string {
  return PROTOCOL + JOB + job.trim();
}
