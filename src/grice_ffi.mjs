// JavaScript code behind grice's `@external` functions.

// Syntax trees
//
// What glance's offsets count, for `grice/internal/line_index`.

// JavaScript strings count UTF-16 code units, as glexer does here.
export function utf16_length(text) {
  return text.length;
}
