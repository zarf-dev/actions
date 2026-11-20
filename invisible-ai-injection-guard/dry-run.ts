// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026-Present The Zarf Authors

// Dry run of invisible-ai-injection-guard against a whole repository. Read-only: it never writes to GitHub.
//
// Put this file in invisible-ai-injection-guard/ and run from there:
//   npm ci
//   GH_TOKEN=$(gh auth token) npx tsx dry-run.ts <owner>/<repo> [--state open|closed|all] [--comments]
//     [--min-severity low|medium|high] [--limit N] [--out DIR]
//
// Writes <out>/<owner>-<repo>-issues.md and <out>/<owner>-<repo>-prs.md.
// --comments also scans every comment, review and review comment (many more API calls; watch the rate limit).

import { writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { getOctokit } from '@actions/github'
import type { Target, Subject } from './src/github.js'
import { buildReportComment, formatLocation } from './src/report.js'
import { markersFor, NO_MARKERS } from './src/bots.js'
import { DEFAULT_SCAN_OPTIONS, scan } from './src/scan.js'
import { loadTemplateSnippets } from './src/templates.js'
import type { Finding, Severity } from './src/types.js'
import { atLeast, maxSeverity } from './src/types.js'

// Same settings as the workflow in zarf-dev/actions.
const LABEL = 'suspicious-hidden-content'
const TRUSTED_BOTS = ['dependabot[bot]']

const args = process.argv.slice(2)
const flag = (name: string, fallback: string): string => {
  const i = args.indexOf(`--${name}`)
  return i === -1 ? fallback : (args[i + 1] ?? fallback)
}
const slug = args.find((a) => /^[^-][^/]*\/[^/]+$/u.test(a))
if (!slug || !process.env['GH_TOKEN']) {
  console.error('usage: GH_TOKEN=$(gh auth token) npx tsx dry-run.ts owner/repo [--state all] [--comments] ...')
  process.exit(1)
}
const [owner = '', repo = ''] = slug.split('/')
const state = flag('state', 'all') as 'open' | 'closed' | 'all'
const minSeverity = flag('min-severity', 'medium') as Severity
const limit = Number(flag('limit', 'Infinity'))
const outDir = flag('out', '.')
const withComments = args.includes('--comments')

const octokit = getOctokit(process.env['GH_TOKEN'])
const log = {
  debug: () => undefined,
  warning: (message: string) => {
    console.warn(message)
  }
}
const templateSnippets = await loadTemplateSnippets(octokit, owner, repo, log)

type User = { login?: string; type?: string } | null | undefined
interface Text {
  subject: Subject
  title: string
  body: string | null | undefined
  user: User
  association: string
}
interface Result {
  text: Text
  findings: Finding[]
  actions: string[]
  report: string
}
interface Item {
  kind: 'issue' | 'pull_request'
  number: number
  title: string
  url: string
  state: string
  labels: string[]
  results: Result[]
}

function check(item: Item, text: Text, labeled: { done: boolean }): Result | undefined {
  const author = text.user?.login ?? 'ghost'
  const body = text.body ?? ''
  const trusted =
    text.user?.type === 'Bot' && TRUSTED_BOTS.includes(author.toLowerCase()) ? markersFor([author]) : NO_MARKERS
  const isComment = text.subject.type === 'comment'
  const findings = scan(
    { title: text.title, body },
    {
      ...DEFAULT_SCAN_OPTIONS,
      // Templates only apply to descriptions, as in the action.
      ignoredSnippets: isComment ? new Set() : templateSnippets,
      allowedMarkers: trusted
    },
    isComment ? 'comment' : 'body'
  ).filter((f) => atLeast(f.severity, minSeverity))
  if (findings.length === 0) return undefined

  const actions: string[] = []
  if (!item.labels.includes(LABEL) && !labeled.done) actions.push(`added label \`${LABEL}\``)
  labeled.done = true
  if (text.subject.type === 'comment' && text.subject.kind !== 'review') actions.push('hid the comment')
  const target: Target = {
    kind: item.kind,
    owner,
    repo,
    number: item.number,
    subject: text.subject,
    title: text.title,
    body,
    author,
    authorType: text.user?.type ?? 'User',
    sender: author,
    authorAssociation: text.association,
    labels: item.labels
  }
  const report = buildReportComment(target, findings, { showEvidence: true, actions: [...actions] })
  actions.push('posted report comment')
  return { text, findings, actions, report }
}

async function commentsOf(item: Item): Promise<Text[]> {
  const params = { owner, repo, per_page: 100 }
  const texts: Text[] = []
  const issueComments = await octokit.paginate(octokit.rest.issues.listComments, {
    ...params,
    issue_number: item.number
  })
  for (const c of issueComments) {
    // Skip the action's own reports, as the action does.
    if (c.user?.type === 'Bot' && (c.body ?? '').includes('<!-- invisible-ai-injection-guard:report')) continue
    texts.push({
      subject: { type: 'comment', kind: 'issue_comment', id: c.id, nodeId: c.node_id, url: c.html_url },
      title: '',
      body: c.body,
      user: c.user,
      association: c.author_association
    })
  }
  if (item.kind === 'pull_request') {
    const reviewComments = await octokit.paginate(octokit.rest.pulls.listReviewComments, {
      ...params,
      pull_number: item.number
    })
    for (const c of reviewComments) {
      texts.push({
        subject: { type: 'comment', kind: 'review_comment', id: c.id, nodeId: c.node_id, url: c.html_url },
        title: '',
        body: c.body,
        user: c.user,
        association: c.author_association
      })
    }
    const reviews = await octokit.paginate(octokit.rest.pulls.listReviews, { ...params, pull_number: item.number })
    for (const r of reviews) {
      if (!r.body) continue
      texts.push({
        subject: { type: 'comment', kind: 'review', id: r.id, nodeId: r.node_id, url: r.html_url },
        title: '',
        body: r.body,
        user: r.user,
        association: r.author_association
      })
    }
  }
  return texts
}

const items: Item[] = []
let count = 0
for await (const page of octokit.paginate.iterator(octokit.rest.issues.listForRepo, {
  owner,
  repo,
  state,
  per_page: 100
})) {
  for (const raw of page.data) {
    if (count++ >= limit) break
    const item: Item = {
      kind: raw.pull_request ? 'pull_request' : 'issue',
      number: raw.number,
      title: raw.title,
      url: raw.html_url,
      state: raw.state,
      labels: raw.labels.map((l) => (typeof l === 'string' ? l : (l.name ?? ''))),
      results: []
    }
    const labeled = { done: false }
    const description: Text = {
      subject: { type: 'description' },
      title: raw.title,
      body: raw.body,
      user: raw.user,
      association: raw.author_association ?? 'NONE'
    }
    for (const text of [description, ...(withComments ? await commentsOf(item) : [])]) {
      const result = check(item, text, labeled)
      if (result) item.results.push(result)
    }
    items.push(item)
    process.stderr.write(`\r${count} scanned`)
  }
  if (count >= limit) break
}
process.stderr.write('\n')

const cell = (s: string): string => s.replace(/\|/gu, '\\|').replace(/</gu, '&lt;').replace(/\r?\n/gu, ' ')

function render(kind: Item['kind']): string {
  const all = items.filter((i) => i.kind === kind)
  const flagged = all.filter((i) => i.results.length > 0)
  const name = kind === 'issue' ? 'Issues' : 'Pull requests'
  const out = [
    `# Dry run: ${name.toLowerCase()} in ${owner}/${repo}`,
    '',
    `Scanned ${all.length} ${name.toLowerCase()} (state: ${state}, comments: ${withComments ? 'yes' : 'no'}, ` +
      `min severity: ${minSeverity}). **${flagged.length} would be flagged.**`,
    '',
    'Nothing was written to GitHub. Closing is not simulated: in the zarf-dev/actions workflow, a flagged ' +
      'description (not a comment) would also close the item.',
    ''
  ]
  if (flagged.length > 0) {
    out.push('| Item | State | Max severity | Flagged texts | Would close |', '| --- | --- | --- | --- | --- |')
    for (const i of flagged) {
      const max = maxSeverity(i.results.flatMap((r) => r.findings)) ?? ''
      const closes = i.state === 'open' && i.results.some((r) => r.text.subject.type === 'description')
      out.push(
        `| [#${i.number}](${i.url}) ${cell(i.title)} | ${i.state} | ${max} | ${i.results.length} | ${closes ? 'yes' : ''} |`
      )
    }
  }
  for (const i of flagged) {
    out.push('', '---', '', `## [#${i.number}](${i.url}) ${cell(i.title)}`, '')
    out.push(`State: ${i.state}. Labels: ${i.labels.map((l) => `\`${l}\``).join(', ') || 'none'}.`)
    for (const r of i.results) {
      const s = r.text.subject
      const where = s.type === 'description' ? 'Description' : `[${s.kind.replace('_', ' ')} ${s.id}](${s.url})`
      out.push('', `### ${where} by @${r.text.user?.login ?? 'ghost'}`, '', '**Would have:**')
      for (const a of r.actions) out.push(`- ${a.replace(/`/gu, '')}`)
      out.push('', '| Severity | Location | Rule |', '| --- | --- | --- |')
      for (const f of r.findings) out.push(`| ${f.severity} | ${formatLocation(f)} | \`${f.rule}\` |`)
      out.push('', '<details><summary>Report comment that would be posted</summary>', '', '`````markdown')
      out.push(r.report, '`````', '', '</details>')
    }
  }
  return out.join('\n') + '\n'
}

for (const [kind, suffix] of [
  ['issue', 'issues'],
  ['pull_request', 'prs']
] as const) {
  const file = join(outDir, `${owner}-${repo}-${suffix}.md`)
  writeFileSync(file, render(kind))
  console.log(`Wrote ${file}`)
}
