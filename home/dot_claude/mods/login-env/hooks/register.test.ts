import { test, expect } from 'claude-code/testing'
import { MARK } from './register'

const ENV = ['PATH=/mise/node/bin:/usr/bin', 'JAVA_HOME=/mise/java', 'SECRET_TOKEN=nope', ''].join('\0')

test('copies the listed variables from the interactive login shell', async ($, on) => {
  const set: Record<string, string | undefined> = {}
  let argv: readonly string[] = []
  on('env.get', ($, e) => ({ value: e.name === 'SHELL' ? '/bin/zsh' : undefined }))
  on('env.set', ($, e) => { set[e.name] = e.value; return { value: undefined } })
  on('process.run', ($, e) => {
    argv = e.argv
    return { value: { exitCode: 0, stdout: `p10k noise${MARK}${ENV}`, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })

  expect(argv.slice(0, 3)).toEqual(['/bin/zsh', '-l', '-i'])
  expect(set).toEqual({ PATH: '/mise/node/bin:/usr/bin', JAVA_HOME: '/mise/java' })
})

test('leaves the environment alone when the shell prints nothing usable', async ($, on) => {
  const set: string[] = []
  on('env.get', () => ({ value: undefined }))
  on('env.set', ($, e) => { set.push(e.name); return { value: undefined } })
  on('process.run', () => ({ value: { exitCode: 1, stdout: '', stderr: 'boom', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })

  expect(set).toEqual([])
})
