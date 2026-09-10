#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/agents-hook-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

sock="$tmp/control.sock"
capture="$tmp/request.json"

ruby -rsocket -rtimeout -e '
  server = UNIXServer.new(ARGV[0])
  pid = nil
  begin
    Timeout.timeout(5) do
      input = %q({"hook_event_name":"PermissionRequest","session_id":"conversation-1","tool_use_id":"tool-1","tool_name":"Bash","message":"Approve?"})
      reader, writer = IO.pipe
      environment = {
        "PATH" => ARGV[3],
        "AGENTS_APP" => "1",
        "AGENTS_CONTROL_SOCK" => ARGV[0],
        "AGENTS_SESSION_ID" => "row-1",
        "AGENTS_PANE_ID" => "e9e280ce-7f7e-4db7-8dd0-d77e8f535e27",
        "AGENTS_PANE_GENERATION" => "7c252663-d6ed-4862-9796-72b6041907c1"
      }
      pid = Process.spawn(environment, "/bin/bash", ARGV[2], in: reader)
      reader.close
      writer.write(input)
      writer.close
      client = server.accept
      File.write(ARGV[1], client.gets)
      client.write("{\"ok\":true}\n")
      client.close
      _, status = Process.wait2(pid)
      pid = nil
      exit status.exitstatus unless status.success?
    end
  ensure
    server.close rescue nil
    if pid
      Process.kill("TERM", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end
' "$sock" "$capture" "$root/hooks/agents-status.sh" \
  "$root/hooks/test-support:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

jq -e '
  . as $report |
  .cmd == "harness-event" and
  .version == 1 and
  .agent == "claude" and
  (.pid | type) == "number" and
  (.run_id | startswith(($report.pid | tostring) + ":")) and
  .event == "PermissionRequest" and
  .agent_session_id == "conversation-1" and
  .request_id == "tool-1" and
  .tool_name == "Bash" and
  .message == "Approve?"
' "$capture" >/dev/null

printf 'agents-status lifecycle report: ok\n'
