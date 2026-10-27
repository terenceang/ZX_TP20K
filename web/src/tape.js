// ============================================================================
//  tape.js -- typing LOAD "" for the deck's LOAD button
// ============================================================================

import { typeText } from './zxkeys.js'

/**
 * The text the page types to start a tape: a plain 'j' is the LOAD keyword
 * token at the ROM's K cursor (the letters L,O,A,D would type "LOAD" as
 * ordinary characters), then two quotes, then RETURN.
 */
export function loadCommand() {
  return 'j""\r'
}

/**
 * Types LOAD "" + ENTER as paced matrix key events (FE packets): 'j' presses
 * J, each quote is the SYMBOL SHIFT+P chord, RETURN ends the line.  The board
 * only sees key presses -- the character-to-key translation lives in the page
 * (zxkeys.js), like the real membrane, which never knows what a key "means".
 */
export function typeLoadCommand(send, opts) {
  return typeText(loadCommand(), send, opts)
}
