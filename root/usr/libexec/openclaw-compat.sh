#!/bin/sh
# Shared OpenClaw runtime compatibility repairs.

. /usr/libexec/openclaw-paths.sh
oc_load_paths "${OPENCLAW_INSTALL_ROOT:-/opt}"

NODE_BIN="${NODE_BIN:-${NODE_BASE}/bin/node}"

oc_runtime_compat_probe() {
	[ -x "$NODE_BIN" ] || return 1

	"$NODE_BIN" <<'NODE' >/dev/null 2>&1
try {
	new RegExp("\\p{Emoji}", "u");
	new RegExp("^\\p{RGI_Emoji}$", "v");
	process.exit(0);
} catch (error) {
	process.exit(1);
}
NODE
}

oc_runtime_compat_patch_file() {
	local file="$1"
	local kind="$2"

	[ -f "$file" ] || return 0
	[ -x "$NODE_BIN" ] || return 1

	OC_COMPAT_FILE="$file" OC_COMPAT_KIND="$kind" "$NODE_BIN" <<'NODE' >/dev/null 2>&1
const fs = require('fs');

const file = process.env.OC_COMPAT_FILE;
const kind = process.env.OC_COMPAT_KIND;
const patches = {
  fast_string_truncated_width: [
    [
      String.raw`const EMOJI_RE = /[\u{1F1E6}-\u{1F1FF}]{2}|\u{1F3F4}[\u{E0061}-\u{E007A}]{2}[\u{E0030}-\u{E0039}\u{E0061}-\u{E007A}]{1,3}\u{E007F}|(?:\p{Emoji}\uFE0F\u20E3?|\p{Emoji_Modifier_Base}\p{Emoji_Modifier}?|\p{Emoji_Presentation})(?:\u200D(?:\p{Emoji_Modifier_Base}\p{Emoji_Modifier}?|\p{Emoji_Presentation}|\p{Emoji}\uFE0F\u20E3?))*/yu;`,
      String.raw`const EMOJI_RE = /(?:[\u{1F1E6}-\u{1F1FF}]{2}|\u{1F3F4}[\u{E0061}-\u{E007A}]{2}[\u{E0030}-\u{E0039}\u{E0061}-\u{E007A}]{1,3}\u{E007F}|[\u{1F300}-\u{1FAFF}\u{2300}-\u{27BF}\u{1F900}-\u{1F9FF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}](?:\uFE0F|\u20E3)?(?:\u200D[\u{1F300}-\u{1FAFF}\u{2300}-\u{27BF}\u{1F900}-\u{1F9FF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}](?:\uFE0F|\u20E3)?)*)/yu;`,
    ],
  ],
  pi_tui: [
    [
      String.raw`const zeroWidthRegex = /^(?:\p{Default_Ignorable_Code_Point}|\p{Control}|\p{Mark}|\p{Surrogate})+$/v;`,
      String.raw`const zeroWidthRegex = /^[\u00AD\u034F\u061C\u180B-\u180E\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFE00-\uFE0F\uFEFF\uFFF9-\uFFFB\u0300-\u036F\uD800-\uDFFF]+$/u;`,
    ],
    [
      String.raw`const leadingNonPrintingRegex = /^[\p{Default_Ignorable_Code_Point}\p{Control}\p{Format}\p{Mark}\p{Surrogate}]+/v;`,
      String.raw`const leadingNonPrintingRegex = /^[\u00AD\u034F\u061C\u180B-\u180E\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFE00-\uFE0F\uFEFF\uFFF9-\uFFFB\u0300-\u036F\uD800-\uDFFF]+/u;`,
    ],
    [
      String.raw`const rgiEmojiRegex = /^\p{RGI_Emoji}$/v;`,
      String.raw`const rgiEmojiRegex = /^(?:[\u{1F1E6}-\u{1F1FF}]{2}|\u{1F3F4}[\u{E0061}-\u{E007A}]{2}[\u{E0030}-\u{E0039}\u{E0061}-\u{E007A}]{1,3}\u{E007F}|[\u{1F300}-\u{1FAFF}\u{2300}-\u{27BF}\u{1F900}-\u{1F9FF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}](?:\uFE0F|\u20E3)?(?:\u200D[\u{1F300}-\u{1FAFF}\u{2300}-\u{27BF}\u{1F900}-\u{1F9FF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}](?:\uFE0F|\u20E3)?)*)$/u;`,
    ],
  ],
};

let text = fs.readFileSync(file, 'utf8');
let modified = false;

for (const [oldText, newText] of patches[kind] || []) {
  if (text.includes(oldText)) {
    text = text.split(oldText).join(newText);
    modified = true;
  }
}

if (modified) {
  fs.writeFileSync(file, text);
}
NODE

	chown openclaw:openclaw "$file" 2>/dev/null || true
}

oc_runtime_compat_patch_tree() {
	local kind="$1"
	local rel_path="$2"
	local root file

	for root in "$OC_GLOBAL" "$NODE_BASE"; do
		[ -d "$root" ] || continue
		find "$root" -type f -path "*/$rel_path" 2>/dev/null | while IFS= read -r file; do
			[ -n "$file" ] || continue
			oc_runtime_compat_patch_file "$file" "$kind" || true
		done
	done
}

oc_apply_runtime_compat() {
	oc_runtime_compat_probe && return 0

	oc_runtime_compat_patch_tree fast_string_truncated_width 'fast-string-truncated-width/dist/index.js'
	oc_runtime_compat_patch_tree pi_tui '@mariozechner/pi-tui/dist/utils.js'
}
