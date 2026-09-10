import { afterAll, beforeAll, expect, test } from "bun:test";
import { createServer, type Server } from "node:net";

const socketPath = `/tmp/agents-omp-test-${process.pid}.sock`;
const reports: Array<Record<string, unknown>> = [];
let server: Server;
let handlers: Map<string, (event: any, context: any) => void | Promise<void>>;

beforeAll(async () => {
	Object.assign(process.env, {
		AGENTS_APP: "1",
		AGENTS_CONTROL_SOCK: socketPath,
		AGENTS_SESSION_ID: "row-1",
		AGENTS_PANE_ID: "e9e280ce-7f7e-4db7-8dd0-d77e8f535e27",
		AGENTS_PANE_GENERATION: "7c252663-d6ed-4862-9796-72b6041907c1",
	});

	server = createServer(socket => {
		let request = "";
		socket.on("data", chunk => {
			request += chunk.toString();
			if (!request.includes("\n")) return;
			reports.push(JSON.parse(request));
			socket.end('{"ok":true}\n');
		});
	});
	await new Promise<void>((resolve, reject) => {
		server.once("error", reject);
		server.listen(socketPath, resolve);
	});

	handlers = new Map();
	const extension = (await import("./agents-omp.ts")).default;
	extension({ on: (name, handler) => handlers.set(name, handler) });
});

afterAll(async () => {
	await new Promise<void>(resolve => server.close(() => resolve()));
});

test("delivers lifecycle events in order and ignores non-TUI contexts", async () => {
	const tui = {
		mode: "tui",
		sessionManager: { getSessionId: () => "conversation-1" },
	};
	const rpc = { ...tui, mode: "rpc" };

	await handlers.get("session_start")!({ type: "session_start" }, rpc);
	await handlers.get("agent_start")!({ type: "agent_start" }, tui);
	await handlers.get("tool_approval_requested")!(
		{ type: "tool_approval_requested", toolCallId: "call-1", toolName: "bash", reason: "write access" },
		tui,
	);
	await handlers.get("tool_approval_resolved")!(
		{ type: "tool_approval_resolved", toolCallId: "call-1", toolName: "bash", approved: true },
		tui,
	);

	expect(reports.map(report => report.event)).toEqual([
		"agent_start",
		"tool_approval_requested",
		"tool_approval_resolved",
	]);
	expect(reports.map(report => report.sequence)).toEqual([1, 2, 3]);
	expect(new Set(reports.map(report => report.run_id)).size).toBe(1);
	expect(reports[1].request_id).toBe("call-1");
	expect(reports[2].source).toBe("approved");
});
