// rex-reopen-tab for pi: tells the tracker (tracker.lua) which session this
// pi process holds. pi does not keep its session file open, so the tracker
// cannot find the session from outside the process.
// install.sh copies this file to <pi agent dir>/extensions/rex-reopen-tab.ts.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"
import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const DIR = join(homedir(), ".local/state/rex-reopen-tab/pi")
const FILE = join(DIR, `${process.pid}.json`)

// A reload imports this file again; remove the file on exit only once.
// A signal (a closed tab) skips this; tracker.lua removes those files.
const flag = globalThis as { rexReopenTabExit?: boolean }
if (!flag.rexReopenTabExit) {
  flag.rexReopenTabExit = true
  process.once("exit", () => {
    try {
      rmSync(FILE, { force: true })
    } catch {}
  })
}

export default function (pi: ExtensionAPI) {
  // Runs at startup and after /new, /resume, /fork, and /reload.
  pi.on("session_start", async (_event, ctx) => {
    try {
      mkdirSync(DIR, { recursive: true })
      const data = {
        pid: process.pid,
        sessionId: ctx.sessionManager.getSessionId(),
        // pi writes this file only after the first message.
        sessionFile: ctx.sessionManager.getSessionFile() ?? null,
        cwd: ctx.cwd,
        // pi sets its process title, so ps shows only "pi" without the flags.
        args: process.argv.slice(2),
      }
      writeFileSync(`${FILE}.tmp`, JSON.stringify(data))
      renameSync(`${FILE}.tmp`, FILE)
    } catch {}
  })
}
