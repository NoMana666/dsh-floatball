import { spawn, execFile } from 'node:child_process'
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import os from 'node:os'

const here = dirname(fileURLToPath(import.meta.url))

/** Runtime data lives in %LOCALAPPDATA%\dsh-floatball (settings, logs, heartbeat). */
function settingsDir() {
  const base = process.env.LOCALAPPDATA || join(os.homedir(), 'AppData', 'Local')
  return join(base, 'dsh-floatball')
}

function readSettings(dir) {
  try {
    return JSON.parse(readFileSync(join(dir, 'settings.json'), 'utf8'))
  } catch {
    return {}
  }
}

function logLine(msg) {
  try {
    const line = '[' + new Date().toISOString() + '] ' + msg + '\n'
    appendFileSync(join(settingsDir(), 'plugin.log'), line)
  } catch {}
}

/** Kill balls left over from an older version (or from manual launchers), so two balls never stack up. */
function killStaleBalls() {
  return new Promise((resolve) => {
    const script = "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*ball.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
    execFile('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script], { windowsHide: true, timeout: 8000 }, () => resolve())
  })
}

export function apply(ctx, config = {}) {
  logLine('apply pid=' + process.pid)
  const dir = settingsDir()
  try { mkdirSync(dir, { recursive: true }) } catch {}

  const settings = readSettings(dir)
  if (settings.autoStart === false || config.autoStart === false) {
    logLine('autostart disabled, skip')
    return undefined
  }

  const heartbeatFile = join(dir, 'heartbeat.json')
  let child = null
  let stopped = false
  let heartbeat = null
  let attention = 0

  const beat = () => {
    try {
      writeFileSync(heartbeatFile, JSON.stringify({
        pid: process.pid,
        ts: Date.now(),
        attention: attention > 0,
      }))
    } catch {}
  }

  // Heartbeat: refreshed every 3s while DSH lives. The ball exits on its own
  // when the heartbeat goes stale for 20s, so it never outlives the host.
  beat()
  heartbeat = setInterval(beat, 3000)
  if (heartbeat.unref) heartbeat.unref()

  const start = async () => {
    await killStaleBalls()
    if (stopped) return
    const args = [
      '-Sta', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
      '-File', join(here, 'ball.ps1'),
      '-ParentPid', String(process.pid),
      '-SettingsDir', dir,
      '-HeartbeatFile', heartbeatFile,
    ]
    try {
      child = spawn('powershell.exe', args, { stdio: 'ignore', windowsHide: true })
      logLine('spawn child pid=' + child.pid + ' parent=' + process.pid)
      child.on('exit', (code) => { logLine('child exit ' + code); child = null })
      child.on('error', (err) => { logLine('child error ' + err.message); child = null })
    } catch (err) {
      logLine('spawn failed ' + err.message)
      child = null
    }
  }

  start().catch((err) => logLine('start failed ' + err.message))

  // Attention: light the ball up while DSH is waiting for an approval or an answer.
  const disposers = []
  const enterAttention = (kind) => {
    attention += 1
    logLine('attention on ' + kind + ' n=' + attention)
    beat()
  }
  const leaveAttention = (kind) => {
    attention = Math.max(0, attention - 1)
    logLine('attention off ' + kind + ' n=' + attention)
    beat()
  }
  const wrap = (kind) => async (...args) => {
    const next = args[args.length - 1]
    enterAttention(kind)
    try {
      return await next()
    } finally {
      leaveAttention(kind)
    }
  }
  try {
    disposers.push(ctx.on('approval/request', wrap('approval')))
  } catch (err) {
    logLine('hook approval failed ' + err.message)
  }
  try {
    disposers.push(ctx.on('user-questions/request', wrap('question')))
  } catch (err) {
    logLine('hook questions failed ' + err.message)
  }

  // Those events are agent-scoped: a plugin listening on the root ctx often
  // never sees them. Wrap the service methods instead, so every scope passes through.
  const patchService = (name, method, kind) => {
    try {
      const svc = ctx.get(name)
      if (!svc || typeof svc[method] !== 'function') {
        logLine('patch skip ' + name + '.' + method)
        return
      }
      if (svc.__dshFloatballPatched) return
      const orig = svc[method].bind(svc)
      svc[method] = async (...args) => {
        enterAttention(kind)
        try {
          return await orig(...args)
        } finally {
          leaveAttention(kind)
        }
      }
      svc.__dshFloatballPatched = true
      logLine('patched ' + name + '.' + method)
    } catch (err) {
      logLine('patch ' + name + ' failed ' + err.message)
    }
  }
  patchService('approval', 'request', 'approval')
  patchService('userQuestions', 'ask', 'question')

  return () => {
    logLine('dispose')
    stopped = true
    try { clearInterval(heartbeat) } catch {}
    for (const dispose of disposers) {
      try { dispose?.() } catch {}
    }
    try { child?.kill() } catch {}
    child = null
  }
}
