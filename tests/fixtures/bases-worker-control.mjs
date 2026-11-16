import readline from "node:readline";

function respond(request, result) {
  process.stdout.write(`${JSON.stringify({ id: request.id, ok: true, result })}\n`);
}

const input = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

input.on("line", (line) => {
  if (!line.trim()) return;
  const request = JSON.parse(line);
  const params = request.params ?? {};
  if (params.fixture === "hang") {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
    return;
  }
  if (params.fixture === "crash") {
    process.stderr.write("controlled fixture crash");
    process.exit(7);
  }
  const result = {
    state: "current",
    matches: [],
    diagnostics: [],
    fixture: params.fixture ?? "ready",
    pid: process.pid,
  };
  if (params.fixture === "delay") {
    setTimeout(() => respond(request, result), params.delay ?? 50);
    return;
  }
  respond(request, result);
});
