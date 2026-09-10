import { randomUUID } from "node:crypto";
import { createConnection } from "node:net";

type Context = {
	mode: string;
	sessionManager: { getSessionId(): string };
};

type API = {
	on(name: string, handler: (event: any, context: Context) => void | Promise<void>): void;
};

type Report = Record<string, unknown> & { event: string };

const env = process.env;
const enabled = Boolean(
	env.AGENTS_APP &&
		env.AGENTS_CONTROL_SOCK &&
		env.AGENTS_SESSION_ID &&
		env.AGENTS_PANE_ID &&
		env.AGENTS_PANE_GENERATION,
);
const runId = randomUUID();
let sequence = 0;
let delivery = Promise.resolve();

function send(report: Report, context: Context): Promise<void> {
	if (!enabled || context.mode !== "tui") return Promise.resolve();

	const body = JSON.stringify({
		cmd: "harness-event",
		version: 1,
		session: env.AGENTS_SESSION_ID,
		pane: env.AGENTS_PANE_ID,
		generation: env.AGENTS_PANE_GENERATION,
		agent: "omp",
		run_id: runId,
		pid: process.pid,
		sequence: ++sequence,
		agent_session_id: context.sessionManager.getSessionId(),
		...report,
	});

	delivery = delivery.then(
		() => deliver(body),
		() => deliver(body),
	);
	return delivery;
}

function deliver(body: string): Promise<void> {
	return new Promise(resolve => {
		const socket = createConnection(env.AGENTS_CONTROL_SOCK!);
		let finished = false;
		let reply = "";
		const finish = () => {
			if (finished) return;
			finished = true;
			socket.destroy();
			if (reply && !reply.includes('"ok":true')) {
				console.error(`Agents refused a harness event: ${reply.trim()}`);
			}
			resolve();
		};
		socket.setTimeout(2000, finish);
		socket.once("error", finish);
		socket.once("end", finish);
		socket.on("data", chunk => {
			reply += chunk.toString();
			if (reply.includes("\n")) finish();
		});
		socket.once("connect", () => socket.write(`${body}\n`));
	});
}

export default function agentsExtension(pi: API): void {
	pi.on("session_start", (event, ctx) => send({ event: event.type }, ctx));
	pi.on("session_switch", (event, ctx) => send({ event: event.type, source: event.reason }, ctx));
	pi.on("agent_start", (event, ctx) => send({ event: event.type }, ctx));
	pi.on("agent_end", (event, ctx) => {
		const lastAssistant = [...event.messages].reverse().find(message => message.role === "assistant");
		const stopReason = lastAssistant?.stopReason;
		return send({
			event: event.type,
			will_continue: event.willContinue === true,
			outcome: stopReason === "error" ? "failed" : stopReason === "aborted" ? "interrupted" : "completed",
			is_interrupt: stopReason === "aborted",
		}, ctx);
	});
	pi.on("auto_retry_start", (event, ctx) =>
		send({ event: event.type, source: `attempt ${event.attempt}`, message: event.errorMessage }, ctx),
	);
	pi.on("auto_retry_end", (event, ctx) =>
		send({
			event: event.type,
			source: `attempt ${event.attempt}`,
			...(event.success ? {} : { outcome: "failed", message: event.finalError }),
		}, ctx),
	);
	pi.on("tool_approval_requested", (event, ctx) =>
		send(
			{
				event: event.type,
				request_id: event.toolCallId,
				tool_name: event.toolName,
				message: event.reason,
			},
			ctx,
		),
	);
	pi.on("tool_approval_resolved", (event, ctx) =>
		send(
			{
				event: event.type,
				request_id: event.toolCallId,
				tool_name: event.toolName,
				source: event.approved ? "approved" : "denied",
				message: event.reason,
			},
			ctx,
		),
	);
	pi.on("tool_execution_start", (event, ctx) => {
		if (event.toolName !== "ask") return;
		return send({ event: event.type, request_id: event.toolCallId, tool_name: event.toolName }, ctx);
	});
	pi.on("tool_execution_end", (event, ctx) => {
		if (event.toolName !== "ask") return;
		return send({
			event: event.type,
			request_id: event.toolCallId,
			tool_name: event.toolName,
			outcome: event.isError ? "failed" : "completed",
		}, ctx);
	});
	pi.on("session_shutdown", (event, ctx) => send({ event: event.type }, ctx));
}
