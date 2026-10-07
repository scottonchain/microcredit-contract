/**
 * The text a wallet-direct page keeps on screen when a step stops. A toast is gone before anyone can read it, and a
 * failure that only reaches the console looks like nothing happened (Hermes's browser runs, 2026-10-06). The text says what
 * the error was, trimmed so a long RPC error does not dump a request body on the page, and adds a hint for the two network
 * failures that are not the user's doing. A timeout may have come after the wallet sent, so that hint says to look at the
 * wallet's activity before pressing the button again.
 */
const MAX_LENGTH = 300;

export function networkHint(raw: string): string | undefined {
  if (/\b429\b|rate.?limit|too many requests/i.test(raw)) {
    return "The network endpoint is limiting requests. If this says nothing was sent, wait a minute and press the button again.";
  }
  if (/timed out|timeout|fetch failed|failed to fetch|network request failed|econn/i.test(raw)) {
    return "The network endpoint did not answer. Look at your wallet's activity before pressing the button again: the step may or may not have been sent.";
  }
  return undefined;
}

/** `what` is the sentence start ("The repayment stopped"), `parsed` the readable error, `raw` everything the error said. */
export function stopMessage(what: string, parsed: string, raw: string = parsed): string {
  const body = parsed.length > MAX_LENGTH ? `${parsed.slice(0, MAX_LENGTH)}...` : parsed;
  const hint = networkHint(`${parsed} ${raw}`);
  return `${what}: ${body}${hint ? ` ${hint}` : ""}`;
}
