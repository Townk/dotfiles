import type { Register } from 'claude-code'

// Printed before `env -0` so whatever .zshrc writes to stdout is skipped.
export const MARK = '__LOGIN_ENV_START__'

// The variables an interactive login shell sets that a plain login shell
// (what the desktop app reads) misses. `$.env.set` takes literal names only,
// so adding one here also needs a case below.
export const NAMES = [
  'PATH', 'JAVA_HOME', 'GOROOT', 'CARGO_HOME', 'RUSTUP_HOME', 'RUSTUP_TOOLCHAIN',
  'KOTLIN_HOME', 'LUA_INIT', 'EDITOR', 'MANPAGER', 'HOMEBREW_NO_ENV_HINTS',
] as const

export const parseEnv = (stdout: string): Map<string, string> => {
  const vars = new Map<string, string>()
  const at = stdout.indexOf(MARK)
  if (at < 0) return vars
  for (const entry of stdout.slice(at + MARK.length).split('\0')) {
    const eq = entry.indexOf('=')
    if (eq > 0) vars.set(entry.slice(0, eq), entry.slice(eq + 1))
  }
  return vars
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)

    const set = (name: (typeof NAMES)[number], v: string) => {
      switch (name) {
        case 'PATH': return $.env.set('PATH', v)
        case 'JAVA_HOME': return $.env.set('JAVA_HOME', v)
        case 'GOROOT': return $.env.set('GOROOT', v)
        case 'CARGO_HOME': return $.env.set('CARGO_HOME', v)
        case 'RUSTUP_HOME': return $.env.set('RUSTUP_HOME', v)
        case 'RUSTUP_TOOLCHAIN': return $.env.set('RUSTUP_TOOLCHAIN', v)
        case 'KOTLIN_HOME': return $.env.set('KOTLIN_HOME', v)
        case 'LUA_INIT': return $.env.set('LUA_INIT', v)
        case 'EDITOR': return $.env.set('EDITOR', v)
        case 'MANPAGER': return $.env.set('MANPAGER', v)
        case 'HOMEBREW_NO_ENV_HINTS': return $.env.set('HOMEBREW_NO_ENV_HINTS', v)
      }
    }

    const shell = (await $.env.get('SHELL')) ?? '/bin/zsh'
    const { exitCode, stdout, stderr } = await $.process.run(
      [shell, '-l', '-i', '-c', `printf %s ${MARK}; env -0`],
      { env: { TERM: 'dumb' }, timeoutMs: 20_000 },
    )
    const vars = parseEnv(stdout)
    if (vars.size === 0) {
      $.ui.log(`login-env: ${shell} -lic gave no environment (exit ${exitCode}): ${stderr.slice(0, 200)}`, { to: 'debug' })
      return started
    }

    const applied: string[] = []
    for (const name of NAMES) {
      const value = vars.get(name)
      if (value === undefined) continue
      await set(name, value)
      applied.push(name)
    }
    $.ui.log(`login-env: set ${applied.join(', ') || 'nothing'} from ${shell}`, { to: 'debug' })
    return started
  })
}
