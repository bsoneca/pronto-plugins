// A promise started before the step that will use it (a response waited for while the click that
// causes it is made). If the step fails first, or the scenario is run again after a wedge, nobody
// awaits the promise and its timeout, 30 s later, is an unhandled rejection that kills the whole
// runner (Deno exits on one), every other scenario's verdict with it. Marked handled here, it
// still rejects for whoever does await it; the scenario's verdict is its step's own.
export function early<T>(p: Promise<T>): Promise<T> {
  p.catch(() => {});
  return p;
}
