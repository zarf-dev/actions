// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026-Present The Zarf Authors

/** Hidden markers a bot writes into its own descriptions and comments to find its text again. */
export interface BotMarkers {
  /** Allowed HTML comment contents (`<!-- ... -->`), matched against the trimmed text. */
  html: readonly RegExp[]
  /** Allowed Markdown link-reference comment contents (`[//]: # (...)`). */
  markdown: readonly RegExp[]
  /**
   * Allow a single zero-width space between `@` and a login (`@\u{200B}user`), which keeps copied text from
   * notifying that user. One character between two visible ones cannot carry a hidden payload.
   */
  mentionBreaks: boolean
}

export const NO_MARKERS: BotMarkers = { html: [], markdown: [], mentionBreaks: false }

/**
 * Bots whose markers can be allowed with `trusted-bots`. Keys are GitHub logins. A login ending in `[bot]`
 * belongs to a GitHub App and cannot be registered by a user, because user names cannot contain brackets.
 * Patterns are anchored and narrow, so that anything else hidden in the bot's text (for example in release
 * notes it copies from a dependency) is still reported.
 */
export const KNOWN_BOTS: Readonly<Record<string, BotMarkers>> = {
  // Markers such as `[//]: # (dependabot-automerge-start)`. In the release notes it copies, mentions are written as
  // `@\u{200B}user`, and raw HTML it strips is replaced by `<!-- raw HTML omitted -->`.
  'dependabot[bot]': {
    html: [/^raw HTML omitted$/u],
    markdown: [/^dependabot-[a-z]+(?:-[a-z]+)*$/u],
    mentionBreaks: true
  }
}

export function markersFor(logins: readonly string[]): BotMarkers {
  const bots = logins.map((login) => KNOWN_BOTS[login] ?? NO_MARKERS)
  return {
    html: bots.flatMap((b) => b.html),
    markdown: bots.flatMap((b) => b.markdown),
    mentionBreaks: bots.some((b) => b.mentionBreaks)
  }
}
