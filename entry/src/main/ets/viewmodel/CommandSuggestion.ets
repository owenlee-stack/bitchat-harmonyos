/**
 * One autocomplete entry for the "/" command popup (US6, T039; port of
 * bitchat-android ui/ChatState.kt CommandSuggestion).
 */

/** A command, its aliases, an optional argument hint and a description. */
export class CommandSuggestion {
  /** Primary command token, always lowercase (typed into the composer). */
  readonly command: string;
  /** Alternative spellings that also match this suggestion. */
  readonly aliases: string[];
  /** Argument hint shown after the command, null when it takes none. */
  readonly argsHint: string | null;
  readonly description: string;

  constructor(command: string, aliases: string[], argsHint: string | null,
    description: string) {
    this.command = command;
    this.aliases = aliases;
    this.argsHint = argsHint;
    this.description = description;
  }
}
